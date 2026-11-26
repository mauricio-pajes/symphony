defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with the selected agent.
  """

  require Logger
  alias SymphonyElixir.{AgentRouting, Config, HeadlessAgent, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_selected_agent(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_selected_agent(workspace, issue, recipient, opts, worker_host) do
    settings = Config.settings!()
    classifier = fn prompt -> run_headless(:classifier, settings.agent.classifier_command, workspace, prompt, issue, recipient) end

    with {:ok, issue, requirements} <- AgentRouting.enrich(issue, settings.agent),
         {:ok, provider} <- AgentRouting.select(issue, requirements, settings.agent, classifier) do
      Logger.info("Selected agent provider=#{provider} #{issue_context(issue)}")
      run_provider(provider, workspace, issue, recipient, Keyword.put(opts, :agent_settings, settings.agent), worker_host)
    end
  end

  defp run_provider(:codex, workspace, issue, recipient, opts, worker_host) do
    run_codex_turns(workspace, issue, recipient, opts, worker_host)
  end

  defp run_provider(provider, workspace, issue, recipient, opts, nil) do
    command = headless_command(provider, opts[:agent_settings])
    prompt = build_turn_prompt(issue, opts, 1, 1)

    with {:ok, _result} <- run_headless(provider, command, workspace, prompt, issue, recipient), do: :ok
  end

  defp run_provider(_provider, _workspace, _issue, _recipient, _opts, _worker_host),
    do: {:error, :agent_routing_requires_local_worker}

  defp headless_command(:claude, agent), do: agent.claude_command
  defp headless_command(:gemini, agent), do: agent.gemini_command

  defp run_headless(provider, command, workspace, prompt, issue, recipient) do
    on_progress = fn ->
      send_codex_update(recipient, issue, %{
        event: :agent_progress,
        timestamp: DateTime.utc_now(),
        message: "#{provider} is running"
      })
    end

    HeadlessAgent.run(provider, command, workspace, prompt,
      secret_names: Tracker.bind_agent_tools().secret_environment_names,
      timeout_ms: headless_timeout(provider),
      on_progress: on_progress
    )
  end

  defp headless_timeout(:classifier), do: min(60_000, Config.settings!().codex.turn_timeout_ms)
  defp headless_timeout(_provider), do: Config.settings!().codex.turn_timeout_ms

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      with {:continue, refreshed_issue} <- continue_with_issue?(issue, issue_state_fetcher),
           true <- turn_number < max_turns,
           false <- AgentRouting.phase_changed?(issue, refreshed_issue, opts[:agent_settings]) do
        do_run_codex_turns(
          app_session,
          workspace,
          refreshed_issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number + 1,
          max_turns
        )
      else
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    prompt = PromptBuilder.build_prompt(issue, opts)

    if opts[:agent_settings].providers_by_state == %{} do
      prompt
    else
      "Assigned phase: #{issue.state}. Follow the workflow instructions for this phase. End this turn when the tracker advances to the next assigned phase.\n\n" <> prompt
    end
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
