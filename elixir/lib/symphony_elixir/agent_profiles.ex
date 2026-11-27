defmodule SymphonyElixir.AgentProfiles do
  @moduledoc """
  Evaluates enrolled profiles against authorized scope and observed availability.

  The launcher supplies identity observations. Slot counts come from the
  scheduler and remain advisory until it reserves capacity. The registry
  contains opaque account keys and never handles provider credentials.
  """

  alias SymphonyElixir.AgentRouting

  @type provider :: AgentRouting.provider()
  @type account :: {provider(), String.t()}
  @type scope :: %{
          project: String.t(),
          repositories: [String.t()],
          data_class: String.t(),
          workspace_policy: String.t(),
          access: :read | :write
        }
  @type model_option :: %{model: String.t(), effort: String.t() | nil, capabilities: [atom()]}
  @type quota_scope :: account() | {provider(), String.t(), String.t()}
  @type quota_status :: :available | :exhausted | :unknown
  @type quota_observation :: %{
          status: quota_status(),
          expires_at_ms: integer(),
          reset_at_ms: integer() | nil
        }
  @type identity :: %{account_key: String.t(), status: :verified | :denied | :expired, expires_at_ms: integer()}
  @type slots :: %{running: non_neg_integer(), limit: non_neg_integer()}

  defmodule Profile do
    @moduledoc "A local alias enrolled by the project's operator."

    alias SymphonyElixir.AgentProfiles

    @enforce_keys [:id, :provider, :account_key, :scopes, :options]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            provider: AgentProfiles.provider(),
            account_key: String.t(),
            scopes: [AgentProfiles.scope()],
            options: [AgentProfiles.model_option()]
          }
  end

  defmodule Availability do
    @moduledoc "A point-in-time policy and telemetry snapshot supplied by the host."

    alias SymphonyElixir.AgentProfiles

    @enforce_keys [:now_ms]
    defstruct [:now_ms, identities: %{}, account_slots: %{}, provider_slots: %{}, cooldowns: %{}, quotas: %{}]

    @type t :: %__MODULE__{
            now_ms: integer(),
            identities: %{optional(String.t()) => AgentProfiles.identity()},
            account_slots: %{optional(AgentProfiles.account()) => AgentProfiles.slots()},
            provider_slots: %{optional(AgentProfiles.provider()) => AgentProfiles.slots()},
            cooldowns: %{optional(AgentProfiles.account() | AgentProfiles.provider()) => integer()},
            quotas: %{optional(AgentProfiles.quota_scope()) => [AgentProfiles.quota_observation()]}
          }
  end

  @type rejection :: :scope_denied | :identity_unverified | :identity_expired | :identity_denied | :identity_mismatch
  @type wait_reason ::
          :cooldown | :quota_exhausted | :account_capacity_unknown | :account_saturated | :provider_saturated
  @type availability :: {:ready, quota_status()} | {:wait, wait_reason(), integer() | nil, quota_status()}

  @doc """
  Checks the full scope in a single grant and verifies the enrolled identity.

  A successful check is based on the supplied observation. The worker still
  has to verify its identity and effective policy before receiving task data.
  """
  @spec authorize(Profile.t(), scope(), Availability.t()) :: :ok | {:error, rejection()}
  def authorize(%Profile{} = profile, scope, %Availability{} = availability) do
    if Enum.any?(profile.scopes, &covers_scope?(&1, scope)) do
      verify_identity(profile, availability)
    else
      {:error, :scope_denied}
    end
  end

  @doc "Returns observed capacity for a profile and model without allocating a slot."
  @spec availability(Profile.t(), String.t(), Availability.t()) :: availability()
  def availability(%Profile{provider: provider, account_key: account_key}, model, %Availability{} = snapshot) do
    account = {provider, account_key}
    {quota, reset_at} = quota_status(snapshot, account, model)

    with :ready <- cooldown(snapshot, account),
         :ready <- quota_capacity(quota, reset_at),
         :ready <- account_capacity(snapshot.account_slots[account]),
         :ready <- provider_capacity(snapshot.provider_slots[provider]) do
      {:ready, quota}
    else
      {:wait, reason, retry_at} -> {:wait, reason, retry_at, quota}
    end
  end

  defp covers_scope?(grant, %{repositories: [_ | _] = requested} = scope) do
    grant.project == scope.project and
      grant.data_class == scope.data_class and
      grant.workspace_policy == scope.workspace_policy and
      grant.access == scope.access and
      Enum.all?(requested, &(&1 in grant.repositories))
  end

  defp covers_scope?(_grant, _scope), do: false

  defp verify_identity(profile, snapshot) do
    account_key = profile.account_key

    case snapshot.identities[profile.id] do
      %{account_key: other} when other != account_key ->
        {:error, :identity_mismatch}

      %{status: :denied} ->
        {:error, :identity_denied}

      %{status: :expired} ->
        {:error, :identity_expired}

      %{status: :verified, expires_at_ms: expires_at} when is_integer(expires_at) and expires_at <= snapshot.now_ms ->
        {:error, :identity_expired}

      %{account_key: ^account_key, status: :verified, expires_at_ms: expires_at} when is_integer(expires_at) ->
        :ok

      _ ->
        {:error, :identity_unverified}
    end
  end

  defp cooldown(snapshot, {provider, _account_key} = account) do
    snapshot.cooldowns
    |> Map.take([provider, account])
    |> Map.values()
    |> Enum.filter(&(&1 > snapshot.now_ms))
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> :ready
      until_ms -> {:wait, :cooldown, until_ms}
    end
  end

  defp quota_status(snapshot, {provider, account_key} = account, model) do
    observations = Map.get(snapshot.quotas, account, []) ++ Map.get(snapshot.quotas, {provider, account_key, model}, [])
    fresh = Enum.filter(observations, &(&1.expires_at_ms > snapshot.now_ms))

    case Enum.filter(fresh, &(&1.status == :exhausted)) do
      [] ->
        if fresh != [] and fresh == observations and Enum.all?(fresh, &(&1.status == :available)) do
          {:available, nil}
        else
          {:unknown, nil}
        end

      exhausted ->
        {:exhausted, quota_reset(exhausted, snapshot.now_ms)}
    end
  end

  defp quota_reset(exhausted, now_ms) do
    resets = Enum.map(exhausted, & &1.reset_at_ms)

    if Enum.all?(resets, &(is_integer(&1) and &1 > now_ms)), do: Enum.max(resets)
  end

  defp quota_capacity(:exhausted, reset_at), do: {:wait, :quota_exhausted, reset_at}
  defp quota_capacity(_status, _reset_at), do: :ready

  defp account_capacity(nil), do: {:wait, :account_capacity_unknown, nil}

  defp account_capacity(%{running: running, limit: limit})
       when is_integer(running) and is_integer(limit) and running >= 0 and running < limit,
       do: :ready

  defp account_capacity(_slots), do: {:wait, :account_saturated, nil}

  defp provider_capacity(nil), do: :ready

  defp provider_capacity(%{running: running, limit: limit})
       when is_integer(running) and is_integer(limit) and running >= 0 and running < limit,
       do: :ready

  defp provider_capacity(_slots), do: {:wait, :provider_saturated, nil}
end
