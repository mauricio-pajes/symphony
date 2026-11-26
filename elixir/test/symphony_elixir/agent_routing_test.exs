defmodule SymphonyElixir.AgentRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentRouting, HeadlessAgent, Jira, PathSafety}
  alias SymphonyElixir.Config.Schema

  @routes %{
    jira_intake: nil,
    providers_by_state: %{"planning" => "gemini", "review" => "claude"},
    classify_scope_states: ["planning"]
  }

  test "routes clear scopes by state and only consults the classifier for ambiguous intake" do
    issue = %Issue{state: "Planning", title: "New filter", description: "Ticket content"}
    no_classifier = fn _ -> flunk("unexpected classification") end

    assert AgentRouting.select(issue, "### Acceptance criteria\n- Filters by status", @routes, no_classifier) ==
             {:ok, :gemini}

    assert AgentRouting.select(%{issue | state: "Review"}, "", @routes, no_classifier) == {:ok, :claude}
    assert AgentRouting.select(%{issue | state: "In Progress"}, "", @routes, no_classifier) == {:ok, :codex}

    assert AgentRouting.select(issue, "Acceptance criteria: ", @routes, fn prompt ->
             assert prompt =~ "Ticket content"
             {:ok, "review\n"}
           end) == {:ok, :claude}

    assert AgentRouting.select(%{issue | labels: ["scope-unclear"]}, "Acceptance criteria: filters", @routes, fn _ ->
             {:ok, "implementation"}
           end) == {:ok, :codex}

    assert AgentRouting.select(issue, "", @routes, fn _ -> {:ok, "unclear"} end) == {:ok, :gemini}
    assert AgentRouting.select(issue, "", @routes, fn _ -> {:ok, "multimodal"} end) == {:ok, :gemini}
    assert AgentRouting.select(issue, "", @routes, fn _ -> {:ok, "unknown"} end) == {:error, :invalid_scope_classification}
    assert AgentRouting.select(%{issue | state: nil}, "", @routes, no_classifier) == {:ok, :codex}
    assert AgentRouting.phase_changed?(issue, %{issue | state: "Review"}, @routes)
    refute AgentRouting.phase_changed?(issue, %{issue | state: "planning "}, @routes)
    refute AgentRouting.phase_changed?(%{issue | state: "Todo"}, %{issue | state: "In Progress"}, @routes)
  end

  test "validates routed states and normalizes configuration" do
    config = %{
      "tracker" => %{"kind" => "memory", "active_states" => ["Planning"]},
      "agent" => %{"providers_by_state" => %{" Planning " => "gemini"}, "classify_scope_states" => ["Planning"]}
    }

    assert {:ok, settings} = Schema.parse(config)
    assert settings.agent.providers_by_state == %{"planning" => "gemini"}
    assert :ok = AgentRouting.validate_settings(settings)

    assert {:error, :agent_routing_requires_local_worker} =
             AgentRouting.validate_settings(%{settings | worker: %{settings.worker | ssh_hosts: ["example"]}})

    assert {:error, :agent_routing_requires_active_states} =
             AgentRouting.validate_settings(%{settings | tracker: %{settings.tracker | active_states: ["Todo"]}})

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(put_in(config, ["agent", "providers_by_state"], %{"Planning" => "other"}))

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(put_in(config, ["agent", "claude_command"], []))
  end

  test "validates Jira intake and scrubs both the standard and configured credentials from agent bindings" do
    workflow = Workflow.workflow_file_path()
    provider = %{"base_url" => "https://blaze.example", "email" => "$SYMPHONY_TEST_JIRA_EMAIL", "api_token" => "$SYMPHONY_TEST_JIRA_TOKEN"}

    for {name, value} <- [{"SYMPHONY_TEST_JIRA_EMAIL", "test@example.com"}, {"SYMPHONY_TEST_JIRA_TOKEN", "fixture-token"}] do
      previous = System.get_env(name)
      on_exit(fn -> restore_env(name, previous) end)
      System.put_env(name, value)
    end

    settings = %{tracker: %{kind: "memory"}, agent: %{jira_intake: provider}}
    File.write!(workflow, "---\n#{Jason.encode!(settings)}\n---\n")
    assert :ok = WorkflowStore.force_reload()

    assert Enum.sort(Tracker.bind_agent_tools().secret_environment_names) ==
             ["JIRA_API_TOKEN", "JIRA_EMAIL", "SYMPHONY_TEST_JIRA_EMAIL", "SYMPHONY_TEST_JIRA_TOKEN"]
  end

  test "keeps the Linear dispatch identity when enriching it with Jira context" do
    issue = %Issue{id: "linear-id", identifier: "WORK-1", state: "Todo", description: "https://blaze.example/browse/ASH-18"}
    settings = %{@routes | jira_intake: %{}}

    fetcher = fn description, %{} ->
      assert description == issue.description
      {:ok, %{description: "Acceptance criteria: filters", context: "Jira requirements"}}
    end

    assert {:ok, enriched, "Acceptance criteria: filters"} = AgentRouting.enrich(issue, settings, fetcher)
    assert %{id: "linear-id", identifier: "WORK-1", state: "Todo"} = enriched
    assert enriched.description =~ "Jira requirements"
    assert {:ok, ^issue, _} = AgentRouting.enrich(issue, settings, fn _, _ -> {:ok, nil} end)

    assert {:error, {:jira_intake_failed, :jira_request_failed}} =
             AgentRouting.enrich(issue, settings, fn _, _ -> {:error, {:jira_api_request, "protected details"}} end)

    assert {:error, {:jira_intake_failed, {:jira_api_status, 403}}} =
             AgentRouting.enrich(issue, settings, fn _, _ -> {:error, {:jira_api_status, 403}} end)
  end

  test "fetches Jira using the configured origin and never follows an untrusted link" do
    provider = %{"base_url" => "https://blaze.example", "email" => "test@example.com", "api_token" => "test"}

    request = fn method, path, query, body, settings ->
      assert method == "GET"
      assert path == "/rest/api/3/issue/ASH-18"
      assert query["fields"] =~ "comment"
      assert body == nil
      assert settings.base_url == "https://blaze.example"
      assert settings.follow_redirects == false

      {:ok,
       %{
         status: 200,
         body: %{
           "key" => "ASH-18",
           "fields" => %{
             "summary" => "Add filter",
             "description" => %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => [%{"text" => "Acceptance criteria: filter by state"}]}]},
             "comment" => %{"comments" => [%{"body" => "Use current permissions"}]}
           }
         }
       }}
    end

    assert {:ok, context} =
             Jira.Client.fetch_linked_issue("[Jira](https://blaze.example/browse/ASH-18)", provider, request_fun: request)

    assert context.description == "Acceptance criteria: filter by state"
    assert context.context =~ "Jira ASH-18: Add filter"
    assert context.context =~ "Use current permissions"

    assert {:ok, nil} =
             Jira.Client.fetch_linked_issue("https://blaze.example.evil/browse/ASH-18", provider, request_fun: request)

    assert {:error, :multiple_linked_jira_issues} =
             Jira.Client.fetch_linked_issue("https://blaze.example/browse/ASH-18 https://blaze.example/browse/ASH-19", provider, request_fun: request)

    assert {:error, :jira_intake_project_mismatch} =
             Jira.Client.fetch_linked_issue("https://blaze.example/browse/ASH-18", Map.put(provider, "project_key", "OTHER"), request_fun: request)
  end

  test "runs real subprocesses for routed CLI turns and keeps tracker credentials out of their environment" do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    workspace = Path.join(root, "TASK-1")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)

    previous = System.get_env("SYMPHONY_TEST_SECRET")
    on_exit(fn -> restore_env("SYMPHONY_TEST_SECRET", previous) end)
    System.put_env("SYMPHONY_TEST_SECRET", "secret")

    command = fn result ->
      [
        "/bin/sh",
        "-c",
        "test -z \"${SYMPHONY_TEST_SECRET:-}\" && cat > captured && printf '%s\\n' '$result'"
        |> String.replace("$result", Jason.encode!(result))
      ]
    end

    assert {:ok, "reviewed"} =
             HeadlessAgent.run(
               :claude,
               command.(%{type: "result", is_error: false, result: "reviewed"}),
               workspace,
               "Review this patch",
               secret_names: ["SYMPHONY_TEST_SECRET"]
             )

    assert File.read!(Path.join(workspace, "captured")) == "Review this patch"

    assert {:ok, "criteria"} =
             HeadlessAgent.run(
               :gemini,
               command.(%{event: "result", result: %{status: "SUCCESS", response: "criteria"}}),
               workspace,
               "Analyze the ticket",
               secret_names: ["SYMPHONY_TEST_SECRET"]
             )

    assert %{"event" => "user", "message" => %{"content" => "Analyze the ticket"}} =
             workspace |> Path.join("captured") |> File.read!() |> Jason.decode!()

    assert {:ok, "review"} =
             HeadlessAgent.run(
               :classifier,
               command.(%{type: "item.completed", item: %{type: "agent_message", text: "review"}}),
               workspace,
               "Classify this ticket",
               secret_names: ["SYMPHONY_TEST_SECRET"]
             )

    assert {:error, :invalid_headless_workspace} =
             HeadlessAgent.run(:claude, ["/bin/true"], root, "Off-limits", [])

    assert {:error, {:missing_agent_result, :claude}} =
             HeadlessAgent.run(:claude, ["/bin/sh", "-c", "exit 0"], workspace, "Missing result", [])

    assert {:error, {:agent_exit, :claude, 7}} =
             HeadlessAgent.run(:claude, ["/bin/sh", "-c", "exit 7"], workspace, "Error result", [])

    assert {:error, {:agent_executable_missing, :claude}} =
             HeadlessAgent.run(:claude, ["/nonexistent/symphony-test-cli"], workspace, "Missing CLI", [])

    assert {:error, {:agent_launch_failed, :claude, ArgumentError}} =
             HeadlessAgent.run(:claude, ["/bin/sh", "\0"], workspace, "Invalid launcher argument", [])

    assert {:error, {:missing_agent_result, :claude}} =
             HeadlessAgent.run(:claude, ["/bin/sh", "-c", "echo '{\"type\":\"progress\"}'"], workspace, "No final result", [])

    assert {:error, {:agent_output_too_large, :claude}} =
             HeadlessAgent.run(:claude, ["/bin/sh", "-c", "head -c 9000000 /dev/zero"], workspace, "Oversized line", [])
  end

  test "a headless timeout terminates the process group before returning" do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    workspace = Path.join(root, "TASK-1")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)

    command = ["/bin/sh", "-c", "sleep 0.5; touch late-write"]
    assert {:error, {:agent_timeout, :gemini}} = HeadlessAgent.run(:gemini, command, workspace, "Plan", timeout_ms: 50)
    Process.sleep(600)
    refute File.exists?(Path.join(workspace, "late-write"))
  end

  test "the agent process group is stopped when its worker is cancelled" do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    workspace = Path.join(root, "TASK-1")
    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)

    parent = self()
    command = ["/bin/sh", "-c", "echo '{}'; sleep 0.5; touch late-write"]

    {owner, ref} =
      spawn_monitor(fn ->
        HeadlessAgent.run(:gemini, command, workspace, "Plan", on_progress: fn -> send(parent, :progress) end)
      end)

    assert_receive :progress
    assert_receive :progress
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    Process.sleep(600)
    refute File.exists?(Path.join(workspace, "late-write"))
  end

  test "the worker selects each provider and keeps its workspace on a phase change" do
    workflow = Workflow.workflow_file_path()
    root = Path.join(Path.dirname(workflow), "workspaces")

    command = fn marker, event ->
      ["/bin/sh", "-c", "cat > #{marker}; printf '%s\\n' '#{Jason.encode!(event)}'"]
    end

    config = %{
      tracker: %{kind: "memory", active_states: ["Planning", "Agent Review"]},
      workspace: %{root: root},
      agent: %{
        providers_by_state: %{"Planning" => "gemini", "Agent Review" => "claude"},
        classify_scope_states: ["Planning"],
        classifier_command: command.("scope", %{type: "item.completed", item: %{type: "agent_message", text: "review"}}),
        gemini_command: command.("plan", %{event: "result", result: %{status: "SUCCESS", response: "criteria"}}),
        claude_command: command.("review", %{type: "result", is_error: false, result: "reviewed"})
      }
    }

    File.write!(workflow, "---\n#{Jason.encode!(config)}\n---\nReview {{ issue.identifier }}\n")
    assert :ok = WorkflowStore.force_reload()

    issue = %Issue{id: "id", identifier: "WORK-1", state: "Planning", description: "Acceptance criteria: filter by state"}
    assert :ok = AgentRunner.run(issue)
    workspace = Path.join(root, "WORK-1")
    assert File.read!(Path.join(workspace, "plan")) =~ "Assigned phase: Planning"
    refute File.exists?(Path.join(workspace, "review"))

    assert :ok = AgentRunner.run(%{issue | description: "Scope needs work"})
    assert File.read!(Path.join(workspace, "review")) =~ "Assigned phase: Planning"

    assert :ok = AgentRunner.run(%{issue | state: "Agent Review"})
    assert File.read!(Path.join(workspace, "review")) =~ "Assigned phase: Agent Review"
    assert File.exists?(Path.join(workspace, "plan"))
  end

  test "the orchestrator hands off a shared workspace and pauses it for human review" do
    workflow = Workflow.workflow_file_path()
    root = Path.join(Path.dirname(workflow), "workspaces")
    workspace = Path.join(root, "HANDOFF-1")
    plan_result = Jason.encode!(%{event: "result", result: %{status: "SUCCESS", response: "criteria"}})
    review_result = Jason.encode!(%{type: "result", is_error: false, result: "reviewed"})

    config = %{
      tracker: %{kind: "memory", active_states: ["Planning", "Agent Review"]},
      polling: %{interval_ms: 60_000},
      workspace: %{root: root},
      agent: %{
        max_concurrent_agents: 1,
        providers_by_state: %{"Planning" => "gemini", "Agent Review" => "claude"},
        gemini_command: [
          "/bin/sh",
          "-ce",
          "touch planning; while [ ! -f release ]; do sleep 0.05; done; touch plan-complete; printf '%s\n' '#{plan_result}'"
        ],
        claude_command: [
          "/bin/sh",
          "-ce",
          "test -f plan-complete; touch reviewing; while [ ! -f reviewed ]; do sleep 0.05; done; printf '%s\n' '#{review_result}'"
        ]
      }
    }

    File.write!(workflow, "---\n#{Jason.encode!(config)}\n---\nWork on {{ issue.identifier }}\n")
    assert :ok = WorkflowStore.force_reload()

    issue = %Issue{id: "handoff", identifier: "HANDOFF-1", state: "Planning", title: "Handoff", dispatchable: true}

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Orchestrator.request_refresh()
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Orchestrator.request_refresh()
    assert await(fn -> File.exists?(Path.join(workspace, "planning")) end)
    assert {:ok, canonical_workspace} = PathSafety.canonicalize(workspace)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Agent Review"}])
    Orchestrator.request_refresh()

    assert await(fn ->
             match?(%{running: [%{state: "Agent Review", workspace_path: ^canonical_workspace}]}, Orchestrator.snapshot())
           end)

    refute File.exists?(Path.join(workspace, "reviewing"))
    File.touch!(Path.join(workspace, "release"))
    assert await(fn -> File.exists?(Path.join(workspace, "reviewing")) end)
    assert File.exists?(Path.join(workspace, "plan-complete"))

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Human Review"}])
    Orchestrator.request_refresh()
    assert await(fn -> match?(%{running: [], retrying: []}, Orchestrator.snapshot()) end)
    assert File.dir?(workspace)
  end

  defp await(fun) do
    Enum.any?(1..200, fn _ ->
      if fun.() do
        true
      else
        Process.sleep(25)
        false
      end
    end)
  end
end
