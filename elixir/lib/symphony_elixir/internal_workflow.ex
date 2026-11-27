defmodule SymphonyElixir.InternalWorkflow do
  @moduledoc """
  Reduces a serial, opt-in run under the orchestrator's existing issue claim.

  The caller owns durable admission, workspace leases, permissions, and process
  draining. Only host-verified data may be supplied as verification. Provider
  results cannot approve evidence or request tracker mutations.
  """

  @worker_phases [:planning, :implementation, :validation, :review]
  @max_criteria 64
  @max_reference_bytes 1024

  @enforce_keys [:run_id, :issue_id, :project_id, :requirements_revision, :policy_revision]
  defstruct [
    :run_id,
    :issue_id,
    :project_id,
    :requirements_revision,
    :policy_revision,
    :active_attempt,
    :plan_ref,
    :artifact,
    :correction,
    :review_ref,
    phase: :planning,
    status: :ready,
    independent_review: false,
    retry_limit: 2,
    correction_limit: 1,
    generation: 0,
    retries: 0,
    corrections: 0,
    criteria: [],
    evidence: %{}
  ]

  @type worker_phase :: :planning | :implementation | :validation | :review
  @type phase :: worker_phase() | :human_review
  @type attempt_id :: {run_id :: String.t(), boot_id :: String.t(), generation :: pos_integer()}
  @type hold_reason ::
          :operator_pause
          | :tracker_inactive
          | :provider_blocked
          | :retry_budget_exhausted
          | :correction_budget_exhausted
          | :invalid_outcome
          | :unverified_phase
          | :human_review
  @type artifact :: %{ref: String.t(), revision: String.t()}
  @type correction :: %{artifact: artifact(), findings_ref: String.t()}
  @type evidence :: %{optional(String.t()) => String.t()}
  @type handoff :: %{
          plan_ref: String.t() | nil,
          artifact: artifact() | nil,
          correction: correction() | nil,
          review_ref: String.t() | nil,
          criteria: [String.t()],
          open_criteria: [String.t()],
          evidence: evidence()
        }
  @type attempt :: %{
          id: attempt_id(),
          issue_id: String.t(),
          project_id: String.t(),
          phase: worker_phase(),
          requirements_revision: String.t(),
          policy_revision: String.t(),
          write_mode: :read_only | :workspace_write,
          handoff: handoff()
        }
  @type review_verdict :: {:approved, review_ref :: String.t()} | {:changes_requested, findings_ref :: String.t()}
  @type verification ::
          {:planning, requirements_revision :: String.t(), plan_ref :: String.t(), [criterion_id :: String.t()]}
          | {:implementation, requirements_revision :: String.t(), artifact()}
          | {:validation, requirements_revision :: String.t(), artifact_revision :: String.t(), evidence()}
          | {:review, requirements_revision :: String.t(), artifact_revision :: String.t(), review_verdict()}
  @type directive :: :dispatch | :retry | {:park, hold_reason()}
  @type t :: %__MODULE__{
          run_id: String.t(),
          issue_id: String.t(),
          project_id: String.t(),
          requirements_revision: String.t(),
          policy_revision: String.t(),
          active_attempt: attempt_id() | nil,
          plan_ref: String.t() | nil,
          artifact: artifact() | nil,
          correction: correction() | nil,
          review_ref: String.t() | nil,
          phase: phase(),
          status: :ready | :running | {:parked, hold_reason()},
          independent_review: boolean(),
          retry_limit: non_neg_integer(),
          correction_limit: non_neg_integer(),
          generation: non_neg_integer(),
          retries: non_neg_integer(),
          corrections: non_neg_integer(),
          criteria: [String.t()],
          evidence: evidence()
        }

  @doc "Creates a run from trusted admission and policy fields."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_workflow}
  def new(attrs) do
    identity = Map.take(attrs, @enforce_keys)
    policy = Map.take(attrs, [:independent_review, :retry_limit, :correction_limit])

    with true <- map_size(identity) == length(@enforce_keys) and Enum.all?(Map.values(identity), &reference?/1),
         run = struct!(__MODULE__, Map.merge(identity, policy)),
         true <- is_boolean(run.independent_review) and budget?(run.retry_limit) and budget?(run.correction_limit) do
      {:ok, run}
    else
      false -> {:error, :invalid_workflow}
    end
  end

  @doc "Reserves one attempt. Persist the reservation and verify the worker lease before launch."
  @spec start(t(), String.t()) :: {:ok, t(), attempt()} | {:error, :not_dispatchable | :invalid_boot_id}
  def start(%__MODULE__{status: :ready, phase: phase} = run, boot_id) when phase in @worker_phases do
    if reference?(boot_id) do
      generation = run.generation + 1
      id = {run.run_id, boot_id, generation}

      attempt = %{
        id: id,
        issue_id: run.issue_id,
        project_id: run.project_id,
        phase: phase,
        requirements_revision: run.requirements_revision,
        policy_revision: run.policy_revision,
        write_mode: if(phase == :implementation, do: :workspace_write, else: :read_only),
        handoff: handoff(run)
      }

      {:ok, %{run | status: :running, active_attempt: id, generation: generation}, attempt}
    else
      {:error, :invalid_boot_id}
    end
  end

  def start(%__MODULE__{}, _boot_id), do: {:error, :not_dispatchable}

  @doc """
  Applies a versioned candidate outcome after the current worker tree has exited.

  Verification is supplied by the orchestrator's trusted verifier and uses the
  exact requirements and workspace revisions. A stale attempt has no effect.
  """
  @spec record(t(), attempt_id(), term(), verification() | nil) :: {:ok, t(), directive()} | {:error, :stale_attempt}
  def record(%__MODULE__{status: :running, active_attempt: id} = run, id, outcome, verification) do
    reduce_outcome(run, outcome, verification)
  end

  def record(%__MODULE__{}, _id, _outcome, _verification), do: {:error, :stale_attempt}

  @doc "Parks after tracker inactivation or an operator pause. Drain any active worker first."
  @spec park(t(), :operator_pause | :tracker_inactive) :: t()
  def park(%__MODULE__{status: {:parked, _}} = run, _reason), do: run
  def park(%__MODULE__{} = run, reason) when reason in [:operator_pause, :tracker_inactive], do: hold(run, reason)

  @doc "Resumes a held run after the orchestrator verifies operator authority and tracker eligibility."
  @spec resume(t(), %{requirements_revision: String.t(), workspace_revision: String.t() | nil}) ::
          {:ok, t()} | {:error, :not_parked | :invalid_revisions | :human_review_required}
  def resume(%__MODULE__{status: {:parked, _}} = run, %{requirements_revision: requirements, workspace_revision: workspace}) do
    if reference?(requirements) and (is_nil(workspace) or reference?(workspace)) do
      resume_at_revisions(run, requirements, workspace)
    else
      {:error, :invalid_revisions}
    end
  end

  def resume(%__MODULE__{status: {:parked, _}}, _revisions), do: {:error, :invalid_revisions}
  def resume(%__MODULE__{}, _revisions), do: {:error, :not_parked}

  @doc "Returns the accepted handoff and the criteria still waiting for evidence."
  @spec handoff(t()) :: handoff()
  def handoff(%__MODULE__{} = run) do
    %{
      plan_ref: run.plan_ref,
      artifact: run.artifact,
      correction: run.correction,
      review_ref: run.review_ref,
      criteria: run.criteria,
      open_criteria: Enum.reject(run.criteria, &Map.has_key?(run.evidence, &1)),
      evidence: run.evidence
    }
  end

  defp reduce_outcome(run, %{version: 1, status: :succeeded}, verification), do: advance(run, verification)

  defp reduce_outcome(run, %{version: 1, status: :retryable}, _verification) do
    if run.retries < run.retry_limit do
      {:ok, %{run | status: :ready, active_attempt: nil, retries: run.retries + 1}, :retry}
    else
      parked(run, :retry_budget_exhausted)
    end
  end

  defp reduce_outcome(run, %{version: 1, status: :blocked}, _verification), do: parked(run, :provider_blocked)

  defp reduce_outcome(run, %{version: 1, status: :changes_requested}, verification),
    do: correct(run, verification)

  defp reduce_outcome(run, _outcome, _verification), do: parked(run, :invalid_outcome)

  defp advance(%{phase: :planning, requirements_revision: req} = run, {:planning, req, plan_ref, criteria}) do
    if reference?(plan_ref) and criteria?(criteria) do
      dispatch(%{run | plan_ref: plan_ref, criteria: criteria}, :implementation)
    else
      parked(run, :unverified_phase)
    end
  end

  defp advance(%{phase: :implementation, requirements_revision: req} = run, {:implementation, req, %{ref: ref, revision: revision}}) do
    if reference?(ref) and reference?(revision) do
      dispatch(%{run | artifact: %{ref: ref, revision: revision}}, :validation)
    else
      parked(run, :unverified_phase)
    end
  end

  defp advance(%{phase: :validation, requirements_revision: req, artifact: %{revision: work}} = run, {:validation, req, work, evidence}) do
    if verified_criteria?(run.criteria, evidence) do
      validated = %{run | evidence: evidence}

      if run.independent_review do
        dispatch(validated, :review)
      else
        parked(%{validated | phase: :human_review}, :human_review)
      end
    else
      parked(run, :unverified_phase)
    end
  end

  defp advance(
         %{phase: :review, requirements_revision: req, artifact: %{revision: work}} = run,
         {:review, req, work, {:approved, ref}}
       ) do
    if reference?(ref) do
      parked(%{run | phase: :human_review, review_ref: ref}, :human_review)
    else
      parked(run, :unverified_phase)
    end
  end

  defp advance(run, _verification), do: parked(run, :unverified_phase)

  defp correct(
         %{phase: :review, requirements_revision: req, artifact: %{revision: work} = artifact} = run,
         {:review, req, work, {:changes_requested, findings_ref}}
       ) do
    cond do
      not reference?(findings_ref) ->
        parked(run, :unverified_phase)

      run.corrections >= run.correction_limit ->
        parked(run, :correction_budget_exhausted)

      true ->
        correction = %{artifact: artifact, findings_ref: findings_ref}
        dispatch(clear_artifact(%{run | corrections: run.corrections + 1, correction: correction}), :implementation)
    end
  end

  defp correct(run, _verification), do: parked(run, :unverified_phase)

  defp resume_at_revisions(%{requirements_revision: previous} = run, requirements, _workspace) when previous != requirements do
    {:ok,
     %{
       run
       | requirements_revision: requirements,
         phase: :planning,
         status: :ready,
         plan_ref: nil,
         artifact: nil,
         correction: nil,
         review_ref: nil,
         criteria: [],
         evidence: %{},
         retries: 0,
         corrections: 0
     }}
  end

  defp resume_at_revisions(%{artifact: %{}}, _requirements, nil), do: {:error, :invalid_revisions}

  defp resume_at_revisions(%{artifact: %{revision: previous}} = run, _requirements, workspace) when previous != workspace do
    {:ok, clear_artifact(%{run | phase: :implementation, status: :ready, retries: 0})}
  end

  defp resume_at_revisions(%{phase: :human_review}, _requirements, _workspace), do: {:error, :human_review_required}
  defp resume_at_revisions(run, _requirements, _workspace), do: {:ok, %{run | status: :ready}}

  defp dispatch(run, next), do: {:ok, %{run | phase: next, status: :ready, active_attempt: nil, retries: 0}, :dispatch}
  defp parked(run, reason), do: {:ok, hold(run, reason), {:park, reason}}
  defp hold(run, reason), do: %{run | status: {:parked, reason}, active_attempt: nil}
  defp clear_artifact(run), do: %{run | artifact: nil, review_ref: nil, evidence: %{}}

  defp criteria?(criteria) when is_list(criteria) and criteria != [] and length(criteria) <= @max_criteria do
    Enum.all?(criteria, &reference?/1) and Enum.uniq(criteria) == criteria
  end

  defp criteria?(_criteria), do: false

  defp verified_criteria?(criteria, evidence) when is_map(evidence) and map_size(evidence) == length(criteria) do
    Enum.all?(criteria, &reference?(Map.get(evidence, &1)))
  end

  defp verified_criteria?(_criteria, _evidence), do: false

  defp reference?(value) when is_binary(value) and byte_size(value) in 1..@max_reference_bytes, do: String.trim(value) != ""
  defp reference?(_value), do: false

  defp budget?(value), do: is_integer(value) and value >= 0
end
