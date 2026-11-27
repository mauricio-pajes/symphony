defmodule SymphonyElixir.InternalAdmission do
  @moduledoc """
  Stores internal workflow admission and launch reservations for a local scheduler.

  The state directory must be provisioned outside worker access. A journal handle
  belongs to the OTP process that opened it. The deployment must enforce one
  scheduler per journal, including across BEAM instances.

  A failed write or sync leaves dispatch unauthorized. Reopen and reconcile the
  journal before proceeding. The caller verifies the physical workspace identity,
  OS process identity, worker exit, and approval for each explicit mutation.
  """

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.PathSafety

  @journal_file "admission.json"
  @version 1
  @max_records 512
  @max_bytes 1_048_576
  @max_generation 9_007_199_254_740_991
  @statuses %{ready: "ready", parked: "parked", completed: "completed"}

  @enforce_keys [:root, :root_identity, :owner, :uid, :boot_id]
  defstruct @enforce_keys

  @type scope :: {project_id :: String.t(), issue_id :: String.t()}
  @type binding :: {run_id :: String.t(), generation :: non_neg_integer()}
  @type attempt_id :: {run_id :: String.t(), boot_id :: String.t(), generation :: pos_integer()}
  @type lease :: %{boot_id: String.t(), generation: pos_integer(), process_identity: String.t() | nil}
  @type disposition :: :ready | :parked | :completed
  @type record :: %{
          project_id: String.t(),
          issue_id: String.t(),
          run_id: String.t(),
          workspace_id: String.t(),
          boot_id: String.t(),
          generation: non_neg_integer(),
          status: disposition(),
          lease: lease() | nil
        }
  @type proof :: :process_tree_absence_verified | {:process_tree_drained, process_identity :: String.t()}
  @opaque t :: %__MODULE__{
            root: Path.t(),
            root_identity: {non_neg_integer(), non_neg_integer(), non_neg_integer()},
            owner: pid(),
            uid: non_neg_integer(),
            boot_id: String.t()
          }

  @doc "Provisions an empty journal only when no previous ledger exists."
  @spec initialize(Path.t(), Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def initialize(state_root, workspace_root, boot_id) do
    with {:ok, journal} <- build_handle(state_root, workspace_root, boot_id),
         :ok <- require_new_journal(journal),
         :ok <- persist(journal, %{}) do
      {:ok, journal}
    end
  end

  @doc "Opens an existing journal. A missing or corrupt ledger prevents scheduling."
  @spec open(Path.t(), Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def open(state_root, workspace_root, boot_id) do
    with {:ok, journal} <- build_handle(state_root, workspace_root, boot_id),
         {:ok, _records} <- read_records(journal) do
      {:ok, journal}
    end
  end

  @doc "Reads the durable admission, including any unresolved lease from a previous boot."
  @spec lookup(t(), scope()) :: {:ok, record() | nil} | {:error, term()}
  def lookup(journal, scope) do
    with :ok <- validate_scope(scope),
         {:ok, records} <- read_records(journal) do
      {:ok, Map.get(records, scope)}
    end
  end

  @doc "Admits a previously unrecorded issue after host authorization."
  @spec admit(t(), scope(), String.t(), String.t()) :: :ok | {:error, term()}
  def admit(journal, {project_id, issue_id} = scope, run_id, workspace_id) do
    with :ok <- validate_scope(scope),
         true <- identifier?(run_id) and identifier?(workspace_id),
         {:ok, records} <- read_records(journal),
         :ok <- check_admission(records, scope, run_id, workspace_id) do
      record = %{
        project_id: project_id,
        issue_id: issue_id,
        run_id: run_id,
        workspace_id: workspace_id,
        boot_id: journal.boot_id,
        generation: 0,
        status: :ready,
        lease: nil
      }

      persist(journal, Map.put(records, scope, record))
    else
      false -> {:error, :invalid_admission}
      error -> error
    end
  end

  @doc "Persists a pending lease before the selected worker is launched."
  @spec reserve(t(), scope(), attempt_id()) :: :ok | {:error, term()}
  def reserve(journal, scope, attempt_id) do
    update(journal, scope, &reserve_record(&1, journal.boot_id, attempt_id))
  end

  @doc "Attaches the host-verified process identity before the worker may write."
  @spec attach(t(), scope(), attempt_id(), String.t()) :: :ok | {:error, term()}
  def attach(journal, scope, attempt_id, process_identity) do
    if identifier?(process_identity) do
      update(journal, scope, &attach_record(&1, journal.boot_id, attempt_id, process_identity))
    else
      {:error, :invalid_process_identity}
    end
  end

  @doc """
  Clears a lease only with host-verified process-tree reconciliation.

  A pending lease requires verified absence of its entire process tree. An
  attached lease requires verified exit of the recorded process identity.
  """
  @spec finish(t(), scope(), attempt_id(), proof(), disposition()) :: :ok | {:error, term()}
  def finish(journal, scope, attempt_id, proof, disposition) when is_map_key(@statuses, disposition) do
    update(journal, scope, &finish_record(&1, attempt_id, proof, disposition))
  end

  @doc "Records an explicit park or completion for an inactive admission."
  @spec hold(t(), scope(), binding(), :parked | :completed) :: :ok | {:error, term()}
  def hold(journal, scope, binding, disposition) when disposition in [:parked, :completed] do
    update(journal, scope, fn record ->
      with :ok <- require_inactive(record, binding) do
        {:ok, %{record | status: disposition}}
      end
    end)
  end

  @doc """
  Rearms an eligible admission after explicit authorization and workspace checks.

  A fresh daemon must rearm earlier ready records as well as parked ones.
  Completed issues and unresolved leases cannot be rearmed.
  """
  @spec resume(t(), scope(), binding()) :: :ok | {:error, term()}
  def resume(journal, scope, binding) do
    update(journal, scope, fn record ->
      with :ok <- require_inactive(record, binding) do
        {:ok, %{record | status: :ready, boot_id: journal.boot_id}}
      end
    end)
  end

  defp build_handle(state_root, workspace_root, boot_id) do
    with true <- identifier?(boot_id) and Path.type(state_root) == :absolute and Path.type(workspace_root) == :absolute,
         {:ok, %File.Stat{type: :directory}} <- File.lstat(state_root),
         {:ok, workspace_identity} <- directory_identity(workspace_root),
         {:ok, state_path} <- PathSafety.canonicalize(state_root),
         {:ok, workspace_path} <- PathSafety.canonicalize(workspace_root),
         {:ok, stat} <- File.lstat(state_path),
         true <- stat.type == :directory and private?(stat.mode),
         false <- within_directory?(workspace_path, identity(stat)),
         false <- within_directory?(state_path, workspace_identity) do
      {:ok, %__MODULE__{root: state_path, root_identity: identity(stat), owner: self(), uid: stat.uid, boot_id: boot_id}}
    else
      _error -> {:error, :invalid_state_directory}
    end
  end

  defp directory_identity(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, identity(stat)}
      {:error, :enoent} -> {:ok, nil}
      _error -> {:error, :cannot_stat_directory}
    end
  end

  defp within_directory?(_path, nil), do: false

  defp within_directory?(path, root_identity) do
    case directory_identity(path) do
      {:ok, other} when other != root_identity ->
        parent = Path.dirname(path)
        parent != path and within_directory?(parent, root_identity)

      _same_or_unavailable ->
        true
    end
  end

  defp require_new_journal(journal) do
    case File.lstat(path(journal)) do
      {:error, :enoent} -> :ok
      _existing_or_inaccessible -> {:error, :journal_already_exists}
    end
  end

  defp read_records(journal) do
    with :ok <- check_directory(journal),
         {:ok, stat} <- File.lstat(path(journal)),
         true <- safe_file?(stat, journal.uid),
         {:ok, data} <- File.open(path(journal), [:read, :binary], &IO.binread(&1, @max_bytes + 1)),
         true <- is_binary(data) and byte_size(data) <= @max_bytes do
      decode(data)
    else
      {:error, :enoent} -> {:error, :journal_missing}
      false -> {:error, :unsafe_journal_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_directory(%__MODULE__{owner: owner}) when owner != self(), do: {:error, :not_journal_owner}

  defp check_directory(journal) do
    with {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(journal.root),
         true <- stat.uid == journal.uid and private?(stat.mode) and identity(stat) == journal.root_identity do
      :ok
    else
      _error -> {:error, :state_directory_changed}
    end
  end

  defp persist(journal, records) do
    data = Jason.encode!(%{version: @version, records: records |> Map.values() |> Enum.sort_by(&record_scope/1)})
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    temporary = Path.join(journal.root, ".admission-#{suffix}")

    with :ok <- check_directory(journal) do
      atomic_replace(journal, temporary, data)
    end
  end

  defp atomic_replace(journal, temporary, data) do
    with {:ok, file} <- File.open(temporary, [:write, :exclusive, :raw, :binary]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- :file.write(file, data),
             :ok <- :file.sync(file),
             :ok <- File.rename(temporary, path(journal)) do
          sync_directory(journal.root)
        end
      after
        _ = :file.close(file)
        _ = File.rm(temporary)
      end
    end
  end

  defp sync_directory(path) do
    with {:ok, dir} <- :file.open(String.to_charlist(path), [:raw, :read, :directory]) do
      try do
        :file.sync(dir)
      after
        _ = :file.close(dir)
      end
    end
  end

  defp update(journal, scope, transform) do
    with :ok <- validate_scope(scope),
         {:ok, records} <- read_records(journal),
         {:ok, current} <- Map.fetch(records, scope),
         {:ok, record} <- transform.(current) do
      persist(journal, Map.put(records, scope, record))
    else
      :error -> {:error, :not_admitted}
      error -> error
    end
  end

  defp reserve_record(%{lease: %{}}, _boot_id, _attempt_id), do: {:error, :lease_unresolved}

  defp reserve_record(%{status: :ready, run_id: run_id, boot_id: boot_id} = record, boot_id, {run_id, boot_id, generation})
       when is_integer(generation) and generation == record.generation + 1 and generation <= @max_generation do
    lease = %{boot_id: boot_id, generation: generation, process_identity: nil}
    {:ok, %{record | generation: generation, lease: lease}}
  end

  defp reserve_record(_record, _boot_id, _attempt_id), do: {:error, :not_dispatchable}

  defp attach_record(
         %{run_id: run_id, lease: %{boot_id: boot_id, generation: generation, process_identity: nil} = lease} = record,
         boot_id,
         {run_id, boot_id, generation},
         process_identity
       ) do
    {:ok, %{record | lease: %{lease | process_identity: process_identity}}}
  end

  defp attach_record(_record, _boot_id, _attempt_id, _process_identity), do: {:error, :stale_lease}

  defp finish_record(%{run_id: run_id, lease: %{boot_id: boot_id, generation: generation} = lease} = record, {run_id, boot_id, generation}, proof, disposition) do
    if verified_exit?(lease, proof) do
      {:ok, %{record | status: disposition, lease: nil}}
    else
      {:error, :reconciliation_proof_required}
    end
  end

  defp finish_record(_record, _attempt_id, _proof, _disposition), do: {:error, :stale_lease}

  defp verified_exit?(%{process_identity: nil}, :process_tree_absence_verified), do: true
  defp verified_exit?(%{process_identity: id}, {:process_tree_drained, id}) when is_binary(id), do: true
  defp verified_exit?(_lease, _proof), do: false

  defp require_inactive(%{lease: %{}}, _binding), do: {:error, :lease_unresolved}
  defp require_inactive(%{status: :completed}, _binding), do: {:error, :already_completed}
  defp require_inactive(%{run_id: run_id, generation: gen}, {run_id, gen}), do: :ok
  defp require_inactive(_record, _binding), do: {:error, :stale_admission}

  defp check_admission(records, scope, run_id, workspace_id) do
    cond do
      Map.has_key?(records, scope) -> {:error, :already_admitted}
      map_size(records) >= @max_records -> {:error, :journal_full}
      Enum.any?(records, fn {_scope, record} -> record.run_id == run_id end) -> {:error, :run_already_admitted}
      Enum.any?(records, fn {_scope, record} -> record.workspace_id == workspace_id end) -> {:error, :workspace_already_admitted}
      true -> :ok
    end
  end

  defp decode(data) do
    with {:ok, %{"version" => @version, "records" => entries} = decoded} <- Jason.decode(data),
         true <- map_size(decoded) == 2 and is_list(entries) and length(entries) <= @max_records do
      decode_records(entries)
    else
      _error -> {:error, :invalid_journal}
    end
  end

  defp decode_records(entries) do
    result =
      Enum.reduce_while(entries, {%{}, MapSet.new(), MapSet.new()}, fn entry, {records, runs, workspaces} ->
        with {:ok, record} <- decode_record(entry),
             scope = record_scope(record),
             false <- Map.has_key?(records, scope) or MapSet.member?(runs, record.run_id) or MapSet.member?(workspaces, record.workspace_id) do
          {:cont, {Map.put(records, scope, record), MapSet.put(runs, record.run_id), MapSet.put(workspaces, record.workspace_id)}}
        else
          _error -> {:halt, :invalid}
        end
      end)

    case result do
      {records, _runs, _workspaces} -> {:ok, records}
      :invalid -> {:error, :invalid_journal}
    end
  end

  defp decode_record(
         %{
           "project_id" => project_id,
           "issue_id" => issue_id,
           "run_id" => run_id,
           "workspace_id" => workspace_id,
           "boot_id" => boot_id,
           "generation" => generation,
           "status" => status,
           "lease" => raw_lease
         } = entry
       )
       when map_size(entry) == 8 and is_integer(generation) and generation in 0..@max_generation do
    with true <- Enum.all?([project_id, issue_id, run_id, workspace_id, boot_id], &identifier?/1),
         {state, _name} <- Enum.find(@statuses, fn {_key, name} -> name == status end),
         {:ok, lease} <- decode_lease(raw_lease, boot_id, generation, state) do
      {:ok,
       %{
         project_id: project_id,
         issue_id: issue_id,
         run_id: run_id,
         workspace_id: workspace_id,
         boot_id: boot_id,
         generation: generation,
         status: state,
         lease: lease
       }}
    end
  end

  defp decode_record(_entry), do: :invalid

  defp decode_lease(nil, _boot_id, _generation, _state), do: {:ok, nil}

  defp decode_lease(%{"boot_id" => boot_id, "generation" => generation, "process_identity" => id} = lease, boot_id, generation, :ready)
       when map_size(lease) == 3 and generation > 0 do
    if is_nil(id) or identifier?(id) do
      {:ok, %{boot_id: boot_id, generation: generation, process_identity: id}}
    else
      :invalid
    end
  end

  defp decode_lease(_lease, _boot_id, _generation, _state), do: :invalid

  defp validate_scope({project_id, issue_id}) do
    if identifier?(project_id) and identifier?(issue_id), do: :ok, else: {:error, :invalid_scope}
  end

  defp record_scope(record), do: {record.project_id, record.issue_id}
  defp path(journal), do: Path.join(journal.root, @journal_file)
  defp safe_file?(stat, uid), do: stat.type == :regular and stat.links == 1 and stat.uid == uid and private?(stat.mode) and stat.size <= @max_bytes
  defp private?(mode), do: band(mode, 0o077) == 0
  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}
  defp identifier?(value), do: is_binary(value) and byte_size(value) <= 128 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:@-]*\z/, value)
end
