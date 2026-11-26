defmodule SymphonyElixir.HeadlessAgent do
  @moduledoc """
  Executes local coding CLIs and consumes their structured terminal results.
  """

  alias SymphonyElixir.{Config, PathSafety}

  @spec run(atom(), [String.t()], Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(provider, [command | args], workspace, prompt, opts) do
    with {:ok, workspace} <- workspace_path(workspace),
         executable when is_binary(executable) <- System.find_executable(command),
         {:ok, scratch} <- scratch_directory() do
      run_in_directory(provider, executable, args, workspace, scratch, prompt, opts)
    else
      nil -> {:error, {:agent_executable_missing, provider}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_path(workspace) do
    with {:ok, path} <- PathSafety.canonicalize(Path.expand(workspace)),
         {:ok, root} <- PathSafety.canonicalize(Config.local_workspace_root()),
         true <- String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      _ -> {:error, :invalid_headless_workspace}
    end
  end

  defp scratch_directory do
    path = Path.join(System.tmp_dir!(), "symphony-agent-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))

    with :ok <- File.mkdir(path), do: {:ok, path}
  end

  defp run_in_directory(provider, executable, args, workspace, scratch, prompt, opts) do
    File.chmod!(scratch, 0o700)
    input = Path.join(scratch, "input")
    File.write!(input, encode_input(provider, prompt))

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        args: Enum.map(["-c", ~s(exec "$@" < "$0" 2>/dev/null), input, executable | args], &String.to_charlist/1),
        cd: String.to_charlist(if(provider == :classifier, do: scratch, else: workspace)),
        env: Enum.map(opts[:secret_names] || [], &{String.to_charlist(&1), false}),
        line: 8_388_608
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    cleanup = watch_owner(self(), os_pid, scratch)
    progress = Keyword.get(opts, :on_progress, fn -> :ok end)
    timeout_ms = opts[:timeout_ms] || 300_000
    deadline = if provider == :classifier, do: System.monotonic_time(:millisecond) + timeout_ms
    progress.()

    try do
      await_result(port, provider, timeout_ms, deadline, progress, nil)
    after
      send(cleanup, {:finished, self()})

      receive do
        {:cleaned_up, ^cleanup} -> :ok
      end
    end
  rescue
    error in [File.Error, ErlangError, ArgumentError] ->
      File.rm_rf(scratch)
      {:error, {:agent_launch_failed, provider, error.__struct__}}
  end

  defp watch_owner(owner, os_pid, scratch) do
    spawn(fn ->
      monitor = Process.monitor(owner)

      receive do
        {:finished, ^owner} ->
          clean_process(os_pid, scratch)
          send(owner, {:cleaned_up, self()})

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          clean_process(os_pid, scratch)
      end
    end)
  end

  defp clean_process(os_pid, scratch) do
    System.cmd("/bin/kill", ["-KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
    File.rm_rf(scratch)
  end

  defp encode_input(:gemini, prompt) do
    Jason.encode!(%{event: "user", message: %{content: prompt}}) <> "\n"
  end

  defp encode_input(_provider, prompt), do: prompt

  defp await_result(port, provider, timeout_ms, deadline, progress, result) do
    remaining = if deadline, do: deadline - System.monotonic_time(:millisecond), else: timeout_ms

    if remaining <= 0 do
      {:error, {:agent_timeout, provider}}
    else
      receive_result(port, provider, timeout_ms, deadline, progress, result, remaining)
    end
  end

  defp receive_result(port, provider, timeout_ms, deadline, progress, result, remaining) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        progress.()
        await_result(port, provider, timeout_ms, deadline, progress, parse_result(provider, Jason.decode(line), result))

      {^port, {:data, {:noeol, _line}}} ->
        {:error, {:agent_output_too_large, provider}}

      {^port, {:exit_status, 0}} ->
        result || {:error, {:missing_agent_result, provider}}

      {^port, {:exit_status, status}} ->
        {:error, {:agent_exit, provider, status}}
    after
      remaining -> {:error, {:agent_timeout, provider}}
    end
  end

  defp parse_result(:claude, {:ok, %{"type" => "result", "is_error" => false, "result" => result}}, _previous)
       when is_binary(result), do: {:ok, result}

  defp parse_result(:gemini, {:ok, %{"event" => "result", "result" => %{"status" => "SUCCESS", "response" => result}}}, _previous)
       when is_binary(result), do: {:ok, result}

  defp parse_result(:classifier, {:ok, %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => result}}}, _previous)
       when is_binary(result), do: {:ok, result}

  defp parse_result(_provider, _event, previous), do: previous
end
