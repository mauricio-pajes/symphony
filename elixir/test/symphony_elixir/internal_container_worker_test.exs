defmodule SymphonyElixir.InternalContainerWorkerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentProfiles.{Availability, Profile}
  alias SymphonyElixir.AgentRouter.Request
  alias SymphonyElixir.{InternalAdmission, InternalContainerWorker, InternalDispatch, InternalWorkflow}

  @scope {"fixture", "issue-1"}
  @boot "boot-a"
  @writer "while true; do printf tick >> ticks; sleep 0.1; done"
  @readonly """
  test "$(id -u)" -ne 0
  test ! -S /var/run/docker.sock
  test ! -e /state/admission.json
  if (touch /workspace/readonly-probe) 2>/dev/null; then exit 91; fi
  if (touch /root-fs-probe) 2>/dev/null; then exit 92; fi
  touch /tmp/writable-probe
  """

  if System.get_env("SYMPHONY_RUN_CONTAINER_TESTS") != "1" do
    @moduletag skip: "set SYMPHONY_RUN_CONTAINER_TESTS=1 for the local Docker fixture"
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-container-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "issue")
    state = Path.join(root, "state")
    File.mkdir_p!(workspace)
    File.mkdir!(state)
    File.chmod!(state, 0o700)
    socket = System.fetch_env!("SYMPHONY_TEST_DOCKER_SOCKET")
    image = System.fetch_env!("SYMPHONY_TEST_DOCKER_IMAGE")
    assert {:ok, worker} = InternalContainerWorker.open(socket, workspace_root)

    on_exit(fn ->
      case InternalAdmission.open(state, workspace_root, "cleanup") do
        {:ok, journal} ->
          _ = InternalDispatch.recover(worker, journal, @scope)

        {:error, :journal_missing} ->
          :ok
      end

      File.rm_rf!(root)
    end)

    %{state: state, workspace_root: workspace_root, workspace: workspace, socket: socket, worker: worker, image: image}
  end

  test "routes four isolated phases and persists Human Review before releasing the claim", fixture do
    %{worker: worker, workspace: workspace} = fixture
    {:ok, journal} = InternalAdmission.initialize(fixture.state, fixture.workspace_root, @boot)
    {:ok, workspace_id} = InternalContainerWorker.workspace_id(worker, workspace)
    :ok = InternalAdmission.admit(journal, @scope, "run-1", workspace_id)
    {:ok, run} = workflow()

    assert {:ok, planning, plan} = prepare(run, journal, fixture, :research, @readonly)
    assert plan.decision.target.provider == :gemini
    assert {:ok, %{generation: 1, lease: %{process_identity: identity}}} = InternalAdmission.lookup(journal, @scope)
    assert String.starts_with?(identity, "docker:")

    assert {:error, :lease_unresolved} = prepare(run, journal, fixture, :research, @readonly)
    assert {:ok, 0} = InternalContainerWorker.run(worker, plan.lease, 5000)
    assert {:error, :container_already_started} = InternalContainerWorker.run(worker, plan.lease, 5000)

    assert {:ok, implementing, :dispatch} =
             InternalDispatch.settle(worker, journal, planning, plan, success(), fn ->
               {:planning, "req-1", "plan-1", ["response-field"]}
             end)

    assert {:ok, building, build} = prepare(implementing, journal, fixture, :implement, "printf fixture > artifact")
    assert build.decision.target.provider == :codex
    assert build.attempt.handoff.plan_ref == "plan-1"
    refute File.exists?(Path.join(workspace, "artifact"))

    assert {:error, :stale_attempt} =
             InternalDispatch.settle(worker, journal, building, plan, success(), fn -> flunk("stale result was verified") end)

    assert {:ok, 0} = InternalContainerWorker.run(worker, build.lease, 5000)

    assert {:ok, validating, :dispatch} =
             InternalDispatch.settle(worker, journal, building, build, success(), fn ->
               assert {:error, :container_missing} = InternalContainerWorker.run(worker, build.lease, 5000)
               assert File.read!(Path.join(workspace, "artifact")) == "fixture"
               {:implementation, "req-1", %{ref: "artifact", revision: "rev-1"}}
             end)

    checks = @readonly <> "\ntest \"$(cat artifact)\" = fixture"
    assert {:ok, testing, check} = prepare(validating, journal, fixture, :test, checks)
    assert check.decision.target.provider == :codex
    assert {:ok, 0} = InternalContainerWorker.run(worker, check.lease, 5000)

    assert {:ok, reviewing, :dispatch} =
             InternalDispatch.settle(worker, journal, testing, check, success(), fn ->
               {:validation, "req-1", "rev-1", %{"response-field" => "check-1"}}
             end)

    assert {:ok, in_review, review} = prepare(reviewing, journal, fixture, :review, checks, :codex)
    assert review.decision.target.provider == :claude
    assert review.attempt.handoff.open_criteria == []
    assert {:ok, 0} = InternalContainerWorker.run(worker, review.lease, 5000)

    assert {:ok, %{phase: :human_review}, {:park, :human_review}} =
             InternalDispatch.settle(worker, journal, in_review, review, success(), fn ->
               {:review, "req-1", "rev-1", {:approved, "review-1"}}
             end)

    assert {:ok, next_boot} = InternalAdmission.open(fixture.state, fixture.workspace_root, "boot-b")
    assert {:ok, %{status: :parked, generation: 4, lease: nil}} = InternalAdmission.lookup(next_boot, @scope)
    assert {:error, :not_dispatchable} = InternalAdmission.reserve(next_boot, @scope, {"run-1", "boot-b", 5})
  end

  test "quarantines a timed-out writer until the next scheduler drains its container", fixture do
    %{worker: worker, workspace: workspace} = fixture
    {:ok, journal} = InternalAdmission.initialize(fixture.state, fixture.workspace_root, @boot)
    {:ok, workspace_id} = InternalContainerWorker.workspace_id(worker, workspace)
    :ok = InternalAdmission.admit(journal, @scope, "run-1", workspace_id)

    {:ok, run} = workflow()
    {:ok, running, planning} = prepare(run, journal, fixture, :research, @readonly)
    {:ok, 0} = InternalContainerWorker.run(worker, planning.lease, 5000)

    {:ok, implement, :dispatch} =
      InternalDispatch.settle(worker, journal, running, planning, success(), fn ->
        {:planning, "req-1", "plan-1", ["one"]}
      end)

    script = "/bin/busybox setsid /bin/sh -c '#{@writer}' & wait"
    {:ok, _running, build} = prepare(implement, journal, fixture, :implement, script)
    {port, os_pid} = external_worker(fixture, build)

    try do
      assert_receive {^port, {:data, {:eol, "fixture worker timed out"}}}, 10_000
      assert File.stat!(Path.join(workspace, "ticks")).size > 0
      assert {"", 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)])
      assert_receive {^port, {:exit_status, 137}}, 3000
      assert {:ok, reopened} = InternalAdmission.open(fixture.state, fixture.workspace_root, "boot-b")
      assert {:error, :lease_unresolved} = InternalAdmission.reserve(reopened, @scope, {"run-1", "boot-b", 3})
      assert {:ok, %{lease: %{process_identity: identity}, generation: 2}} = InternalAdmission.lookup(reopened, @scope)
      assert {:error, :container_binding_mismatch} = InternalContainerWorker.drain(worker, {"run-1", @boot, 9}, identity)
      assert {:error, :invalid_container_identity} = InternalContainerWorker.drain(worker, {"run-1", @boot, 2}, "wrong-engine:#{identity}")

      ticks = Path.join(workspace, "ticks")
      initial = File.stat!(ticks).size
      Process.sleep(300)
      assert File.stat!(ticks).size > initial
      assert :ok = InternalDispatch.recover(worker, reopened, @scope)
      drained = File.read!(ticks)
      Process.sleep(300)
      assert File.read!(ticks) == drained
      assert {:ok, %{status: :parked, generation: 2, lease: nil}} = InternalAdmission.lookup(reopened, @scope)
      assert {:error, :not_dispatchable} = InternalAdmission.reserve(reopened, @scope, {"run-1", "boot-b", 3})
    after
      if Port.info(port, :os_pid) == {:os_pid, os_pid} do
        _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end
  end

  defp external_worker(fixture, %{lease: %{attempt_id: {run, boot, generation}, identity: identity}}) do
    script = ~S"""
    [socket, root, run, boot, generation, identity] = System.argv()
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, worker} = SymphonyElixir.InternalContainerWorker.open(socket, root)
    lease = %{attempt_id: {run, boot, String.to_integer(generation)}, identity: identity}

    case SymphonyElixir.InternalContainerWorker.run(worker, lease, 800) do
      {:error, :container_engine_unavailable} ->
        IO.puts("fixture worker timed out")
        Process.sleep(:infinity)

      other ->
        raise "unexpected fixture result: #{inspect(other)}"
    end
    """

    code_paths =
      :code.get_path()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&String.contains?(&1, "/_build/test/lib/"))
      |> Enum.flat_map(&["-pa", &1])

    args =
      ["--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++
        code_paths ++
        ["-e", script, "--", fixture.socket, fixture.workspace_root, run, boot, to_string(generation), identity]

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        line: 4096,
        args: args
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp workflow do
    InternalWorkflow.new(%{
      run_id: "run-1",
      issue_id: "issue-1",
      project_id: "fixture",
      requirements_revision: "req-1",
      policy_revision: "policy-1",
      independent_review: true
    })
  end

  defp prepare(run, journal, fixture, capability, script, independent_from \\ nil) do
    access = %{project: "fixture", repositories: ["api"], data_class: "synthetic", workspace_policy: "container"}

    profiles =
      for {provider, capabilities} <- [codex: [:implement, :test, :review], claude: [:review], gemini: [:research]] do
        id = Atom.to_string(provider)

        %Profile{
          id: id,
          provider: provider,
          account_key: "fixture-#{id}",
          scopes: [Map.put(access, :access, :read), Map.put(access, :access, :write)],
          options: [%{model: "fixture-#{id}", effort: "low", capabilities: capabilities}]
        }
      end

    identities = Map.new(profiles, &{&1.id, %{status: :verified, account_key: &1.account_key, expires_at_ms: 200}})
    slots = Map.new(profiles, &{{&1.provider, &1.account_key}, %{running: 0, limit: 1}})

    request = %Request{
      run_id: run.run_id,
      phase: run.phase,
      policy_version: run.policy_revision,
      requirements_revision: run.requirements_revision,
      workspace_id: "resolved-on-prepare",
      scope: access,
      profile_bindings: Map.new(profiles, &{&1.provider, &1.id}),
      required_capabilities: [capability],
      independent_from: independent_from
    }

    routing = %{
      request: request,
      profiles: profiles,
      availability: %Availability{now_ms: 100, identities: identities, account_slots: slots},
      command_for: fn _target -> {:ok, %{image: fixture.image, argv: ["/bin/sh", "-ec", script]}} end
    }

    InternalDispatch.prepare(fixture.worker, journal, run, @boot, fixture.workspace, routing)
  end

  defp success, do: %{version: 1, status: :succeeded}
end
