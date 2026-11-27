defmodule SymphonyElixir.AgentRouter do
  @moduledoc """
  Routes one opted-in phase using normalized facts and operator policy.

  The caller decides whether to classify ambiguous requirements and supplies
  the resulting capabilities and preferences. Routing does not start calls,
  verify credentials itself, or claim slots. Each provider has one explicit
  profile binding for the request.
  """

  alias SymphonyElixir.AgentProfiles
  alias SymphonyElixir.AgentProfiles.{Availability, Profile}

  @type target :: %{
          provider: AgentProfiles.provider(),
          profile_id: String.t(),
          model: String.t(),
          effort: String.t() | nil
        }
  @type session :: %{
          id: String.t(),
          run_id: String.t(),
          account_key: String.t(),
          policy_version: String.t(),
          target: target(),
          scope: AgentProfiles.scope(),
          workspace_id: String.t(),
          requirements_revision: String.t()
        }
  @type override :: %{
          run_id: String.t(),
          phase: atom() | nil,
          expires_at_ms: integer(),
          target: target(),
          actor: String.t(),
          rationale: String.t()
        }

  defmodule Request do
    @moduledoc "Normalized phase demand and policy supplied by the coordinator."

    alias SymphonyElixir.{AgentProfiles, AgentRouter}

    @enforce_keys [:run_id, :phase, :policy_version, :requirements_revision, :workspace_id, :scope, :profile_bindings]
    defstruct @enforce_keys ++
                [required_capabilities: [], preferences: [], independent_from: nil, session: nil, override: nil]

    @type t :: %__MODULE__{
            run_id: String.t(),
            phase: atom(),
            policy_version: String.t(),
            requirements_revision: String.t(),
            workspace_id: String.t(),
            scope: AgentProfiles.scope(),
            profile_bindings: %{optional(AgentProfiles.provider()) => String.t()},
            required_capabilities: [atom()],
            preferences: [{AgentProfiles.provider(), String.t(), String.t() | nil}],
            independent_from: AgentProfiles.provider() | nil,
            session: AgentRouter.session() | nil,
            override: AgentRouter.override() | nil
          }
  end

  @type rejection ::
          AgentProfiles.rejection()
          | :profile_not_enrolled
          | :profile_alias_conflict
          | :provider_mismatch
          | :review_independence
          | :no_approved_options
          | :model_option_conflict
          | :capability_missing
  @type selection :: :manual_override | :session_affinity | :project_preference | :codex_preference | :catalog_order
  @type alternative :: %{
          provider: AgentProfiles.provider(),
          profile_id: String.t(),
          target: target() | nil,
          status: :eligible | :selected | :deferred | :rejected,
          reason: rejection() | AgentProfiles.wait_reason() | selection() | nil,
          retry_at_ms: integer() | nil,
          quota: AgentProfiles.quota_status()
        }
  @type decision :: %{
          run_id: String.t(),
          phase: atom(),
          policy_version: String.t(),
          requirements_revision: String.t(),
          reason:
            selection()
            | :no_eligible_candidates
            | :waiting_for_capacity
            | :override_waiting
            | :override_denied
            | :invalid_override
            | :invalid_workspace,
          target: target() | nil,
          resume_session_id: String.t() | nil,
          override: override() | nil,
          alternatives: [alternative()]
        }

  @spec route(Request.t(), [Profile.t()], Availability.t()) ::
          {:ok, decision()} | {:wait, decision()} | {:blocked, decision()}
  def route(%Request{workspace_id: workspace_id} = request, profiles, %Availability{} = snapshot)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    profiles_by_id = Enum.group_by(profiles, & &1.id)
    override = active_override(request, snapshot.now_ms)

    candidates =
      request.profile_bindings
      |> Enum.sort()
      |> Enum.flat_map(fn {provider, profile_id} ->
        candidate_options(provider, profile_id, Map.get(profiles_by_id, profile_id, []), request, snapshot)
      end)

    choose(candidates, request, override)
  end

  def route(%Request{} = request, _profiles, %Availability{} = _snapshot) do
    {:blocked, decision(request, [], nil, :invalid_workspace)}
  end

  defp candidate_options(provider, profile_id, profiles, request, snapshot) do
    with {:ok, profile} <- bound_profile(profiles, provider, request.independent_from),
         :ok <- AgentProfiles.authorize(profile, request.scope, snapshot),
         :ok <- validate_options(profile.options) do
      Enum.map(profile.options, &evaluate_option(profile, &1, request, snapshot))
    else
      {:error, reason} -> [alternative(provider, profile_id, nil, :rejected, reason)]
    end
  end

  defp bound_profile([], _provider, _independent_from), do: {:error, :profile_not_enrolled}

  defp bound_profile([%Profile{provider: provider} = profile], provider, independent_from) do
    if provider == independent_from, do: {:error, :review_independence}, else: {:ok, profile}
  end

  defp bound_profile([_profile], _provider, _independent_from), do: {:error, :provider_mismatch}
  defp bound_profile(_profiles, _provider, _independent_from), do: {:error, :profile_alias_conflict}

  defp validate_options([]), do: {:error, :no_approved_options}

  defp validate_options(options) do
    if Enum.uniq_by(options, &{&1.model, &1.effort}) == options, do: :ok, else: {:error, :model_option_conflict}
  end

  defp evaluate_option(profile, option, request, snapshot) do
    target = %{provider: profile.provider, profile_id: profile.id, model: option.model, effort: option.effort}

    if Enum.all?(request.required_capabilities, &(&1 in option.capabilities)) do
      available_option(profile, option, target, request, snapshot)
    else
      alternative(profile.provider, profile.id, target, :rejected, :capability_missing)
    end
  end

  defp available_option(profile, option, target, request, snapshot) do
    case AgentProfiles.availability(profile, option.model, snapshot) do
      {:ready, quota} ->
        alternative(profile.provider, profile.id, target, :eligible, nil)
        |> Map.put(:quota, quota)
        |> Map.put(:resume_session_id, reusable_session(request, target, profile.account_key, option.capabilities))

      {:wait, reason, retry_at, quota} ->
        %{alternative(profile.provider, profile.id, target, :deferred, reason) | retry_at_ms: retry_at, quota: quota}
    end
  end

  defp alternative(provider, profile_id, target, status, reason) do
    %{
      provider: provider,
      profile_id: profile_id,
      target: target,
      status: status,
      reason: reason,
      retry_at_ms: nil,
      quota: :unknown
    }
  end

  defp active_override(%Request{override: nil}, _now_ms), do: nil

  defp active_override(%Request{override: %{run_id: run_id, phase: phase, expires_at_ms: until_ms} = override} = request, now_ms)
       when is_integer(until_ms) do
    if run_id == request.run_id and phase in [nil, request.phase] and until_ms > now_ms do
      validate_override(override)
    end
  end

  defp active_override(_request, _now_ms), do: :invalid

  defp validate_override(%{actor: actor, rationale: rationale, target: target}) when is_binary(actor) and is_binary(rationale) do
    if String.trim(actor) != "" and String.trim(rationale) != "" and is_map(target), do: :valid, else: :invalid
  end

  defp validate_override(_override), do: :invalid

  defp reusable_session(%Request{session: %{id: id}} = request, target, account_key, capabilities)
       when is_binary(id) and byte_size(id) > 0 do
    binding = %{
      run_id: request.run_id,
      policy_version: request.policy_version,
      account_key: account_key,
      scope: request.scope,
      workspace_id: request.workspace_id,
      requirements_revision: request.requirements_revision,
      target: target
    }

    if :resume in capabilities and Map.take(request.session, Map.keys(binding)) == binding do
      id
    end
  end

  defp reusable_session(_request, _target, _account_key, _capabilities), do: nil

  defp choose(candidates, request, :invalid), do: {:blocked, decision(request, candidates, nil, :invalid_override)}

  defp choose(candidates, %Request{override: %{target: target} = override} = request, :valid) do
    case Enum.find(candidates, &(&1.target == target)) do
      %{status: :eligible} = chosen -> pick(request, candidates, override, chosen, :manual_override)
      %{status: :deferred} -> {:wait, decision(request, candidates, override, :override_waiting)}
      _ -> {:blocked, decision(request, candidates, override, :override_denied)}
    end
  end

  defp choose(candidates, request, nil) do
    case Enum.filter(candidates, &(&1.status == :eligible)) do
      [] ->
        if Enum.any?(candidates, &(&1.status == :deferred)) do
          {:wait, decision(request, candidates, nil, :waiting_for_capacity)}
        else
          {:blocked, decision(request, candidates, nil, :no_eligible_candidates)}
        end

      eligible ->
        chosen = Enum.min_by(eligible, &rank(&1, request.preferences))
        pick(request, candidates, nil, chosen, choice_reason(chosen, request.preferences))
    end
  end

  defp rank(candidate, preferences) do
    preference = preference_index(candidate.target, preferences)
    {is_nil(candidate.resume_session_id), is_nil(preference), preference, candidate.provider != :codex}
  end

  defp preference_index(target, preferences), do: Enum.find_index(preferences, &(&1 == {target.provider, target.model, target.effort}))

  defp choice_reason(%{resume_session_id: id}, _preferences) when is_binary(id), do: :session_affinity

  defp choice_reason(candidate, preferences) do
    cond do
      preference_index(candidate.target, preferences) != nil -> :project_preference
      candidate.provider == :codex -> :codex_preference
      true -> :catalog_order
    end
  end

  defp pick(request, candidates, override, chosen, reason) do
    alternatives =
      Enum.map(candidates, fn candidate ->
        if candidate.target == chosen.target, do: %{candidate | status: :selected, reason: reason}, else: candidate
      end)

    result = decision(request, alternatives, override, reason)
    {:ok, %{result | target: chosen.target, resume_session_id: chosen.resume_session_id}}
  end

  defp decision(request, candidates, override, reason) do
    %{
      run_id: request.run_id,
      phase: request.phase,
      policy_version: request.policy_version,
      requirements_revision: request.requirements_revision,
      reason: reason,
      target: nil,
      resume_session_id: nil,
      override: override,
      alternatives: Enum.map(candidates, &Map.delete(&1, :resume_session_id))
    }
  end
end
