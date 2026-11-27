defmodule SymphonyElixir.InternalContainerWorker do
  @moduledoc """
  Runs local, network-disabled internal attempts on a trusted Docker Engine.

  The scheduler reserves and attaches a created container before handing its
  lease to a supervised task for execution. A task's exit does not release
  the lease. The scheduler must drain the container and settle the journal
  independently. The caller supplies trusted commands, images, and workspaces.
  """

  alias SymphonyElixir.{InternalAdmission, InternalWorkflow, PathSafety}

  @api "/v1.47"
  @label "io.symphony.phase-lease"
  @control_timeout_ms 5_000
  @max_wait_ms 1_800_000

  @enforce_keys [:socket, :engine_id, :workspace_root]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{socket: Path.t(), engine_id: String.t(), workspace_root: Path.t()}
  @type command :: %{image: String.t(), argv: [String.t()]}
  @opaque lease :: %{attempt_id: InternalAdmission.attempt_id(), identity: String.t()}

  @doc "Binds the local worker to a Unix endpoint and the engine currently behind it."
  @spec open(Path.t(), Path.t()) :: {:ok, t()} | {:error, term()}
  def open(socket, workspace_root) do
    with true <- Path.type(socket) == :absolute and Path.type(workspace_root) == :absolute,
         {:ok, root} <- PathSafety.canonicalize(workspace_root),
         {:ok, %File.Stat{type: :directory}} <- File.stat(root),
         {:ok, engine_id} <- engine_id(socket) do
      {:ok, %__MODULE__{socket: socket, engine_id: engine_id, workspace_root: root}}
    else
      false -> {:error, :invalid_worker_paths}
      {:ok, _stat} -> {:error, :invalid_workspace_root}
      error -> error
    end
  end

  @doc "Returns the physical identity of an existing direct child of the workspace root."
  @spec workspace_id(t(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def workspace_id(worker, path) do
    with {:ok, _path, stat} <- workspace(worker, path), do: {:ok, fingerprint(stat)}
  end

  @doc """
  Reserves, creates without starting, and durably attaches the container.

  Journal and workspace mismatches are rejected before a Docker mutation.
  A failed or ambiguous create or attach keeps the reservation unresolved.
  """
  @spec prepare(t(), InternalAdmission.t(), InternalWorkflow.attempt(), Path.t(), command()) ::
          {:ok, lease()} | {:error, term()}
  def prepare(worker, journal, attempt, path, command) do
    scope = {attempt.project_id, attempt.issue_id}

    with {:ok, path, stat} <- workspace(worker, path),
         :ok <- validate_binding(journal, scope, attempt.id, stat),
         :ok <- check_engine(worker),
         :ok <- check_command(worker, command),
         opts = container_options(worker, path, stat, attempt, command),
         :ok <- InternalAdmission.reserve(journal, scope, attempt.id),
         {:ok, id} <- create_container(worker, attempt.id, opts),
         identity = "docker:" <> worker.engine_id <> ":" <> id,
         :ok <- InternalAdmission.attach(journal, scope, attempt.id, identity) do
      {:ok, %{attempt_id: attempt.id, identity: identity}}
    end
  end

  @doc "Starts an attached lease and observes the exit code. Drain even if execution returns an error."
  @spec run(t(), lease(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(worker, %{attempt_id: attempt_id, identity: identity}, timeout)
      when is_integer(timeout) and timeout in 1..@max_wait_ms do
    with {:ok, id} <- container_id(worker, identity),
         :ok <- check_engine(worker),
         {:ok, {:created, ^id}} <- inspect_container(worker, attempt_id, id),
         {:ok, _response} <- request(worker.socket, :post, "/containers/" <> id <> "/start", 204),
         {:ok, %{"StatusCode" => status} = result} when is_integer(status) and status >= 0 <-
           request(worker.socket, :post, "/containers/" <> id <> "/wait?condition=not-running", 200, receive_timeout: timeout),
         nil <- Map.get(result, "Error") do
      {:ok, status}
    else
      {:ok, :absent} -> {:error, :container_missing}
      {:ok, {:present, _id}} -> {:error, :container_already_started}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_container_exit}
    end
  end

  @doc """
  Removes the container as a unit and confirms the recorded identity is absent.

  Can run after a scheduler restart using the identity from the journal.
  Failed checks, an unavailable engine, or a changed identity retain the lease.
  """
  @spec drain(t(), InternalAdmission.attempt_id(), String.t()) ::
          {:ok, InternalAdmission.proof()} | {:error, term()}
  def drain(worker, attempt_id, identity) do
    with {:ok, id} <- container_id(worker, identity),
         :ok <- check_engine(worker),
         {:ok, observed} <- inspect_container(worker, attempt_id, id),
         :ok <- remove(worker, id, observed),
         :ok <- check_engine(worker),
         {:ok, :absent} <- inspect_container(worker, attempt_id, id) do
      {:ok, {:process_tree_drained, identity}}
    else
      {:ok, _present} -> {:error, :container_still_present}
      error -> error
    end
  end

  @doc "Reconciles an unattached reservation only when the matching stopped container is observed."
  @spec drain_pending(t(), InternalAdmission.attempt_id()) :: {:ok, InternalAdmission.proof()} | {:error, term()}
  def drain_pending(worker, attempt_id) do
    name = lease_name(worker, attempt_id)

    with :ok <- check_engine(worker),
         {:ok, {:created, id}} <- inspect_container(worker, attempt_id, name),
         :ok <- remove(worker, id, :created),
         :ok <- check_engine(worker),
         {:ok, :absent} <- inspect_container(worker, attempt_id, name) do
      {:ok, :process_tree_absence_verified}
    else
      {:ok, _observation} -> {:error, :pending_container_unverified}
      error -> error
    end
  end

  defp workspace(%{workspace_root: root}, path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %File.Stat{type: :directory, uid: uid} = stat} when uid > 0 <- File.lstat(path),
         {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- Path.dirname(canonical) == root do
      {:ok, canonical, stat}
    else
      _error -> {:error, :invalid_container_workspace}
    end
  end

  defp fingerprint(stat), do: "fs-#{stat.major_device}-#{stat.minor_device}-#{stat.inode}"

  defp validate_binding(journal, scope, {run_id, _boot, _generation}, stat) do
    with {:ok, %{run_id: ^run_id, workspace_id: id}} <- InternalAdmission.lookup(journal, scope),
         true <- id == fingerprint(stat) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :workspace_binding_mismatch}
    end
  end

  defp check_command(worker, %{image: "sha256:" <> hash = image, argv: [entry | args]}) do
    with true <- hex_id?(hash) and valid_argv?(entry, args),
         {:ok, %{"Id" => ^image, "Config" => config}} when is_map(config) <-
           request(worker.socket, :get, "/images/" <> image <> "/json", 200),
         volumes = Map.get(config, "Volumes"),
         true <- is_nil(volumes) or volumes == %{} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :unsupported_container_command}
    end
  end

  defp check_command(_worker, _command), do: {:error, :unsupported_container_command}

  defp valid_argv?(entry, args) do
    is_binary(entry) and String.starts_with?(entry, "/") and
      Enum.all?([entry | args], &(is_binary(&1) and String.valid?(&1) and not String.contains?(&1, <<0>>)))
  end

  defp container_options(worker, path, stat, attempt, %{image: image, argv: [entry | args]}) do
    %{
      Image: image,
      Entrypoint: [entry],
      Cmd: args,
      WorkingDir: "/workspace",
      User: "#{stat.uid}:#{stat.gid}",
      Labels: %{@label => lease_name(worker, attempt.id)},
      NetworkDisabled: true,
      Healthcheck: %{Test: ["NONE"]},
      HostConfig: %{
        NetworkMode: "none",
        CapDrop: ["ALL"],
        SecurityOpt: ["no-new-privileges"],
        ReadonlyRootfs: true,
        PidsLimit: 128,
        Memory: 536_870_912,
        LogConfig: %{Type: "none"},
        Tmpfs: %{"/tmp" => "rw,noexec,nosuid,nodev,size=67108864"},
        Mounts: [
          %{
            Type: "bind",
            Source: path,
            Target: "/workspace",
            ReadOnly: attempt.write_mode != :workspace_write,
            BindOptions: %{NonRecursive: true, Propagation: "rprivate"}
          }
        ]
      }
    }
  end

  defp create_container(worker, attempt_id, options) do
    with {:ok, %{"Id" => id}} <- request(worker.socket, :post, "/containers/create?name=" <> lease_name(worker, attempt_id), 201, json: options),
         true <- hex_id?(id) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_container_identity}
    end
  end

  defp inspect_container(worker, attempt_id, identifier) do
    name = lease_name(worker, attempt_id)

    case request(worker.socket, :get, "/containers/" <> identifier <> "/json", [200, 404]) do
      {:ok, %{status: 404}} ->
        {:ok, :absent}

      {:ok, %{body: %{"Id" => id, "Config" => %{"Labels" => %{@label => ^name}}, "State" => %{"Status" => status}}}}
      when identifier in [id, name] ->
        if hex_id?(id) do
          {:ok, {if(status == "created", do: :created, else: :present), id}}
        else
          {:error, :invalid_container_identity}
        end

      {:ok, _response} ->
        {:error, :container_binding_mismatch}

      error ->
        error
    end
  end

  defp remove(_worker, _id, :absent), do: :ok

  defp remove(worker, id, _present) do
    with {:ok, _response} <- request(worker.socket, :delete, "/containers/" <> id <> "?force=true&v=true", [204, 404]), do: :ok
  end

  defp lease_name(%{workspace_root: root}, attempt_id) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary({root, attempt_id}))
    "symphony-phase-" <> Base.encode16(hash, case: :lower)
  end

  defp container_id(%{engine_id: engine_id}, identity) do
    with ["docker", ^engine_id, id] <- String.split(identity, ":"),
         true <- hex_id?(id) do
      {:ok, id}
    else
      _invalid -> {:error, :invalid_container_identity}
    end
  end

  defp hex_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-f0-9]{64}\z/, id)

  defp check_engine(%{socket: socket, engine_id: expected}) do
    case engine_id(socket) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :container_engine_changed}
      error -> error
    end
  end

  defp engine_id(socket) do
    with {:ok, %{"ID" => id, "OSType" => "linux"}} when is_binary(id) <- request(socket, :get, "/info", 200),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{1,48}\z/, id) do
      {:ok, id}
    else
      {:error, reason} -> {:error, reason}
      _unsupported -> {:error, :unsupported_container_engine}
    end
  end

  defp request(socket, method, path, success, opts \\ []) do
    defaults = [
      method: method,
      url: "http://" <> @api <> path,
      unix_socket: socket,
      redirect: false,
      retry: false,
      receive_timeout: @control_timeout_ms,
      connect_options: [timeout: @control_timeout_ms]
    ]

    case Req.request(Keyword.merge(defaults, opts)) do
      {:ok, %{status: ^success, body: body}} ->
        {:ok, body}

      {:ok, %{status: status} = response} when is_list(success) ->
        if status in success, do: {:ok, response}, else: {:error, {:container_engine_status, status}}

      {:ok, %{status: status}} ->
        {:error, {:container_engine_status, status}}

      {:error, _reason} ->
        {:error, :container_engine_unavailable}
    end
  end
end
