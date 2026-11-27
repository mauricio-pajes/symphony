defmodule SymphonyElixir.InternalWorkflowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.InternalWorkflow

  @attrs %{run_id: "run-a", issue_id: "issue-a", project_id: "project-a", requirements_revision: "req-a", policy_revision: "policy-a"}
  @artifact %{ref: "diff-a", revision: "work-a"}
  @plan {:planning, "req-a", "plan-a", ["visible", "compatible"]}
  @evidence %{"visible" => "recording-a", "compatible" => "test-results-a"}
  @validation {:validation, "req-a", "work-a", @evidence}

  test "runs serial phases and makes the verified handoff available for human review" do
    {:ok, run} = InternalWorkflow.new(@attrs)
    {:ok, running, plan} = InternalWorkflow.start(run, "boot-a")

    assert plan.id == {"run-a", "boot-a", 1}
    assert plan.issue_id == "issue-a"
    assert plan.phase == :planning
    assert plan.write_mode == :read_only
    assert plan.requirements_revision == "req-a"
    assert plan.policy_revision == "policy-a"
    assert plan.handoff.criteria == []
    assert {:error, :not_dispatchable} = InternalWorkflow.start(running, "boot-a")

    {:ok, build, :dispatch} = InternalWorkflow.record(running, plan.id, outcome(:succeeded), @plan)
    {:ok, running, implementation} = InternalWorkflow.start(build, "boot-a")
    assert implementation.write_mode == :workspace_write
    assert implementation.handoff.plan_ref == "plan-a"
    assert implementation.handoff.open_criteria == ["visible", "compatible"]

    {:ok, validate, :dispatch} = InternalWorkflow.record(running, implementation.id, outcome(:succeeded), {:implementation, "req-a", @artifact})
    {:ok, running, validation} = InternalWorkflow.start(validate, "boot-a")
    assert validation.write_mode == :read_only
    assert validation.handoff.artifact == @artifact

    {:ok, ready, {:park, :human_review}} = InternalWorkflow.record(running, validation.id, outcome(:succeeded), @validation)
    assert ready.phase == :human_review
    assert %{open_criteria: [], evidence: @evidence} = InternalWorkflow.handoff(ready)
    assert {:error, :not_dispatchable} = InternalWorkflow.start(ready, "boot-a")
    assert {:error, :human_review_required} = InternalWorkflow.resume(ready, revisions())
    assert InternalWorkflow.park(ready, :operator_pause) == ready
  end

  test "requires the exact attempted generation and rejects duplicate and prior boot results" do
    run = new_run()
    assert {:error, :invalid_boot_id} = InternalWorkflow.start(run, "\n ")
    {:ok, running, first} = InternalWorkflow.start(run, "boot-a")
    assert {:error, :stale_attempt} = InternalWorkflow.record(running, {"run-a", "boot-b", 1}, outcome(:succeeded), @plan)
    assert {:error, :stale_attempt} = InternalWorkflow.record(running, {"run-b", "boot-a", 1}, outcome(:succeeded), @plan)

    held = InternalWorkflow.park(running, :tracker_inactive)
    assert {:error, :stale_attempt} = InternalWorkflow.record(held, first.id, outcome(:succeeded), @plan)
    assert {:ok, ready} = InternalWorkflow.resume(held, revisions())
    {:ok, running, second} = InternalWorkflow.start(ready, "boot-b")
    assert second.id == {"run-a", "boot-b", 2}
    assert {:error, :stale_attempt} = InternalWorkflow.record(running, first.id, outcome(:succeeded), @plan)
    assert {:ok, completed, :dispatch} = InternalWorkflow.record(running, second.id, outcome(:succeeded), @plan)
    assert {:error, :stale_attempt} = InternalWorkflow.record(completed, second.id, outcome(:succeeded), @plan)
  end

  test "uses independent review and carries trusted findings into a bounded correction" do
    run = ready_for_validation(independent_review: true)
    review = step(run, :succeeded, @validation)
    findings = {:review, "req-a", "work-a", {:changes_requested, "findings-a"}}
    correction = step(review, :changes_requested, findings)

    assert correction.phase == :implementation

    assert %{artifact: nil, evidence: evidence, correction: %{artifact: @artifact, findings_ref: "findings-a"}} =
             InternalWorkflow.handoff(correction)

    assert evidence == %{}

    new_artifact = %{ref: "diff-b", revision: "work-b"}
    updated = step(correction, :succeeded, {:implementation, "req-a", new_artifact})
    assert %{status: {:parked, :unverified_phase}} = step(updated, :succeeded, @validation, {:park, :unverified_phase})

    review = step(updated, :succeeded, {:validation, "req-a", "work-b", @evidence})
    correction_requested = {:review, "req-a", "work-b", {:changes_requested, "findings-b"}}

    assert %{status: {:parked, :correction_budget_exhausted}} =
             step(review, :changes_requested, correction_requested, {:park, :correction_budget_exhausted})

    assert %{phase: :human_review, review_ref: "verified-review-b"} =
             step(review, :succeeded, {:review, "req-a", "work-b", {:approved, "verified-review-b"}}, {:park, :human_review})
  end

  test "parks when an outcome tries to advance without exact, complete host evidence" do
    run = new_run()
    build = step(run, :succeeded, @plan)
    validate = step(build, :succeeded, {:implementation, "req-a", @artifact})

    cases = [
      {run, {:planning, "req-b", "plan-a", ["visible"]}},
      {run, {:planning, "req-a", "plan-a", ["visible", "visible"]}},
      {run, {:planning, "req-a", "plan-a", []}},
      {run, {:planning, "req-a", " ", ["visible"]}},
      {build, {:implementation, "req-a", %{ref: "diff-a", revision: ""}}},
      {validate, {:validation, "req-a", "work-a", %{"visible" => "recording-a"}}},
      {validate, {:validation, "req-a", "work-a", %{"visible" => "recording-a", "extra" => "test-results-a"}}},
      {validate, {:validation, "req-a", "work-a", %{"visible" => "recording-a", "compatible" => " "}}},
      {validate, {:validation, "req-a", "work-a", nil}},
      {validate, nil}
    ]

    for {phase, verification} <- cases do
      assert %{active_attempt: nil, status: {:parked, :unverified_phase}} =
               step(phase, :succeeded, verification, {:park, :unverified_phase})
    end

    {:ok, running, attempt} = InternalWorkflow.start(validate, "boot-a")
    claims = Map.put(outcome(:succeeded), :evidence, @evidence)
    assert {:ok, _, {:park, :unverified_phase}} = InternalWorkflow.record(running, attempt.id, claims, nil)
  end

  test "rejects unauthorized or stale review decisions" do
    run = ready_for_validation(independent_review: true)
    review = step(run, :succeeded, @validation)

    for verification <- [
          {:review, "req-b", "work-a", {:approved, "review-a"}},
          {:review, "req-a", "work-b", {:approved, "review-a"}},
          {:review, "req-a", "work-a", {:approved, ""}}
        ] do
      outcome = step(review, :succeeded, verification, {:park, :unverified_phase})
      assert %{status: {:parked, :unverified_phase}} = outcome
    end

    invalid_correction = {:review, "req-a", "work-a", {:changes_requested, ""}}

    assert %{status: {:parked, :unverified_phase}} =
             step(review, :changes_requested, invalid_correction, {:park, :unverified_phase})

    assert %{status: {:parked, :unverified_phase}} = step(run, :changes_requested, nil, {:park, :unverified_phase})
  end

  test "uses a per-phase retry budget without resetting it on incidental tracker activity" do
    run = new_run(retry_limit: 1)
    assert {:error, :not_parked} = InternalWorkflow.resume(run, revisions())
    retried = step(run, :retryable, nil, :retry)
    assert retried.retries == 1

    parked = step(retried, :retryable, nil, {:park, :retry_budget_exhausted})
    assert {:error, :not_dispatchable} = InternalWorkflow.start(parked, "boot-b")
    assert {:ok, resumed} = InternalWorkflow.resume(parked, revisions())
    assert resumed.retries == 1
    assert %{retries: 0} = step(retried, :succeeded, @plan)

    assert %{status: {:parked, :provider_blocked}} = step(run, :blocked, nil, {:park, :provider_blocked})

    {:ok, running, attempt} = InternalWorkflow.start(run, "boot-a")
    assert {:ok, _, {:park, :invalid_outcome}} = InternalWorkflow.record(running, attempt.id, %{version: 2, status: :succeeded}, @plan)
  end

  test "resuming revised requirements or work clears stale checklist proof and reopens mandatory phases" do
    run = ready_for_validation()
    ready = step(run, :succeeded, @validation, {:park, :human_review})
    assert {:error, :invalid_revisions} = InternalWorkflow.resume(ready, %{requirements_revision: "req-a"})
    assert {:error, :invalid_revisions} = InternalWorkflow.resume(ready, %{requirements_revision: "", workspace_revision: "work-a"})
    assert {:error, :invalid_revisions} = InternalWorkflow.resume(ready, %{requirements_revision: "req-a", workspace_revision: nil})

    assert {:ok, next} = InternalWorkflow.resume(ready, %{requirements_revision: "req-a", workspace_revision: "work-new"})
    assert next.phase == :implementation
    assert %{artifact: nil, open_criteria: ["visible", "compatible"], evidence: evidence} = InternalWorkflow.handoff(next)
    assert evidence == %{}

    assert {:ok, replanning} = InternalWorkflow.resume(ready, %{requirements_revision: "req-new", workspace_revision: "work-a"})
    assert replanning.phase == :planning
    assert %{artifact: nil, plan_ref: nil, criteria: [], evidence: evidence} = InternalWorkflow.handoff(replanning)
    assert evidence == %{}
    assert %{status: {:parked, :unverified_phase}} = step(replanning, :succeeded, @plan, {:park, :unverified_phase})
  end

  test "validates admission metadata without letting attrs inject workflow state" do
    assert {:error, :invalid_workflow} = InternalWorkflow.new(Map.delete(@attrs, :policy_revision))
    assert {:error, :invalid_workflow} = InternalWorkflow.new(Map.put(@attrs, :retry_limit, -1))
    assert {:error, :invalid_workflow} = InternalWorkflow.new(Map.put(@attrs, :correction_limit, "1"))
    assert {:error, :invalid_workflow} = InternalWorkflow.new(Map.put(@attrs, :independent_review, nil))
    assert {:error, :invalid_workflow} = InternalWorkflow.new(Map.put(@attrs, :run_id, String.duplicate("x", 1025)))
    assert {:ok, %{phase: :planning, evidence: %{}, status: :ready}} = InternalWorkflow.new(Map.merge(@attrs, %{phase: :human_review, status: :running}))
  end

  defp ready_for_validation(options \\ []) do
    options
    |> new_run()
    |> step(:succeeded, @plan)
    |> step(:succeeded, {:implementation, "req-a", @artifact})
  end

  defp new_run(options \\ []) do
    {:ok, run} = InternalWorkflow.new(Map.merge(@attrs, Map.new(options)))
    run
  end

  defp step(run, status, verification, directive \\ :dispatch) do
    assert {:ok, running, attempt} = InternalWorkflow.start(run, "boot-a")
    assert {:ok, updated, ^directive} = InternalWorkflow.record(running, attempt.id, outcome(status), verification)
    updated
  end

  defp outcome(status), do: %{version: 1, status: status}
  defp revisions, do: %{requirements_revision: "req-a", workspace_revision: "work-a"}
end
