defmodule SymphonyElixir.InternalPilot do
  @moduledoc """
  Opt-in synthetic Linear-to-Human-Review pilot driven by the daemon's poll loop.

  Owns one selected issue under the orchestrator process. The host reads and
  projects Linear state. Containers run known fixture commands with no
  credentials, network, or tracker tools.
  """

  require Logger

  alias SymphonyElixir.AgentProfiles.{Availability, Profile}
  alias SymphonyElixir.AgentRouter.Request
  alias SymphonyElixir.{InternalAdmission, InternalDispatch, InternalWorkflow}
  alias SymphonyElixir.InternalContainerWorker, as: Worker
  alias SymphonyElixir.Jira.Client, as: Jira
  alias SymphonyElixir.Linear.InternalPilot, as: Linear

  @jira_url "https://jira.fixture.test/browse/PILOT-1"
  @criteria "fixture-response"
  @requirements "Acceptance criteria:\n- The result file contains fixture-response."
  @expected "fixture-response\n"
  @review "Human Review"
  @start_states ["todo", "to do"]
  @phase_specs %{
    planning: {:gemini, :research, "test ! -e result.txt"},
    implementation: {:codex, :implement, "printf 'fixture-response\\n' > result.txt"},
    validation: {:codex, :test, "test \"$(cat result.txt)\" = fixture-response"},
    review: {:claude, :review, "test \"$(cat result.txt)\" = fixture-response"}
  }

  defstruct [
    :config,
    :scope,
    :boot_id,
    :journal,
    :worker,
    :workspace,
    :image,
    :item,
    :source,
    :run,
    :prepared,
    :task,
    :started_at,
    :reason
  ]

  @type t :: %__MODULE__{}

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{agent: %{internal_pilot: nil}}), do: :ok

  def validate(%{agent: %{internal_pilot: pilot}, tracker: tracker, workspace: workspace, worker: worker}) do
    with %{"issue_id" => issue, "human_review_state_id" => review, "state_directory" => directory, "docker_socket" => socket, "image" => image} when map_size(pilot) == 5 <- pilot,
         true <- uuid?(issue) and uuid?(review) and absolute?(directory) and absolute?(socket),
         true <- is_binary(image) and Regex.match?(~r/\Asha256:[a-f0-9]{64}\z/, image),
         true <- tracker.kind == "linear" and is_binary(tracker.project_slug) and tracker.project_slug != "",
         true <- allowed_endpoint?(tracker.endpoint) and worker.ssh_hosts == [] and absolute?(workspace.root),
         true <- Enum.any?(tracker.active_states, &start_state?/1),
         true <- @review not in (tracker.active_states ++ tracker.terminal_states) do
      :ok
    else
      _invalid -> {:error, :invalid_internal_pilot_config}
    end
  end

  @spec open(map()) :: {:ok, t() | nil} | {:error, term()}
  def open(%{agent: %{internal_pilot: nil}}), do: {:ok, nil}

  def open(config) do
    settings = config.agent.internal_pilot
    root = config.workspace.root
    boot = unique_id()
    scope = %{issue_id: settings["issue_id"], review_id: settings["human_review_state_id"], tracker: config.tracker}

    with {:ok, worker} <- Worker.open(settings["docker_socket"], root),
         {:ok, journal} <- open_journal(settings["state_directory"], root, boot) do
      pilot = %__MODULE__{
        config: pinned(config),
        scope: scope,
        boot_id: boot,
        journal: journal,
        worker: worker,
        workspace: Path.join(root, "pilot@" <> scope.issue_id),
        image: settings["image"]
      }

      {:ok, recover_at_start(pilot)}
    end
  end

  @spec poll(t(), map(), GenServer.server()) :: t()
  def poll(%__MODULE__{} = pilot, config, supervisor) do
    cond do
      pilot.reason == :pilot_configuration_changed -> pilot
      pinned(config) != pilot.config -> stop(pilot, :pilot_configuration_changed)
      pilot.reason == :human_review -> pilot
      true -> observe(pilot, supervisor, Linear.read(pilot.scope))
    end
  end

  @spec worker_result(t(), reference(), term(), map()) :: t()
  def worker_result(%__MODULE__{task: %Task{ref: ref}} = pilot, ref, result, config) do
    Process.demonitor(ref, [:flush])
    pilot = %{pilot | task: nil}

    case result do
      {:ok, observed} -> settle_observed(pilot, observed, config)
      _failure -> stop(pilot, :pilot_worker_failed)
    end
  end

  def worker_result(pilot, _ref, _result, _config), do: pilot

  @spec worker_down(t(), reference()) :: t()
  def worker_down(%__MODULE__{task: %Task{ref: ref}} = pilot, ref) do
    stop(%{pilot | task: nil}, :pilot_worker_exited)
  end

  def worker_down(pilot, _ref), do: pilot

  @spec stop(t(), atom()) :: t()
  def stop(%__MODULE__{} = pilot, reason) do
    if pilot.task, do: Task.shutdown(pilot.task, :brutal_kill)

    reason =
      case InternalDispatch.recover(pilot.worker, pilot.journal, journal_scope(pilot)) do
        :ok ->
          reason

        {:error, :no_lease} ->
          hold_inactive(pilot, reason)

        {:error, error} ->
          log(pilot, "lease requires reconciliation: #{inspect(error)}")
          :pilot_lease_unresolved
      end

    %{pilot | task: nil, reason: reason}
  end

  defp recover_at_start(pilot) do
    case InternalAdmission.lookup(pilot.journal, journal_scope(pilot)) do
      {:ok, nil} -> pilot
      {:ok, %{status: :review_pending}} -> %{pilot | reason: :pilot_review_transition_unconfirmed}
      {:ok, _previous} -> stop(pilot, :pilot_parked_after_restart)
      {:error, _reason} -> %{pilot | reason: :pilot_journal_unavailable}
    end
  end

  @spec rows(t()) :: {map(), map()}
  def rows(%__MODULE__{item: %{issue: issue}, task: %Task{}, prepared: prepared} = pilot) do
    entry = %{
      identifier: issue.identifier,
      issue: issue,
      provider: prepared.decision.target.provider,
      workspace_path: pilot.workspace,
      session_id: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: pilot.started_at,
      last_codex_timestamp: pilot.started_at,
      last_codex_message: "Internal phase: #{prepared.attempt.phase}",
      last_codex_event: :internal_phase
    }

    {%{issue.id => entry}, %{}}
  end

  def rows(%__MODULE__{item: %{issue: issue}, reason: reason} = pilot) when is_atom(reason) and not is_nil(reason) do
    entry = %{
      identifier: issue.identifier,
      issue: issue,
      workspace_path: pilot.workspace,
      error: reason |> Atom.to_string() |> String.replace("_", " "),
      blocked_at: pilot.started_at || DateTime.utc_now()
    }

    {%{}, %{issue.id => entry}}
  end

  def rows(_pilot), do: {%{}, %{}}

  defp observe(pilot, supervisor, {:ok, item}) do
    pilot = %{pilot | item: item}

    cond do
      review_observed?(pilot) -> confirm_review(pilot)
      pilot.reason != nil -> pilot
      eligible?(pilot, item) -> dispatch_observed(pilot, supervisor)
      pilot.source != nil -> stop(pilot, :pilot_issue_changed)
      true -> pilot
    end
  end

  defp observe(%{source: nil} = pilot, _supervisor, {:error, _reason}), do: pilot
  defp observe(%{reason: reason} = pilot, _supervisor, {:error, _reason}) when not is_nil(reason), do: pilot
  defp observe(pilot, _supervisor, {:error, _reason}), do: stop(pilot, :pilot_linear_read_failed)

  defp review_observed?(pilot) do
    pilot.item.state_id == pilot.scope.review_id and pilot.task == nil and
      pilot.reason not in [:pilot_lease_unresolved, :pilot_journal_unavailable]
  end

  defp dispatch_observed(%{task: %Task{}} = pilot, _supervisor), do: pilot
  defp dispatch_observed(%{run: nil} = pilot, supervisor), do: start_run(pilot, pilot.item, supervisor)
  defp dispatch_observed(pilot, supervisor), do: launch_phase(pilot, supervisor)

  defp eligible?(pilot, item) do
    start_state?(item.issue.state) and is_binary(item.issue.description) and String.trim(item.issue.description) == @jira_url and
      (pilot.source == nil or source(item) == pilot.source)
  end

  defp source(item), do: {item.team_id, item.state_id, item.issue.title, item.issue.description}

  defp start_run(pilot, item, supervisor) do
    scope = journal_scope(pilot)

    case InternalAdmission.lookup(pilot.journal, scope) do
      {:ok, nil} -> admit(pilot, item, scope, supervisor)
      {:ok, _prior} -> stop(pilot, :pilot_parked_after_restart)
      {:error, _error} -> %{pilot | reason: :pilot_journal_unavailable}
    end
  end

  defp admit(pilot, item, scope, supervisor) do
    run_id = unique_id()

    with {:ok, %{description: @requirements}} <- fetch_jira(item.issue.description),
         :ok <- File.mkdir(pilot.workspace),
         {:ok, workspace_id} <- Worker.workspace_id(pilot.worker, pilot.workspace),
         :ok <- InternalAdmission.admit(pilot.journal, scope, run_id, workspace_id),
         {:ok, run} <-
           InternalWorkflow.new(%{
             run_id: run_id,
             issue_id: elem(scope, 1),
             project_id: elem(scope, 0),
             requirements_revision: digest(@requirements),
             policy_revision: "synthetic-linear-v1",
             independent_review: true
           }) do
      log(pilot, "read simulated Jira requirements key=PILOT-1")
      launch_phase(%{pilot | run: run, source: source(item)}, supervisor)
    else
      _error -> stop(pilot, :pilot_admission_failed)
    end
  end

  defp launch_phase(pilot, supervisor) do
    routing = routing(pilot.run, pilot.image)

    case InternalDispatch.prepare(pilot.worker, pilot.journal, pilot.run, pilot.boot_id, pilot.workspace, routing) do
      {:ok, run, prepared} ->
        worker = pilot.worker
        lease = prepared.lease
        task = Task.Supervisor.async_nolink(supervisor, fn -> Worker.run(worker, lease, 15_000) end)
        log(pilot, "started phase=#{prepared.attempt.phase} provider=#{prepared.decision.target.provider}")
        %{pilot | run: run, prepared: prepared, task: task, started_at: DateTime.utc_now()}

      _deferred_or_failed ->
        stop(pilot, :pilot_dispatch_blocked)
    end
  end

  defp settle_observed(pilot, observed, config) do
    with true <- pinned(config) == pilot.config,
         {:ok, item} <- Linear.read(pilot.scope),
         true <- eligible?(pilot, item),
         {:ok, next, directive} <-
           InternalDispatch.settle(pilot.worker, pilot.journal, pilot.run, pilot.prepared, observed, fn -> verify(pilot) end) do
      advance(%{pilot | run: next, item: item}, directive)
    else
      _error -> stop(pilot, :pilot_worker_settlement_blocked)
    end
  end

  defp advance(pilot, :dispatch), do: pilot

  defp advance(pilot, {:park, :human_review}) do
    # Park first and re-read before the sole mutation attempt.
    with {:ok, item} <- Linear.read(pilot.scope),
         true <- eligible?(pilot, item) do
      log(pilot, "verified all phases; projecting Human Review")
      response = Linear.move_to_review(pilot.scope)

      case Linear.read(pilot.scope) do
        {:ok, %{state_id: id} = item} when id == pilot.scope.review_id ->
          log(pilot, "confirmed state=Human Review")
          confirm_review(%{pilot | item: item})

        _unconfirmed ->
          log(pilot, "Human Review projection unconfirmed result=#{inspect(response)}")
          %{pilot | reason: :pilot_review_transition_unconfirmed}
      end
    else
      _changed -> %{pilot | reason: :pilot_review_source_changed}
    end
  end

  defp advance(pilot, {:park, reason}), do: %{pilot | reason: reason}
  defp advance(pilot, :retry), do: stop(pilot, :pilot_retry_requires_inspection)

  defp confirm_review(pilot) do
    scope = journal_scope(pilot)

    case InternalAdmission.lookup(pilot.journal, scope) do
      {:ok, %{status: :review_pending, run_id: run_id, generation: generation}} ->
        case InternalAdmission.confirm_review(pilot.journal, scope, {run_id, generation}) do
          :ok -> %{pilot | reason: :human_review}
          {:error, _reason} -> %{pilot | reason: :pilot_journal_unavailable}
        end

      {:ok, _other} ->
        %{pilot | reason: :human_review}

      {:error, _reason} ->
        %{pilot | reason: :pilot_journal_unavailable}
    end
  end

  defp verify(%{run: %{phase: :planning, requirements_revision: revision}}),
    do: {:planning, revision, "jira:PILOT-1", [@criteria]}

  defp verify(%{run: run, workspace: workspace}) do
    path = Path.join(workspace, "result.txt")
    size = byte_size(@expected)

    with {:ok, %File.Stat{type: :regular, size: ^size, links: 1}} <- File.lstat(path),
         {:ok, @expected} <- File.read(path) do
      verify_artifact(run, digest(@expected))
    else
      _invalid -> nil
    end
  end

  defp verify_artifact(%{phase: :implementation, requirements_revision: requirements}, revision),
    do: {:implementation, requirements, %{ref: "result.txt", revision: revision}}

  defp verify_artifact(%{phase: :validation, requirements_revision: requirements}, revision),
    do: {:validation, requirements, revision, %{@criteria => "fixture-content-check"}}

  defp verify_artifact(%{phase: :review, requirements_revision: requirements}, revision),
    do: {:review, requirements, revision, {:approved, "fixture-independent-review"}}

  defp routing(run, image) do
    {provider, capability, script} = Map.fetch!(@phase_specs, run.phase)
    alias_name = Atom.to_string(provider)
    scope = %{project: run.project_id, repositories: ["fixture"], data_class: "synthetic", workspace_policy: "isolated"}
    access = if run.phase == :implementation, do: :write, else: :read

    profile = %Profile{
      id: alias_name,
      provider: provider,
      account_key: alias_name,
      scopes: [Map.put(scope, :access, access)],
      options: [%{model: "fixture", effort: nil, capabilities: [capability]}]
    }

    request = %Request{
      run_id: run.run_id,
      phase: run.phase,
      policy_version: run.policy_revision,
      requirements_revision: run.requirements_revision,
      workspace_id: "resolve-before-launch",
      scope: scope,
      profile_bindings: %{provider => alias_name},
      required_capabilities: [capability],
      independent_from: if(run.phase == :review, do: :codex)
    }

    availability = %Availability{
      now_ms: 0,
      identities: %{alias_name => %{status: :verified, account_key: alias_name, expires_at_ms: 1}},
      account_slots: %{{provider, alias_name} => %{running: 0, limit: 1}}
    }

    outcome = ~S(printf '%s\n' '{"version":1,"status":"succeeded"}')
    command = %{image: image, argv: ["/bin/sh", "-ec", script <> "\n" <> outcome]}

    %{request: request, profiles: [profile], availability: availability, command_for: fn _target -> {:ok, command} end}
  end

  defp fetch_jira(link) do
    config = %{"base_url" => "https://jira.fixture.test", "project_key" => "PILOT", "email" => "fixture@example.test", "api_token" => "fixture"}

    request = fn "GET", "/rest/api/3/issue/PILOT-1", _query, nil, _settings ->
      {:ok, %{status: 200, body: %{"key" => "PILOT-1", "fields" => %{"summary" => "Synthetic pilot", "description" => @requirements}}}}
    end

    Jira.fetch_linked_issue(link, config, request_fun: request)
  end

  defp hold_inactive(pilot, reason) do
    scope = journal_scope(pilot)

    case InternalAdmission.lookup(pilot.journal, scope) do
      {:ok, %{run_id: run_id, generation: generation, status: :ready, lease: nil}} ->
        case InternalAdmission.hold(pilot.journal, scope, {run_id, generation}, :parked) do
          :ok -> reason
          {:error, _error} -> :pilot_journal_unavailable
        end

      {:ok, _other} ->
        reason

      {:error, _error} ->
        :pilot_journal_unavailable
    end
  end

  defp open_journal(directory, root, boot) do
    case InternalAdmission.open(directory, root, boot) do
      {:error, :journal_missing} -> InternalAdmission.initialize(directory, root, boot)
      result -> result
    end
  end

  defp pinned(config), do: {config.agent.internal_pilot, config.tracker, config.workspace, config.worker}
  defp journal_scope(pilot), do: {pilot.scope.tracker.project_slug, pilot.scope.issue_id}
  defp unique_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  defp start_state?(value), do: String.downcase(String.trim(value)) in @start_states
  defp absolute?(value), do: is_binary(value) and Path.type(value) == :absolute
  defp uuid?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/, value)

  defp allowed_endpoint?("https://api.linear.app/graphql"), do: true

  defp allowed_endpoint?(endpoint) when is_binary(endpoint) do
    match?(%URI{scheme: "http", host: "127.0.0.1", path: "/graphql", userinfo: nil, query: nil, fragment: nil}, URI.parse(endpoint))
  end

  defp allowed_endpoint?(_endpoint), do: false

  defp log(pilot, message), do: Logger.info("Internal pilot issue_id=#{pilot.scope.issue_id} #{message}")
end
