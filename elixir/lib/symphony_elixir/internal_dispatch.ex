defmodule SymphonyElixir.InternalDispatch do
  @moduledoc """
  Binds verified container leases to routed internal phase attempts.

  One caller owns the admission journal and schedules each prepared lease
  once. The supervised worker only executes the attached lease. After the
  worker finishes or is stopped, the scheduler drains the container before
  verifying evidence or releasing the next phase. A failed mutation leaves
  the durable record in charge of redispatch.
  """

  alias SymphonyElixir.{AgentProfiles, AgentRouter, InternalAdmission, InternalWorkflow}
  alias SymphonyElixir.AgentRouter.Request
  alias SymphonyElixir.InternalContainerWorker, as: Worker

  @type routing :: %{
          request: Request.t(),
          profiles: [AgentProfiles.Profile.t()],
          availability: AgentProfiles.Availability.t(),
          command_for: (AgentRouter.target() -> {:ok, Worker.command()} | {:error, term()})
        }

  @type prepared :: %{
          attempt: InternalWorkflow.attempt(),
          decision: AgentRouter.decision(),
          lease: Worker.lease()
        }

  @type verifier :: (-> InternalWorkflow.verification() | nil)

  @doc "Routes the next phase and reserves a stopped worker for the selected execution target."
  @spec prepare(Worker.t(), InternalAdmission.t(), InternalWorkflow.t(), String.t(), Path.t(), routing()) ::
          {:ok, InternalWorkflow.t(), prepared()}
          | {:wait, AgentRouter.decision()}
          | {:blocked, AgentRouter.decision()}
          | {:error, term()}
  def prepare(worker, journal, workflow, boot_id, workspace, routing) do
    with {:ok, run, attempt} <- InternalWorkflow.start(workflow, boot_id),
         {:ok, workspace_id} <- Worker.workspace_id(worker, workspace),
         {:ok, request} <- request(routing.request, attempt, workspace_id),
         {:ok, decision} <- AgentRouter.route(request, routing.profiles, routing.availability),
         {:ok, command} <- routing.command_for.(decision.target),
         {:ok, lease} <- Worker.prepare(worker, journal, attempt, workspace, command) do
      {:ok, run, %{attempt: attempt, decision: decision, lease: lease}}
    end
  end

  @doc """
  Settles a bound attempt after confirming drain and running a trusted verifier.

  A stale or unbound result has no effect. The verifier inspects host evidence
  after the container can no longer write. The returned next phase is usable
  only after the journal has recorded the disposition.
  """
  @spec settle(Worker.t(), InternalAdmission.t(), InternalWorkflow.t(), prepared(), term(), verifier()) ::
          {:ok, InternalWorkflow.t(), InternalWorkflow.directive()} | {:error, term()}
  def settle(worker, journal, run, prepared, outcome, verify) do
    %{attempt: attempt, lease: %{attempt_id: lease_id, identity: identity}} = prepared
    scope = {run.project_id, run.issue_id}

    with true <- run.active_attempt == attempt.id and attempt.id == lease_id,
         {:ok, ^identity} <- attached_identity(journal, scope, attempt.id),
         {:ok, proof} <- Worker.drain(worker, attempt.id, identity),
         {:ok, next, directive} <- InternalWorkflow.record(run, attempt.id, outcome, verify.()),
         :ok <- InternalAdmission.finish(journal, scope, attempt.id, proof, disposition(directive)) do
      {:ok, next, directive}
    else
      false -> {:error, :stale_attempt}
      {:ok, _identity} -> {:error, :stale_lease}
      error -> error
    end
  end

  @doc "Drains and parks a verified lease from the journal during cancellation or boot recovery."
  @spec recover(Worker.t(), InternalAdmission.t(), InternalAdmission.scope()) :: :ok | {:error, term()}
  def recover(worker, journal, scope) do
    with {:ok, %{run_id: run_id, lease: %{boot_id: boot_id, generation: generation, process_identity: identity}}} <-
           InternalAdmission.lookup(journal, scope),
         attempt_id = {run_id, boot_id, generation},
         {:ok, proof} <- recovery_proof(worker, attempt_id, identity) do
      InternalAdmission.finish(journal, scope, attempt_id, proof, :parked)
    else
      {:ok, _record} -> {:error, :no_lease}
      error -> error
    end
  end

  defp recovery_proof(worker, attempt_id, nil), do: Worker.drain_pending(worker, attempt_id)
  defp recovery_proof(worker, attempt_id, identity), do: Worker.drain(worker, attempt_id, identity)

  defp request(%Request{scope: %{project: project} = scope} = request, %{project_id: project} = attempt, workspace_id) do
    access = if attempt.write_mode == :workspace_write, do: :write, else: :read

    {:ok,
     %{
       request
       | run_id: elem(attempt.id, 0),
         phase: attempt.phase,
         requirements_revision: attempt.requirements_revision,
         policy_version: attempt.policy_revision,
         workspace_id: workspace_id,
         scope: Map.put(scope, :access, access)
     }}
  end

  defp request(_request, _attempt, _workspace_id), do: {:error, :routing_scope_mismatch}

  defp attached_identity(journal, scope, {run_id, boot_id, generation}) do
    with {:ok, %{run_id: ^run_id, lease: lease}} <- InternalAdmission.lookup(journal, scope),
         %{boot_id: ^boot_id, generation: ^generation, process_identity: identity} when is_binary(identity) <- lease do
      {:ok, identity}
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :stale_lease}
    end
  end

  defp disposition({:park, _reason}), do: :parked
  defp disposition(_next), do: :ready
end
