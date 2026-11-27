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
  alias SymphonyElixir.{InternalAdmission, InternalDispatch, InternalWorkflow, Tracker}
  alias SymphonyElixir.InternalContainerWorker, as: Worker
  alias SymphonyElixir.InternalPilotInventory, as: Inventory
  alias SymphonyElixir.InternalPilotProviders, as: Providers
  alias SymphonyElixir.InternalPilotRepository, as: Repository
  alias SymphonyElixir.Jira.Client, as: Jira
  alias SymphonyElixir.Linear.InternalPilot, as: Linear

  @jira_origin "https://jira.fixture.test"
  @criteria "fixture-response"
  @requirements "Acceptance criteria:\n- The result file contains fixture-response."
  @expected "fixture-response\n"
  @review "Human Review"
  @start_states ["todo", "to do"]
  @demo_modes [:api_demo, :ui_filter, :ui_sort]
  @independent_modes [:multi_agent | @demo_modes]
  @provider_retry_delays [5_000, 15_000]
  @retryable_provider_errors [
    :gemini_pilot_invalid_plan,
    :gemini_pilot_missing_structured_output,
    :gemini_pilot_timeout,
    :codex_pilot_invalid_proposal,
    :codex_pilot_timeout,
    :claude_pilot_invalid_review,
    :claude_pilot_timeout
  ]
  @review_observation_window_ms 20_000
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
    :mode,
    :plan,
    :proposal,
    :review,
    :demo_runner,
    :frontend_runner,
    :demo_evidence,
    :item,
    :source,
    :run,
    :prepared,
    :task,
    :started_at,
    :reason,
    :current,
    :queue_since,
    :provider_retry,
    :review_observation_until,
    provider_retries: %{},
    history: %{}
  ]

  @type t :: %__MODULE__{}

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{agent: %{internal_pilot: nil}}), do: :ok

  def validate(%{agent: %{internal_pilot: pilot}, tracker: tracker, workspace: workspace, worker: worker}) do
    with mode when mode in ["fixture", "codex", "multi_agent", "api_demo", "queue"] <- Map.get(pilot, "implementation", "fixture"),
         true <- configured_runners?(mode, Map.fetch(pilot, "demo_runner"), Map.fetch(pilot, "frontend_runner")),
         {:ok, _since} <- queue_since(mode, Map.get(pilot, "queue_since")),
         settings = Map.drop(pilot, ["implementation", "demo_runner", "frontend_runner", "queue_since"]),
         true <- scoped_settings?(mode, settings),
         %{
           "human_review_state_id" => review,
           "state_directory" => directory,
           "docker_socket" => socket,
           "image" => image
         } <- settings,
         true <- uuid?(review) and absolute?(directory) and absolute?(socket),
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
         {:ok, journal} <- open_journal(settings["state_directory"], root, boot),
         {:ok, since} <- queue_since(settings["implementation"], settings["queue_since"]) do
      pilot = %__MODULE__{
        config: pinned(config),
        scope: scope,
        boot_id: boot,
        journal: journal,
        worker: worker,
        workspace: if(scope.issue_id, do: Path.join(root, "pilot@" <> scope.issue_id), else: root),
        image: settings["image"],
        mode: pilot_mode(settings["implementation"]),
        demo_runner: settings["demo_runner"],
        frontend_runner: settings["frontend_runner"],
        queue_since: since
      }

      {:ok, if(pilot.mode == :queue, do: recover_queue(pilot), else: recover_at_start(pilot))}
    end
  end

  @spec poll(t(), map(), GenServer.server()) :: t()
  def poll(%__MODULE__{mode: :queue} = queue, config, supervisor), do: poll_queue(queue, config, supervisor)

  def poll(%__MODULE__{} = pilot, config, supervisor) do
    cond do
      pilot.reason == :pilot_configuration_changed -> pilot
      pinned(config) != pilot.config -> stop(pilot, :pilot_configuration_changed)
      pilot.reason == :human_review -> pilot
      true -> observe(pilot, supervisor, Linear.read(pilot.scope))
    end
  end

  @spec worker_result(t(), reference(), term(), map()) :: t()
  def worker_result(
        %__MODULE__{mode: :queue, current: %{task: %Task{ref: ref}, run: %{phase: phase}} = current} = queue,
        ref,
        {:provider, phase, {:error, reason}} = result,
        config
      )
      when reason in @retryable_provider_errors do
    attempt = Map.get(queue.provider_retries, phase, 0)

    with delay when is_integer(delay) <- Enum.at(@provider_retry_delays, attempt),
         true <- pinned(config) == queue.config,
         :ok <- verify_provider_retry(current) do
      Process.demonitor(ref, [:flush])
      next_attempt = attempt + 1
      retry = %{attempt: next_attempt, due_at_ms: System.monotonic_time(:millisecond) + delay, error: reason}
      log(current, "retrying provider phase=#{phase} attempt=#{next_attempt} after_ms=#{delay} reason=#{reason}")

      %{queue | current: %{current | task: nil}, provider_retry: retry, provider_retries: Map.put(queue.provider_retries, phase, next_attempt)}
    else
      _unavailable -> finish_queue_run(queue, worker_result(current, ref, result, config))
    end
  end

  def worker_result(%__MODULE__{mode: :queue, current: %__MODULE__{} = current} = queue, ref, result, config) do
    finish_queue_run(queue, worker_result(current, ref, result, config))
  end

  def worker_result(%__MODULE__{task: %Task{ref: ref}} = pilot, ref, result, config) do
    Process.demonitor(ref, [:flush])
    pilot = %{pilot | task: nil}

    case result do
      {:demo, {:ok, evidence}} when pilot.mode in @demo_modes ->
        accept_demo(pilot, evidence, config)

      {:demo, {:error, reason}} when is_atom(reason) ->
        stop(pilot, reason)

      {:provider, phase, {:ok, response}} when phase == pilot.run.phase and is_nil(pilot.prepared) ->
        accept_provider_response(pilot, phase, response, config)

      {:provider, phase, {:error, reason}} when phase == pilot.run.phase and is_atom(reason) ->
        stop(pilot, reason)

      {:ok, observed} ->
        settle_observed(pilot, observed, config)

      _failure ->
        stop(pilot, :pilot_worker_failed)
    end
  end

  def worker_result(pilot, _ref, _result, _config), do: pilot

  defp accept_demo(pilot, evidence, config) do
    if pinned(config) == pilot.config do
      advance_review(%{pilot | demo_evidence: evidence})
    else
      stop(pilot, :pilot_configuration_changed)
    end
  end

  defp accept_provider_response(pilot, phase, response, config) do
    if pinned(config) == pilot.config do
      {key, message} =
        case phase do
          :planning -> {:plan, "received Gemini plan"}
          :implementation -> {:proposal, "received bounded Codex proposal"}
          :review -> {:review, "received Claude Code approval"}
        end

      log(pilot, message)
      Map.replace!(pilot, key, response)
    else
      stop(pilot, :pilot_configuration_changed)
    end
  end

  @spec worker_down(t(), reference()) :: t()
  def worker_down(%__MODULE__{mode: :queue, current: %__MODULE__{} = current} = queue, ref) do
    finish_queue_run(queue, worker_down(current, ref))
  end

  def worker_down(%__MODULE__{task: %Task{ref: ref}} = pilot, ref) do
    stop(%{pilot | task: nil}, :pilot_worker_exited)
  end

  def worker_down(pilot, _ref), do: pilot

  @spec stop(t(), atom()) :: t()
  def stop(%__MODULE__{mode: :queue, current: current} = queue, reason) do
    queue = if current, do: archive_queue_run(queue, stop(current, reason)), else: queue
    %{queue | reason: reason}
  end

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

  defp recover_queue(queue) do
    with {:ok, records} <- InternalAdmission.records(queue.journal),
         :ok <- reconcile_queue_leases(queue, Map.to_list(records)) do
      %{queue | reason: nil}
    else
      _failure -> %{queue | reason: :pilot_queue_recovery_blocked}
    end
  end

  defp reconcile_queue_leases(queue, records) do
    project = queue.scope.tracker.project_slug

    Enum.reduce_while(records, :ok, fn
      {{^project, _issue_id}, %{lease: nil}}, :ok ->
        {:cont, :ok}

      {{^project, _issue_id} = scope, _active}, :ok ->
        case InternalDispatch.recover(queue.worker, queue.journal, scope) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _foreign, :ok ->
        {:halt, {:error, :pilot_queue_project_changed}}
    end)
  end

  defp poll_queue(queue, config, supervisor) do
    cond do
      queue.reason == :pilot_configuration_changed -> queue
      pinned(config) != queue.config -> stop(queue, :pilot_configuration_changed)
      queue.reason == :pilot_queue_recovery_blocked -> recover_queue(queue)
      queue.provider_retry != nil -> poll_provider_retry(queue, config, supervisor)
      queue.current != nil -> finish_queue_run(queue, poll(queue.current, config, supervisor))
      true -> admit_next_queue_issue(queue, supervisor)
    end
  end

  defp poll_provider_retry(%{current: current, provider_retry: retry} = queue, config, supervisor) do
    if System.monotonic_time(:millisecond) >= retry.due_at_ms do
      queue = %{queue | provider_retry: nil}

      case verify_provider_retry(current) do
        :ok -> finish_queue_run(queue, poll(current, config, supervisor))
        {:error, _reason} -> finish_queue_run(queue, stop(current, :pilot_retry_requires_inspection))
      end
    else
      queue
    end
  end

  defp verify_provider_retry(%{run: %{run_id: run_id, generation: generation}, boot_id: boot_id} = pilot) do
    with {:ok, %{run_id: ^run_id, generation: ^generation, boot_id: ^boot_id} = record} <-
           InternalAdmission.lookup(pilot.journal, journal_scope(pilot)),
         %{status: :ready, lease: nil, workspace_id: id} <- record,
         {:ok, ^id} <- Worker.workspace_id(pilot.worker, pilot.workspace) do
      :ok
    else
      _mismatch -> {:error, :pilot_retry_scope_changed}
    end
  end

  defp admit_next_queue_issue(queue, supervisor) do
    tracker = queue.scope.tracker

    with {:ok, records} <- InternalAdmission.records(queue.journal),
         {:ok, candidates} <- Tracker.fetch_issues_by_states(Enum.filter(tracker.active_states, &start_state?/1)) do
      candidates
      |> Enum.sort_by(&{&1.priority || 5, if(&1.created_at, do: DateTime.to_unix(&1.created_at), else: 0), &1.id})
      |> Enum.find_value(queue, &queue_candidate(queue, &1, records, supervisor))
    else
      _unavailable -> queue
    end
  end

  defp queue_candidate(queue, issue, records, supervisor) do
    scope = %{queue.scope | issue_id: issue.id}
    workspace = Path.join(queue.workspace, "pilot@" <> (issue.id || ""))

    with true <- uuid?(issue.id) and issue.dispatchable and after_cutover?(issue.created_at, queue.queue_since),
         false <- Map.has_key?(records, {scope.tracker.project_slug, issue.id}) or File.exists?(workspace),
         mode when not is_nil(mode) <- Enum.find(@demo_modes, &jira_description?(issue.description, jira_url(&1))),
         {:ok, item} <- Linear.read(scope),
         child = %{queue | scope: scope, mode: mode, workspace: workspace, history: %{}},
         true <- eligible?(child, item) do
      finish_queue_run(queue, observe(child, supervisor, {:ok, item}))
    else
      _skip -> nil
    end
  end

  defp finish_queue_run(queue, %{reason: :pilot_lease_unresolved} = current) do
    {_, blocked} = rows(current)
    %{reset_queue_run(queue) | reason: :pilot_queue_recovery_blocked, history: Map.merge(queue.history, blocked)}
  end

  defp finish_queue_run(queue, %{reason: :pilot_review_transition_unconfirmed} = current) do
    now = System.monotonic_time(:millisecond)
    deadline = queue.review_observation_until || now + @review_observation_window_ms

    if now < deadline do
      %{queue | current: current, review_observation_until: deadline}
    else
      archive_queue_run(queue, current)
    end
  end

  defp finish_queue_run(queue, %{reason: reason} = current) when is_nil(reason) or reason == :pilot_demo_pending do
    %{queue | current: current}
  end

  defp finish_queue_run(queue, current) do
    archive_queue_run(queue, current)
  end

  defp archive_queue_run(queue, current) do
    {_, blocked} = rows(current)
    history = Map.merge(queue.history, blocked) |> Enum.sort_by(fn {_id, row} -> row.blocked_at end, {:desc, DateTime}) |> Enum.take(24)
    %{reset_queue_run(queue) | history: Map.new(history)}
  end

  defp reset_queue_run(queue), do: %{queue | current: nil, provider_retry: nil, provider_retries: %{}, review_observation_until: nil}

  defp after_cutover?(_created, nil), do: true
  defp after_cutover?(%DateTime{} = created, cutoff), do: DateTime.compare(created, cutoff) != :lt
  defp after_cutover?(_unknown, _cutoff), do: false

  @spec rows(t()) :: {map(), map()}
  def rows(%__MODULE__{mode: :queue, current: nil, history: history}), do: {%{}, history}

  def rows(%__MODULE__{mode: :queue, current: current, history: history}) do
    {running, blocked} = rows(current)
    {running, Map.merge(history, blocked)}
  end

  def rows(%__MODULE__{item: %{issue: issue}, task: %Task{}} = pilot) do
    {provider, message} = running_phase(pilot)

    entry = %{
      identifier: issue.identifier,
      issue: issue,
      provider: provider,
      workspace_path: pilot.workspace,
      session_id: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: pilot.started_at,
      last_codex_timestamp: pilot.started_at,
      last_codex_message: message,
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

  @spec retry_rows(t()) :: map()
  def retry_rows(%__MODULE__{current: %{item: %{issue: issue}, workspace: workspace}, provider_retry: %{} = retry}) do
    row = %{
      attempt: retry.attempt,
      due_at_ms: retry.due_at_ms,
      error: retry.error |> Atom.to_string() |> String.replace("_", " "),
      identifier: issue.identifier,
      issue_url: issue.url,
      workspace_path: workspace
    }

    %{issue.id => row}
  end

  def retry_rows(_pilot), do: %{}

  defp running_phase(%{prepared: nil, run: %{phase: :planning}}), do: {:gemini, "Gemini is planning"}
  defp running_phase(%{prepared: nil, run: %{phase: :implementation}}), do: {:codex, "Codex is preparing the implementation"}
  defp running_phase(%{prepared: nil, run: %{phase: :review}}), do: {:claude, "Claude Code is reviewing the diff"}
  defp running_phase(%{prepared: nil, run: %{phase: :human_review}, mode: :api_demo}), do: {:gemini, "Gemini is producing the Bruno demos"}
  defp running_phase(%{prepared: nil, run: %{phase: :human_review}}), do: {:gemini, "Gemini is producing the browser demo"}

  defp running_phase(%{prepared: prepared}) do
    {prepared.decision.target.provider, "Internal phase: #{prepared.attempt.phase}"}
  end

  defp observe(pilot, supervisor, {:ok, item}) do
    pilot = %{pilot | item: item}

    cond do
      review_observed?(pilot) -> confirm_review(pilot)
      pilot.reason == :pilot_demo_pending and eligible?(pilot, item) -> launch_demo(pilot, supervisor)
      pilot.reason == :pilot_demo_pending -> stop(pilot, :pilot_issue_changed)
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
    start_state?(item.issue.state) and jira_description?(item.issue.description, jira_url(pilot.mode)) and
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

    with {:ok, %{description: requirements}} <- fetch_jira(item.issue.description, pilot.mode),
         :ok <- File.mkdir(pilot.workspace),
         :ok <- seed_workspace(pilot),
         {:ok, workspace_id} <- Worker.workspace_id(pilot.worker, pilot.workspace),
         :ok <- InternalAdmission.admit(pilot.journal, scope, run_id, workspace_id),
         {:ok, run} <-
           InternalWorkflow.new(%{
             run_id: run_id,
             issue_id: elem(scope, 1),
             project_id: elem(scope, 0),
             requirements_revision: digest(requirements),
             policy_revision: policy_revision(pilot.mode),
             independent_review: pilot.mode != :codex
           }) do
      log(pilot, "read simulated Jira requirements key=#{jira_key(pilot.mode)}")
      launch_phase(%{pilot | run: run, source: source(item)}, supervisor)
    else
      _error -> stop(pilot, :pilot_admission_failed)
    end
  end

  defp seed_workspace(%{mode: :fixture}), do: :ok
  defp seed_workspace(%{workspace: workspace, mode: mode}), do: Repository.seed(workspace, mode)

  defp launch_phase(%{mode: mode, run: %{phase: :planning}, plan: nil, workspace: workspace} = pilot, supervisor)
       when mode in @independent_modes do
    launch_provider(pilot, supervisor, :gemini, fn -> Providers.plan(workspace, mode) end)
  end

  defp launch_phase(%{mode: mode, run: %{phase: :implementation}, proposal: nil, workspace: workspace} = pilot, supervisor)
       when mode in [:codex | @independent_modes] do
    plan_summary = if pilot.plan, do: pilot.plan.summary
    launch_provider(pilot, supervisor, :codex, fn -> Repository.propose(workspace, plan_summary, mode) end)
  end

  defp launch_phase(%{mode: mode, run: %{phase: :review, artifact: %{revision: revision}}, review: nil} = pilot, supervisor)
       when mode in @independent_modes do
    workspace = pilot.workspace

    case Repository.artifact(workspace, mode) do
      {:ok, %{revision: ^revision} = artifact} ->
        launch_provider(pilot, supervisor, :claude, fn -> Providers.review(workspace, artifact, mode) end)

      _changed ->
        stop(pilot, :pilot_review_artifact_changed)
    end
  end

  defp launch_phase(pilot, supervisor) do
    routing = routing(pilot)

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

  defp launch_provider(pilot, supervisor, provider, run) do
    phase = pilot.run.phase
    task = Task.Supervisor.async_nolink(supervisor, fn -> {:provider, phase, run.()} end)
    log(pilot, "started authenticated provider=#{provider} phase=#{phase}")
    %{pilot | prepared: nil, task: task, started_at: DateTime.utc_now()}
  end

  defp launch_demo(pilot, supervisor) do
    %{workspace: workspace, mode: mode, run: %{artifact: %{revision: revision}}} = pilot
    {client, runner} = if mode == :api_demo, do: {"bruno", pilot.demo_runner}, else: {"browser", pilot.frontend_runner}
    task = Task.Supervisor.async_nolink(supervisor, fn -> {:demo, Providers.demo(workspace, revision, runner, mode)} end)
    log(pilot, "started authenticated provider=gemini phase=demo client=#{client}")
    %{pilot | prepared: nil, task: task, started_at: DateTime.utc_now(), reason: nil}
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
  defp advance(%{mode: mode} = pilot, {:park, :human_review}) when mode in @demo_modes, do: %{pilot | reason: :pilot_demo_pending}
  defp advance(pilot, {:park, :human_review}), do: advance_review(pilot)
  defp advance(pilot, {:park, reason}), do: %{pilot | reason: reason}
  defp advance(pilot, :retry), do: stop(pilot, :pilot_retry_requires_inspection)

  defp advance_review(pilot) do
    # Park first and re-read before the sole mutation attempt.
    with {:ok, item} <- Linear.read(pilot.scope),
         true <- eligible?(pilot, item),
         {:ok, description} <- review_description(pilot, item) do
      log(pilot, "verified all phases; projecting Human Review")
      response = Linear.move_to_review(pilot.scope, description)

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

  defp confirm_review(pilot) do
    scope = journal_scope(pilot)

    with {:ok, record} <- InternalAdmission.lookup(pilot.journal, scope),
         :ok <- verify_review_observation(pilot, record),
         :ok <- confirm_review_record(pilot, scope, record) do
      %{pilot | reason: :human_review}
    else
      {:error, :pilot_review_evidence_unconfirmed} -> %{pilot | reason: :pilot_review_evidence_unconfirmed}
      {:error, _reason} -> %{pilot | reason: :pilot_journal_unavailable}
    end
  end

  defp confirm_review_record(pilot, scope, %{status: :review_pending, run_id: run_id, generation: generation}) do
    InternalAdmission.confirm_review(pilot.journal, scope, {run_id, generation})
  end

  defp confirm_review_record(_pilot, _scope, _record), do: :ok

  defp verify_review_observation(%{mode: :fixture}, _record), do: :ok

  defp verify_review_observation(pilot, %{status: status}) when status in [:review_pending, :human_review] do
    with {:ok, artifact} <- Repository.artifact(pilot.workspace, pilot.mode),
         body when is_binary(body) <- pilot.item.issue.description,
         true <- Repository.review_observed?(body, artifact),
         true <- pilot.mode not in @independent_modes or Providers.observed?(body, artifact.revision),
         true <- demos_observed?(pilot.mode, body) do
      :ok
    else
      _unconfirmed -> {:error, :pilot_review_evidence_unconfirmed}
    end
  end

  defp verify_review_observation(_pilot, _record), do: {:error, :pilot_review_evidence_unconfirmed}

  defp review_description(%{mode: :fixture}, _item), do: {:ok, nil}

  defp review_description(%{run: %{artifact: %{revision: revision}}} = pilot, %{issue: %{description: description}})
       when is_binary(description) do
    with {:ok, %{revision: ^revision} = artifact} <- Repository.artifact(pilot.workspace, pilot.mode),
         {:ok, demo} <- demo_description(pilot, revision) do
      provider = if pilot.mode in @independent_modes, do: Providers.evidence(pilot.plan, pilot.review), else: ""
      {:ok, Repository.review_description(description, artifact, provider <> demo, pilot.mode)}
    else
      _unverified -> {:error, :codex_pilot_unverified_artifact}
    end
  end

  defp review_description(_pilot, _item), do: {:error, :codex_pilot_unverified_artifact}
  defp demo_description(%{mode: :api_demo, demo_evidence: evidence}, revision), do: Inventory.demos(evidence, revision)

  defp demo_description(%{mode: mode, demo_evidence: evidence}, revision) when mode in [:ui_filter, :ui_sort],
    do: SymphonyElixir.InternalPilotFrontend.demo(evidence, revision)

  defp demo_description(_pilot, _revision), do: {:ok, ""}

  defp demos_observed?(:api_demo, body), do: Inventory.demos_observed?(body)
  defp demos_observed?(mode, body) when mode in [:ui_filter, :ui_sort], do: SymphonyElixir.InternalPilotFrontend.demo_observed?(body)
  defp demos_observed?(_mode, _body), do: true

  defp verify(%{mode: mode, run: %{phase: :planning, requirements_revision: requirements}, plan: %{revision: plan}})
       when mode in @independent_modes,
       do: {:planning, requirements, "gemini-plan:" <> plan, [criterion(mode)]}

  defp verify(%{mode: mode, run: %{phase: :planning, requirements_revision: revision}}),
    do: {:planning, revision, "jira:" <> jira_key(mode), [criterion(mode)]}

  defp verify(%{mode: mode, workspace: workspace} = pilot) when mode in [:codex | @independent_modes] do
    case Repository.artifact(workspace, mode) do
      {:ok, artifact} -> verify_repository(pilot, artifact)
      {:error, _reason} -> nil
    end
  end

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

  defp verify_repository(%{run: %{phase: :implementation, requirements_revision: requirements}}, %{revision: revision, ref: ref}),
    do: {:implementation, requirements, %{ref: ref, revision: revision}}

  defp verify_repository(%{mode: mode, run: %{phase: :validation, requirements_revision: requirements}}, %{revision: revision}),
    do: {:validation, requirements, revision, %{criterion(mode) => "offline-regression-tests"}}

  defp verify_repository(%{run: %{phase: :review, requirements_revision: requirements}, review: %{revision: revision}}, %{revision: revision}),
    do: {:review, requirements, revision, {:approved, "claude-review:" <> revision}}

  defp verify_repository(_pilot, _artifact), do: nil

  defp verify_artifact(%{phase: :implementation, requirements_revision: requirements}, revision),
    do: {:implementation, requirements, %{ref: "result.txt", revision: revision}}

  defp verify_artifact(%{phase: :validation, requirements_revision: requirements}, revision),
    do: {:validation, requirements, revision, %{@criteria => "fixture-content-check"}}

  defp verify_artifact(%{phase: :review, requirements_revision: requirements}, revision),
    do: {:review, requirements, revision, {:approved, "fixture-independent-review"}}

  defp routing(%{mode: mode, run: run} = pilot) do
    {provider, capability, command} = phase_command(pilot)
    alias_name = Atom.to_string(provider)
    scope = %{project: run.project_id, repositories: [policy_revision(mode)], data_class: "synthetic", workspace_policy: "isolated"}
    access = if run.phase == :implementation, do: :write, else: :read

    profile = %Profile{
      id: alias_name,
      provider: provider,
      account_key: alias_name,
      scopes: [Map.put(scope, :access, access)],
      options: [%{model: profile_model(mode, run.phase), effort: nil, capabilities: [capability]}]
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

    %{request: request, profiles: [profile], availability: availability, command_for: fn _target -> {:ok, command} end}
  end

  defp profile_model(mode, :planning) when mode in @independent_modes, do: Providers.gemini_model()
  defp profile_model(mode, :review) when mode in @independent_modes, do: "claude"
  defp profile_model(mode, :implementation) when mode in [:codex | @independent_modes], do: "codex"
  defp profile_model(_mode, _phase), do: "fixture"

  defp phase_command(%{mode: mode, run: %{phase: phase}, image: image, proposal: proposal}) when mode in @independent_modes do
    {provider, capability, _script} = Map.fetch!(@phase_specs, phase)
    {provider, capability, Repository.command(phase, image, proposal, mode)}
  end

  defp phase_command(%{mode: :codex, run: %{phase: phase}, image: image, proposal: proposal}) do
    {_provider, capability, _script} = Map.fetch!(@phase_specs, phase)
    {:codex, capability, Repository.command(phase, image, proposal, :codex)}
  end

  defp phase_command(%{run: %{phase: phase}, image: image}) do
    {provider, capability, script} = Map.fetch!(@phase_specs, phase)
    outcome = ~S(printf '%s\n' '{"version":1,"status":"succeeded"}')
    {provider, capability, %{image: image, argv: ["/bin/sh", "-ec", script <> "\n" <> outcome]}}
  end

  defp jira_description?(body, url) when is_binary(body),
    do: String.trim(body) in [url, "<#{url}>", "[#{url}](#{url})", "[#{url}](<#{url}>)"]

  defp jira_description?(_body, _url), do: false
  defp pilot_mode("codex"), do: :codex
  defp pilot_mode("multi_agent"), do: :multi_agent
  defp pilot_mode("api_demo"), do: :api_demo
  defp pilot_mode("queue"), do: :queue
  defp pilot_mode(_default), do: :fixture
  defp jira_url(mode), do: @jira_origin <> "/browse/" <> jira_key(mode)
  defp jira_key(:fixture), do: "PILOT-1"
  defp jira_key(:codex), do: "PILOT-2"
  defp jira_key(:multi_agent), do: "PILOT-3"
  defp jira_key(:api_demo), do: "PILOT-4"
  defp jira_key(:ui_filter), do: "PILOT-5"
  defp jira_key(:ui_sort), do: "PILOT-6"
  defp criterion(:fixture), do: @criteria
  defp criterion(:api_demo), do: "inventory-availability-contract"
  defp criterion(mode) when mode in [:ui_filter, :ui_sort], do: "inventory-catalog-interaction"
  defp criterion(_repository_mode), do: "version-label-normalization"
  defp policy_revision(:fixture), do: "synthetic-linear-v1"
  defp policy_revision(:codex), do: "personal-codex-v1"
  defp policy_revision(:multi_agent), do: "personal-multi-agent-v1"
  defp policy_revision(:api_demo), do: "personal-api-demo-v1"
  defp policy_revision(mode) when mode in [:ui_filter, :ui_sort], do: "personal-frontend-demo-v1"
  defp jira_requirements(:fixture), do: @requirements
  defp jira_requirements(repository_mode), do: Repository.requirements(repository_mode)

  defp configured_runners?("api_demo", {:ok, path}, :error), do: absolute?(path)
  defp configured_runners?("queue", {:ok, api}, {:ok, frontend}), do: absolute?(api) and absolute?(frontend)
  defp configured_runners?(mode, :error, :error), do: mode not in ["api_demo", "queue"]
  defp configured_runners?(_mode, _api, _frontend), do: false

  defp queue_since(_mode, nil), do: {:ok, nil}

  defp queue_since("queue", value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> {:ok, date}
      _invalid -> :error
    end
  end

  defp queue_since(_mode, _value), do: :error

  defp scoped_settings?("queue", settings), do: map_size(settings) == 4 and not Map.has_key?(settings, "issue_id")
  defp scoped_settings?(_mode, %{"issue_id" => issue} = settings), do: map_size(settings) == 5 and uuid?(issue)
  defp scoped_settings?(_mode, _settings), do: false

  defp fetch_jira(link, mode) do
    key = jira_key(mode)
    endpoint = "/rest/api/3/issue/" <> key
    config = %{"base_url" => @jira_origin, "project_key" => "PILOT", "email" => "fixture@example.test", "api_token" => "fixture"}

    request = fn "GET", ^endpoint, _query, nil, _settings ->
      {:ok, %{status: 200, body: %{"key" => key, "fields" => %{"summary" => "Synthetic pilot", "description" => jira_requirements(mode)}}}}
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
