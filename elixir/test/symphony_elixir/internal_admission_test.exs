defmodule SymphonyElixir.InternalAdmissionTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.InternalAdmission

  @scope {"project-a", "issue-a"}
  @old_attempt {"run-a", "boot-a", 1}
  @new_attempt {"run-a", "boot-b", 2}

  setup do
    name = Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
    fixture = Path.join(System.tmp_dir!(), "symphony-admission-#{name}")
    state = Path.join(fixture, "state")
    workspace = Path.join(fixture, "state-workspaces")
    File.mkdir_p!(state)
    File.chmod!(state, 0o700)
    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf!(fixture) end)

    %{state: state, workspace: workspace, ledger: Path.join(state, "admission.json")}
  end

  test "requires explicit provisioning and rejects duplicate scope, run, and workspace", paths do
    assert {:error, :journal_missing} = InternalAdmission.open(paths.state, paths.workspace, "boot-a")
    journal = initialize(paths)
    assert {:error, :journal_already_exists} = InternalAdmission.initialize(paths.state, paths.workspace, "boot-b")
    assert band(File.stat!(paths.ledger).mode, 0o777) == 0o600
    assert {:ok, nil} = InternalAdmission.lookup(journal, @scope)
    assert {:error, :not_admitted} = InternalAdmission.reserve(journal, @scope, @old_attempt)
    assert :ok = InternalAdmission.admit(journal, @scope, "run-a", "workspace-a")
    assert {:error, :already_admitted} = InternalAdmission.admit(journal, @scope, "run-b", "workspace-b")
    assert {:error, :run_already_admitted} = InternalAdmission.admit(journal, {"project-b", "issue-b"}, "run-a", "workspace-b")
    assert {:error, :workspace_already_admitted} = InternalAdmission.admit(journal, {"project-b", "issue-b"}, "run-b", "workspace-a")
    assert {:error, :invalid_admission} = InternalAdmission.admit(journal, @scope, "run/a", "workspace-a")
    assert {:error, :invalid_scope} = InternalAdmission.admit(journal, {"project-a", "../issue-a"}, "run-c", "workspace-c")
    assert {:ok, %{status: :ready, generation: 0, lease: nil}} = InternalAdmission.lookup(journal, @scope)
    assert File.ls!(paths.state) == ["admission.json"]
  end

  test "persists a pending lease across a new boot and requires explicit absence proof", paths do
    journal = admitted(paths)
    assert {:error, :not_dispatchable} = InternalAdmission.reserve(journal, @scope, {"run-a", "boot-a", 2})
    assert {:error, :not_dispatchable} = InternalAdmission.reserve(journal, @scope, {"run-a", "boot-a", 1.0})
    assert {:error, :not_dispatchable} = InternalAdmission.reserve(journal, @scope, {"run-a", "boot-b", 1})
    assert :ok = InternalAdmission.reserve(journal, @scope, @old_attempt)
    assert {:ok, reopened} = InternalAdmission.open(paths.state, paths.workspace, "boot-b")

    assert {:ok, %{status: :ready, generation: 1, lease: %{boot_id: "boot-a", generation: 1, process_identity: nil}}} =
             InternalAdmission.lookup(reopened, @scope)

    assert {:error, :lease_unresolved} = InternalAdmission.reserve(reopened, @scope, @new_attempt)
    assert {:error, :lease_unresolved} = InternalAdmission.resume(reopened, @scope, {"run-a", 1})
    assert {:error, :lease_unresolved} = InternalAdmission.hold(reopened, @scope, {"run-a", 1}, :parked)
    assert {:error, :stale_lease} = InternalAdmission.attach(reopened, @scope, @old_attempt, "host-child")

    assert {:error, :stale_lease} =
             InternalAdmission.finish(reopened, @scope, @new_attempt, :process_tree_absence_verified, :parked)

    assert {:error, :reconciliation_proof_required} =
             InternalAdmission.finish(reopened, @scope, @old_attempt, {:process_tree_drained, "host-child"}, :parked)

    assert :ok = InternalAdmission.finish(reopened, @scope, @old_attempt, :process_tree_absence_verified, :parked)
    assert {:error, :not_dispatchable} = InternalAdmission.reserve(reopened, @scope, @new_attempt)
    assert {:error, :stale_admission} = InternalAdmission.resume(reopened, @scope, {"run-a", 0})
    assert :ok = InternalAdmission.resume(reopened, @scope, {"run-a", 1})
    assert :ok = InternalAdmission.reserve(reopened, @scope, @new_attempt)
  end

  test "does not reserve a second writer while a child from the old boot is alive", paths do
    journal = admitted(paths)
    assert :ok = InternalAdmission.reserve(journal, @scope, @old_attempt)
    sleep_binary = System.find_executable("sleep")
    port = Port.open({:spawn_executable, sleep_binary}, [:exit_status, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    expected_identity = "fixture-process-#{pid}"

    try do
      assert {:error, :invalid_process_identity} = InternalAdmission.attach(journal, @scope, @old_attempt, "bad/process")
      assert :ok = InternalAdmission.attach(journal, @scope, @old_attempt, expected_identity)
      assert {:error, :stale_lease} = InternalAdmission.attach(journal, @scope, @old_attempt, "replacement")
      assert {"", 0} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)])
      assert {:ok, reopened} = InternalAdmission.open(paths.state, paths.workspace, "boot-b")
      assert {:ok, %{lease: %{process_identity: ^expected_identity}}} = InternalAdmission.lookup(reopened, @scope)
      assert {:error, :lease_unresolved} = InternalAdmission.reserve(reopened, @scope, @new_attempt)

      assert {:error, :reconciliation_proof_required} =
               InternalAdmission.finish(reopened, @scope, @old_attempt, :process_tree_absence_verified, :completed)

      assert {:error, :reconciliation_proof_required} =
               InternalAdmission.finish(reopened, @scope, @old_attempt, {:process_tree_drained, "other-child"}, :completed)

      assert {"", 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)])
      assert_receive {^port, {:exit_status, 137}}, 1000

      assert :ok =
               InternalAdmission.finish(reopened, @scope, @old_attempt, {:process_tree_drained, expected_identity}, :completed)

      assert {:ok, final} = InternalAdmission.open(paths.state, paths.workspace, "boot-c")
      assert {:ok, %{status: :completed, generation: 1, lease: nil}} = InternalAdmission.lookup(final, @scope)
      assert {:error, :already_completed} = InternalAdmission.resume(final, @scope, {"run-a", 1})
      assert {:error, :not_dispatchable} = InternalAdmission.reserve(final, @scope, {"run-a", "boot-c", 2})
      assert {:error, :already_admitted} = InternalAdmission.admit(final, @scope, "run-b", "workspace-a")
    after
      if Port.info(port, :os_pid) == {:os_pid, pid} do
        _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    end
  end

  test "keeps ready admissions pinned to the boot and preserves explicit holds", paths do
    _journal = admitted(paths)
    assert {:ok, reopened} = InternalAdmission.open(paths.state, paths.workspace, "boot-b")
    assert {:error, :not_dispatchable} = InternalAdmission.reserve(reopened, @scope, {"run-a", "boot-b", 1})
    assert :ok = InternalAdmission.resume(reopened, @scope, {"run-a", 0})
    assert :ok = InternalAdmission.hold(reopened, @scope, {"run-a", 0}, :parked)
    assert {:ok, held} = InternalAdmission.open(paths.state, paths.workspace, "boot-c")
    assert {:ok, %{status: :parked, boot_id: "boot-b", lease: nil}} = InternalAdmission.lookup(held, @scope)
    assert {:error, :not_dispatchable} = InternalAdmission.reserve(held, @scope, {"run-a", "boot-c", 1})
    assert :ok = InternalAdmission.resume(held, @scope, {"run-a", 0})
    assert :ok = InternalAdmission.reserve(held, @scope, {"run-a", "boot-c", 1})
  end

  test "allows prefix siblings and rejects overlapping roots, state symlinks, relative paths, and public directories", paths do
    _journal = initialize(paths)
    assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, paths.state, "boot-b")
    assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, Path.join(paths.state, "child"), "boot-b")

    nested = Path.join(paths.workspace, "child")
    File.mkdir!(nested)
    File.chmod!(nested, 0o700)
    assert {:error, :invalid_state_directory} = InternalAdmission.open(nested, paths.workspace, "boot-b")

    aliased = Path.join(paths.workspace, "aliased")
    File.ln_s!(paths.state, aliased)
    assert {:error, :invalid_state_directory} = InternalAdmission.open(aliased, paths.workspace, "boot-b")
    assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, aliased, "boot-b")
    assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, "relative", "boot-b")
    assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, paths.workspace, "")

    missing_workspace = Path.join(Path.dirname(paths.workspace), "not-created")
    assert {:ok, _journal} = InternalAdmission.open(paths.state, missing_workspace, "boot-b")

    case_alias = Path.join(Path.dirname(paths.state), "STATE")

    if File.dir?(case_alias) do
      assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, case_alias, "boot-b")
      assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, Path.join(case_alias, "future"), "boot-b")
    end

    loop = Path.join(paths.workspace, "loop")
    File.ln_s!(loop, loop)
    assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, loop, "boot-b")

    File.chmod!(paths.state, 0o755)
    assert {:error, :invalid_state_directory} = InternalAdmission.open(paths.state, paths.workspace, "boot-b")
  end

  test "detects replacement of the opened directory and refuses another OTP process's handle", paths do
    journal = admitted(paths)
    assert {:error, :not_journal_owner} = Task.await(Task.async(fn -> InternalAdmission.lookup(journal, @scope) end))
    File.rename!(paths.state, paths.state <> "-old")
    File.mkdir!(paths.state)
    File.chmod!(paths.state, 0o700)
    assert {:error, :state_directory_changed} = InternalAdmission.reserve(journal, @scope, @old_attempt)
    assert {:error, :journal_missing} = InternalAdmission.open(paths.state, paths.workspace, "boot-b")
  end

  test "refuses links, oversized ledgers and records without private mode", paths do
    journal = initialize(paths)
    copied = paths.ledger <> ".copy"
    File.rename!(paths.ledger, copied)
    File.ln_s!(copied, paths.ledger)
    assert {:error, :unsafe_journal_file} = InternalAdmission.lookup(journal, @scope)
    File.rm!(paths.ledger)
    File.ln!(copied, paths.ledger)
    assert {:error, :unsafe_journal_file} = InternalAdmission.lookup(journal, @scope)
    File.rm!(copied)
    File.chmod!(paths.ledger, 0o644)
    assert {:error, :unsafe_journal_file} = InternalAdmission.lookup(journal, @scope)
    File.chmod!(paths.ledger, 0o600)
    File.write!(paths.ledger, String.duplicate(" ", 1_048_577))
    assert {:error, :unsafe_journal_file} = InternalAdmission.lookup(journal, @scope)
  end

  test "rejects malformed, unknown, inconsistent and duplicate records before dispatch", paths do
    journal = admitted(paths)
    assert :ok = InternalAdmission.reserve(journal, @scope, @old_attempt)
    %{"records" => [record]} = Jason.decode!(File.read!(paths.ledger))

    for raw <- [
          %{"records" => [record], "version" => 2},
          %{"records" => "bad", "version" => 1},
          %{"records" => [record, record], "version" => 1},
          %{"records" => [Map.delete(record, "lease")], "version" => 1},
          %{"records" => [%{record | "status" => "completed"}], "version" => 1},
          %{"records" => [%{record | "generation" => 2}], "version" => 1},
          %{"records" => [put_in(record["lease"]["process_identity"], "/unsafe")], "version" => 1}
        ] do
      File.write!(paths.ledger, Jason.encode!(raw))
      assert {:error, :invalid_journal} = InternalAdmission.open(paths.state, paths.workspace, "boot-b")
      assert {:error, :invalid_journal} = InternalAdmission.reserve(journal, @scope, @old_attempt)
    end

    File.write!(paths.ledger, "{")
    assert {:error, :invalid_journal} = InternalAdmission.open(paths.state, paths.workspace, "boot-b")
  end

  test "bounds the admission count without deleting previous records", paths do
    journal = admitted(paths)
    %{"records" => [record]} = Jason.decode!(File.read!(paths.ledger))

    rows =
      for n <- 1..512 do
        %{record | "issue_id" => "fixture-issue-#{n}", "run_id" => "fixture-run-#{n}", "workspace_id" => "fixture-workspace-#{n}"}
      end

    File.write!(paths.ledger, Jason.encode!(%{"version" => 1, "records" => rows}))
    assert {:error, :journal_full} = InternalAdmission.admit(journal, @scope, "run-c", "workspace-new")
    assert {:ok, %{status: :ready}} = InternalAdmission.lookup(journal, {"project-a", "fixture-issue-512"})
  end

  defp initialize(paths) do
    assert {:ok, journal} = InternalAdmission.initialize(paths.state, paths.workspace, "boot-a")
    journal
  end

  defp admitted(paths) do
    journal = initialize(paths)
    assert :ok = InternalAdmission.admit(journal, @scope, "run-a", "workspace-a")
    journal
  end
end
