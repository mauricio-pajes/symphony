defmodule SymphonyElixir.AgentRouterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentProfiles
  alias SymphonyElixir.AgentProfiles.{Availability, Profile}
  alias SymphonyElixir.AgentRouter
  alias SymphonyElixir.AgentRouter.Request

  @scope %{
    project: "sandbox-project",
    repositories: ["payments", "client"],
    data_class: "synthetic",
    workspace_policy: "local-sandbox",
    access: :read
  }

  @request %Request{
    run_id: "run-1",
    phase: :review,
    policy_version: "policy-1",
    requirements_revision: "requirements-1",
    workspace_id: "workspace-1",
    scope: @scope,
    profile_bindings: %{codex: "codex-local", claude: "claude-local", gemini: "gemini-local"},
    required_capabilities: [:read_diff]
  }

  test "routes deterministically with a Codex preference and records its audit inputs" do
    profiles = profiles()
    availability = snapshot(profiles)

    assert {:ok, decision} = AgentRouter.route(@request, profiles, availability)
    assert {:ok, ^decision} = AgentRouter.route(@request, Enum.reverse(profiles), availability)

    assert %{
             run_id: "run-1",
             phase: :review,
             policy_version: "policy-1",
             requirements_revision: "requirements-1",
             reason: :codex_preference,
             target: %{provider: :codex, model: "codex-model", effort: "low"},
             resume_session_id: nil,
             override: nil
           } = decision

    assert [claude, codex, gemini] = decision.alternatives
    assert %{provider: :claude, status: :eligible} = claude
    assert %{provider: :codex, status: :selected, reason: :codex_preference, quota: :unknown} = codex
    assert %{provider: :gemini, status: :eligible} = gemini
  end

  test "honors ordered project model preferences and never invents a profile or effort" do
    profiles = profiles()

    request = %{
      @request
      | preferences: [{:codex, "codex-model", "unsupported"}, {:gemini, "gemini-model", "low"}]
    }

    assert {:ok, %{reason: :project_preference, target: %{provider: :gemini, effort: "low"}}} =
             AgentRouter.route(request, profiles, snapshot(profiles))
  end

  test "uses only model options that cover every required capability" do
    profiles = profiles()

    assert {:ok, decision} =
             AgentRouter.route(%{@request | required_capabilities: [:read_diff, :inspect_image]}, profiles, snapshot(profiles))

    assert %{reason: :catalog_order, target: %{provider: :gemini}} = decision
    assert %{reason: :capability_missing, status: :rejected} = find(decision, :codex)
  end

  test "rejects changes in project, data class, workspace policy, access or repository" do
    profiles = profiles()
    availability = snapshot(profiles)

    for {key, unauthorized} <- [
          project: "other-project",
          repositories: ["payments", "private-repo"],
          repositories: [],
          data_class: "corporate",
          workspace_policy: "remote-unrestricted",
          access: :write
        ] do
      request = %{@request | scope: Map.put(@scope, key, unauthorized)}

      assert {:blocked, decision} = AgentRouter.route(request, profiles, availability)
      assert decision.reason == :no_eligible_candidates
      assert Enum.all?(decision.alternatives, &(&1.reason == :scope_denied))
    end

    assert {:blocked, %{reason: :invalid_workspace}} =
             AgentRouter.route(%{@request | workspace_id: ""}, profiles, availability)
  end

  test "does not merge repository grants to authorize a multi-repository attempt" do
    [codex | _] = profiles()
    grants = [%{@scope | repositories: ["payments"]}, %{@scope | repositories: ["client"]}]
    codex = %{codex | scopes: grants}

    assert {:error, :scope_denied} = AgentProfiles.authorize(codex, @scope, snapshot([codex]))
  end

  test "requires an observed verified identity matching the enrolled account" do
    [codex | _] = profiles()
    availability = snapshot([codex])
    verified = availability.identities[codex.id]

    for {observation, reason} <- [
          {nil, :identity_unverified},
          {%{verified | account_key: "unexpected-account"}, :identity_mismatch},
          {%{verified | status: :denied}, :identity_denied},
          {%{verified | status: :expired}, :identity_expired},
          {%{verified | expires_at_ms: availability.now_ms}, :identity_expired}
        ] do
      snapshot = %{availability | identities: %{codex.id => observation}}
      assert {:error, ^reason} = AgentProfiles.authorize(codex, @scope, snapshot)
    end
  end

  test "describes missing, conflicting and incorrectly bound policy entries" do
    [codex, claude, gemini] = profiles()
    availability = snapshot([codex, claude, gemini])

    assert {:ok, decision} =
             AgentRouter.route(@request, [codex, claude, %{codex | id: gemini.id}, gemini], availability)

    assert %{reason: :profile_alias_conflict} = find(decision, :gemini)

    request = %{@request | profile_bindings: %{codex: claude.id, claude: "missing", gemini: gemini.id}}
    assert {:blocked, decision} = AgentRouter.route(request, [codex, claude, %{gemini | options: []}], availability)
    assert %{reason: :provider_mismatch} = find(decision, :codex)
    assert %{reason: :profile_not_enrolled} = find(decision, :claude)
    assert %{reason: :no_approved_options} = find(decision, :gemini)

    colliding = %{gemini | options: gemini.options ++ gemini.options}
    assert {:blocked, decision} = AgentRouter.route(request, [codex, claude, colliding], availability)
    assert %{reason: :model_option_conflict} = find(decision, :gemini)
  end

  test "prefers only sessions bound to the same approved target, workspace and inputs" do
    profiles = profiles()
    availability = snapshot(profiles)

    session = %{
      id: "provider-session",
      run_id: @request.run_id,
      account_key: "claude-account",
      policy_version: @request.policy_version,
      target: %{provider: :claude, profile_id: "claude-local", model: "claude-model", effort: "low"},
      scope: @scope,
      requirements_revision: @request.requirements_revision,
      workspace_id: @request.workspace_id
    }

    assert {:ok, %{reason: :session_affinity, target: %{provider: :claude}, resume_session_id: "provider-session"} = decision} =
             AgentRouter.route(%{@request | session: session}, profiles, availability)

    refute Enum.any?(decision.alternatives, &Map.has_key?(&1, :resume_session_id))

    for incompatible <- [
          %{session | account_key: "rebound-account"},
          %{session | run_id: "other-run"},
          %{session | policy_version: "other-policy"},
          %{session | id: ""},
          %{session | workspace_id: "other-workspace"},
          %{session | requirements_revision: "other-revision"},
          %{session | scope: %{@scope | access: :write}},
          put_in(session, [:target, :profile_id], "other-profile"),
          put_in(session, [:target, :effort], "other-effort"),
          %{session | target: %{provider: :gemini, profile_id: "gemini-local", model: "gemini-model", effort: "low"}}
        ] do
      assert {:ok, %{target: %{provider: :codex}, resume_session_id: nil}} =
               AgentRouter.route(%{@request | session: incompatible}, profiles, availability)
    end
  end

  test "never sends an independent review to the implementation provider" do
    profiles = profiles()

    assert {:ok, decision} =
             AgentRouter.route(%{@request | independent_from: :codex}, profiles, snapshot(profiles))

    assert %{target: %{provider: :claude}, reason: :catalog_order} = decision
    assert %{status: :rejected, reason: :review_independence} = find(decision, :codex)
  end

  test "handles a scoped override without expanding model, permission or identity policy" do
    profiles = profiles()
    availability = snapshot(profiles)

    override = %{
      target: %{provider: :claude, profile_id: "claude-local", model: "claude-model", effort: "low"},
      run_id: @request.run_id,
      phase: @request.phase,
      expires_at_ms: availability.now_ms + 500,
      actor: "operator",
      rationale: "Require a separate reviewer"
    }

    assert {:ok, %{target: %{provider: :claude}, reason: :manual_override, override: ^override}} =
             AgentRouter.route(%{@request | override: override}, profiles, availability)

    assert {:ok, %{reason: :manual_override}} =
             AgentRouter.route(%{@request | override: %{override | phase: nil}}, profiles, availability)

    for expired <- [
          %{override | run_id: "another-run"},
          %{override | phase: :build},
          %{override | expires_at_ms: availability.now_ms}
        ] do
      assert {:ok, %{reason: :codex_preference, override: nil}} =
               AgentRouter.route(%{@request | override: expired}, profiles, availability)
    end

    for invalid <- [
          Map.delete(override, :actor),
          %{override | actor: " "},
          %{override | rationale: ""},
          %{override | expires_at_ms: :never}
        ] do
      assert {:blocked, %{reason: :invalid_override}} =
               AgentRouter.route(%{@request | override: invalid}, profiles, availability)
    end

    unsupported = put_in(override, [:target, :effort], "unsupported")

    assert {:blocked, %{reason: :override_denied, target: nil}} =
             AgentRouter.route(%{@request | override: unsupported}, profiles, availability)

    assert {:blocked, decision} =
             AgentRouter.route(%{@request | override: override, independent_from: :claude}, profiles, availability)

    assert decision.reason == :override_denied
    assert %{reason: :review_independence} = find(decision, :claude)

    cooled = %{availability | cooldowns: %{claude: availability.now_ms + 100}}

    assert {:wait, decision} = AgentRouter.route(%{@request | override: override}, profiles, cooled)
    assert decision.reason == :override_waiting
    assert %{status: :deferred, reason: :cooldown, retry_at_ms: 200} = find(decision, :claude)
  end

  test "defers an exhausted binding and never rotates to a second alias" do
    [codex | _] = profiles()
    spare = %{codex | id: "codex-spare", account_key: "another-account"}
    availability = snapshot([codex, spare])
    quota = %{status: :exhausted, expires_at_ms: 300, reset_at_ms: 250}
    snapshot = %{availability | quotas: %{{:codex, codex.account_key} => [quota]}}
    request = %{@request | profile_bindings: %{codex: codex.id}}

    assert {:wait, decision} = AgentRouter.route(request, [codex, spare], snapshot)
    assert decision.reason == :waiting_for_capacity

    assert [%{profile_id: "codex-local", status: :deferred, reason: :quota_exhausted, retry_at_ms: 250, quota: :exhausted}] =
             decision.alternatives
  end

  test "defers across overlapping cooldowns and tracks quota buckets separately from capacity" do
    [codex | _] = profiles()
    availability = snapshot([codex])
    account = {:codex, codex.account_key}
    model = "codex-model"

    observations = [
      %{status: :exhausted, expires_at_ms: 400, reset_at_ms: 230},
      %{status: :exhausted, expires_at_ms: 400, reset_at_ms: 260}
    ]

    scopes = %{
      account => observations,
      {:codex, codex.account_key, "other-model"} => [%{status: :exhausted, expires_at_ms: 600, reset_at_ms: 600}]
    }

    cooled = %{availability | cooldowns: %{:codex => 250, account => 280}, quotas: scopes}
    assert {:wait, :cooldown, 280, :exhausted} = AgentProfiles.availability(codex, model, cooled)

    assert {:wait, :quota_exhausted, 260, :exhausted} =
             AgentProfiles.availability(codex, model, %{availability | quotas: scopes})

    assert {:wait, :quota_exhausted, nil, :exhausted} =
             AgentProfiles.availability(codex, model, %{
               availability
               | quotas: Map.put(scopes, account, [%{status: :exhausted, expires_at_ms: 400, reset_at_ms: nil}])
             })

    assert {:ready, :unknown} = AgentProfiles.availability(codex, model, %{availability | now_ms: 400, quotas: scopes})

    model_quota = %{{:codex, codex.account_key, model} => [%{status: :available, expires_at_ms: 200, reset_at_ms: nil}]}
    assert {:ready, :available} = AgentProfiles.availability(codex, model, %{availability | quotas: model_quota})

    partially_unknown = Map.put(model_quota, account, [%{status: :unknown, expires_at_ms: 200, reset_at_ms: nil}])
    assert {:ready, :unknown} = AgentProfiles.availability(codex, model, %{availability | quotas: partially_unknown})
  end

  test "counts aliases against the same account slots and exposes missing and saturated limits" do
    [codex | _] = profiles()
    alias_profile = %{codex | id: "codex-alias"}
    availability = snapshot([codex, alias_profile])
    account = {:codex, codex.account_key}

    assert {:wait, :account_capacity_unknown, nil, :unknown} =
             AgentProfiles.availability(codex, "codex-model", %{availability | account_slots: %{}})

    exhausted = %{availability | account_slots: %{account => %{running: 1, limit: 1}}}

    for profile <- [codex, alias_profile] do
      assert {:wait, :account_saturated, nil, :unknown} =
               AgentProfiles.availability(profile, "codex-model", exhausted)
    end

    assert {:wait, :provider_saturated, nil, :unknown} =
             AgentProfiles.availability(codex, "codex-model", %{availability | provider_slots: %{codex: %{running: 1, limit: 1}}})

    assert {:ready, :unknown} =
             AgentProfiles.availability(codex, "codex-model", %{availability | provider_slots: %{codex: %{running: 1, limit: 2}}})
  end

  defp profiles do
    provider_capabilities = [
      codex: [:read_diff, :resume],
      claude: [:read_diff, :resume],
      gemini: [:read_diff, :inspect_image]
    ]

    for {provider, capabilities} <- provider_capabilities do
      %Profile{
        id: "#{provider}-local",
        provider: provider,
        account_key: "#{provider}-account",
        scopes: [@scope],
        options: [%{model: "#{provider}-model", effort: "low", capabilities: capabilities}]
      }
    end
  end

  defp snapshot(profiles) do
    %Availability{
      now_ms: 100,
      identities: Map.new(profiles, &{&1.id, %{account_key: &1.account_key, status: :verified, expires_at_ms: 1_000}}),
      account_slots: Map.new(profiles, &{{&1.provider, &1.account_key}, %{running: 0, limit: 1}})
    }
  end

  defp find(decision, provider), do: Enum.find(decision.alternatives, &(&1.provider == provider))
end
