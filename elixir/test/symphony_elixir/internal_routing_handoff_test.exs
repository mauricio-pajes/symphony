defmodule SymphonyElixir.InternalRoutingHandoffTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentProfiles.{Availability, Profile}
  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.AgentRouter.Request
  alias SymphonyElixir.InternalWorkflow

  test "verified handoffs update the internal phase without relying on a tracker transition" do
    scope = %{project: "example", repositories: ["api"], data_class: "synthetic", workspace_policy: "local-fixture"}
    {profiles, bindings, availability} = policy(scope)

    assert {:ok, run} =
             InternalWorkflow.new(%{
               run_id: "run-1",
               issue_id: "issue-1",
               project_id: scope.project,
               requirements_revision: "requirements-1",
               policy_revision: "policy-1",
               independent_review: true
             })

    assert {:ok, planning, plan} = InternalWorkflow.start(run, "boot-1")
    assert {:ok, %{target: %{provider: :gemini}}} = route(plan, scope, bindings, profiles, availability, [:research])

    assert {:ok, implementation, :dispatch} =
             complete(planning, plan, {:planning, "requirements-1", "plan-ref", ["response-field"]})

    assert {:ok, implementing, build} = InternalWorkflow.start(implementation, "boot-1")
    assert %{plan_ref: "plan-ref", open_criteria: ["response-field"]} = build.handoff
    assert {:ok, %{target: %{provider: :codex}}} = route(build, scope, bindings, profiles, availability, [:implement])

    assert {:ok, validation, :dispatch} =
             complete(implementing, build, {:implementation, "requirements-1", %{ref: "diff-ref", revision: "commit-1"}})

    assert {:ok, validating, check} = InternalWorkflow.start(validation, "boot-1")

    assert {:ok, review, :dispatch} =
             complete(validating, check, {:validation, "requirements-1", "commit-1", %{"response-field" => "test-ref"}})

    assert {:ok, reviewing, check_review} = InternalWorkflow.start(review, "boot-1")
    assert %{artifact: %{revision: "commit-1"}, open_criteria: [], evidence: %{"response-field" => "test-ref"}} = check_review.handoff

    assert {:ok, %{target: %{provider: :claude}, alternatives: alternatives}} =
             route(check_review, scope, bindings, profiles, availability, [:review], :codex)

    assert Enum.any?(alternatives, &match?(%{provider: :codex, reason: :review_independence}, &1))

    assert {:ok, ready, {:park, :human_review}} =
             complete(reviewing, check_review, {:review, "requirements-1", "commit-1", {:approved, "review-ref"}})

    assert %{review_ref: "review-ref"} = InternalWorkflow.handoff(ready)
    assert {:error, :not_dispatchable} = InternalWorkflow.start(ready, "boot-1")
  end

  defp complete(run, attempt, verification) do
    InternalWorkflow.record(run, attempt.id, %{version: 1, status: :succeeded}, verification)
  end

  defp route(attempt, scope, bindings, profiles, availability, capabilities, independent_from \\ nil) do
    access = if attempt.write_mode == :workspace_write, do: :write, else: :read

    AgentRouter.route(
      %Request{
        run_id: elem(attempt.id, 0),
        phase: attempt.phase,
        policy_version: attempt.policy_revision,
        requirements_revision: attempt.requirements_revision,
        workspace_id: "fixture-workspace",
        scope: Map.put(scope, :access, access),
        profile_bindings: bindings,
        required_capabilities: capabilities,
        independent_from: independent_from
      },
      profiles,
      availability
    )
  end

  defp policy(scope) do
    profiles =
      for {provider, capabilities} <- [codex: [:implement, :review], claude: [:review], gemini: [:research]] do
        id = Atom.to_string(provider)

        %Profile{
          id: id,
          provider: provider,
          account_key: "fixture-#{id}",
          scopes: [Map.put(scope, :access, :read), Map.put(scope, :access, :write)],
          options: [%{model: "fixture-#{id}", effort: "low", capabilities: capabilities}]
        }
      end

    bindings = Map.new(profiles, &{&1.provider, &1.id})
    identities = Map.new(profiles, &{&1.id, %{status: :verified, account_key: &1.account_key, expires_at_ms: 200}})
    slots = Map.new(profiles, &{{&1.provider, &1.account_key}, %{running: 0, limit: 1}})

    {profiles, bindings, %Availability{now_ms: 100, identities: identities, account_slots: slots}}
  end
end
