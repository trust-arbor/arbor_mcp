defmodule Arbor.MCP.Server.Runtime.HTTPWriterProxy do
  @moduledoc false
  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  alias Arbor.MCP.Server.Runtime.{Deadline, HTTPWriterRegistry, Initialization, Ref}

  def start_link(opts) do
    table = Keyword.fetch!(opts, :table)

    with {:ok, _context} <- Initialization.begin(table, opts[:config], :cohort),
         {:ok, pid} <-
           GenServer.start_link(__MODULE__, opts, timeout: Initialization.remaining(table)),
         :ok <- Initialization.watch(table, pid) do
      {:ok, pid}
    end
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    root = Keyword.fetch!(opts, :supervisor)
    config = Keyword.fetch!(opts, :config)
    :ok = Initialization.watch(table, self())

    case ensure_domain(table, root, config) do
      {:ok, domain} ->
        :ets.insert(table, {:http_writer_proxy, self()})
        monitor = Process.monitor(HTTPWriterRegistry.guardian(domain))
        {:ok, %{domain: domain, monitor: monitor}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: {:stop, :http_writer_guardian_unavailable, state}

  def handle_info(_message, state), do: {:noreply, state}

  # Called by the actual Plug process at entry, before body/auth/era work.
  # This facade accepts no caller-authored writer, generation, scope or proof.
  def capture(runtime, opts \\ []) do
    started = Deadline.now()

    with {:ok, runtime} <- Ref.validate(runtime),
         true <- Initialization.ready?(Ref.table(runtime)),
         {:ok, record} <- record(runtime),
         {:ok, deadline} <- entry_deadline(started, record.request_timeout_ms, opts),
         {:ok, proxy} <- active_proxy(runtime) do
      HTTPWriterRegistry.capture(record.domain, proxy, deadline)
    else
      false -> {:error, :runtime_unavailable}
      error -> error
    end
  end

  def domain(runtime) do
    with {:ok, record} <- record(runtime), do: {:ok, record.domain}
  end

  def seal({:ok, domain}), do: HTTPWriterRegistry.seal(domain)
  def seal(_unavailable), do: {:error, :http_io_cleanup_unconfirmed}

  def cleanup_status({:ok, domain}), do: HTTPWriterRegistry.cleanup_status(domain)
  def cleanup_status(_unavailable), do: {:error, :http_io_cleanup_unconfirmed}

  def active_proxy(runtime) do
    case :ets.lookup(Ref.table(runtime), :http_writer_proxy) do
      [{:http_writer_proxy, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :http_writer_unavailable}

      _ ->
        {:error, :http_writer_unavailable}
    end
  rescue
    ArgumentError -> {:error, :http_writer_unavailable}
  end

  defp record(runtime) do
    case :ets.lookup(Ref.table(runtime), :http_writer_domain) do
      [{:http_writer_domain, record}] -> {:ok, record}
      _ -> {:error, :http_writer_unavailable}
    end
  rescue
    ArgumentError -> {:error, :http_writer_unavailable}
  end

  defp ensure_domain(table, root, config) do
    case :ets.lookup(table, :http_writer_domain) do
      [{:http_writer_domain, %{domain: domain}}] ->
        case HTTPWriterRegistry.stats(domain) do
          %{sealed: false} -> {:ok, domain}
          _poisoned -> {:error, :http_writer_domain_unavailable}
        end

      [] ->
        with {:ok, context} <- Initialization.current(table),
             {:ok, domain} <-
               HTTPWriterRegistry.start(root, registry_options(table, root, config, context)) do
          :ets.insert(
            table,
            {:http_writer_domain,
             %{domain: domain, request_timeout_ms: config.request_timeout_ms}}
          )

          {:ok, domain}
        end
    end
  end

  defp registry_options(table, root, config, context) do
    [
      runtime: Ref.new(root, table),
      init_deadline: context.deadline,
      max_writers: config.max_http_writers,
      max_writer_metadata_bytes: config.max_http_writer_metadata_bytes,
      max_io_frames: config.max_http_io_frames,
      max_io_bytes: config.max_http_io_bytes,
      max_io_frame_bytes: config.max_http_io_frame_bytes,
      failure_timeout_ms: config.output_timeout_ms
    ]
  end

  defp entry_deadline(started, maximum, opts) do
    with {:ok, values} <- entry_options(opts, %{}, 2),
         timeout = Map.get(values, :timeout, maximum),
         true <- is_integer(timeout) and timeout > 0 and timeout <= 0xFFFFFFFF,
         deadline = Map.get(values, :deadline, started + min(maximum, timeout)),
         :ok <- Deadline.validate(deadline),
         deadline = min(deadline, started + min(maximum, timeout)),
         true <- deadline > Deadline.now() do
      {:ok, deadline}
    else
      _invalid -> {:error, :invalid_http_entry_options}
    end
  end

  defp entry_options([], values, _remaining), do: {:ok, values}

  defp entry_options([{key, value} | rest], values, remaining)
       when key in [:deadline, :timeout] and remaining > 0 do
    if Map.has_key?(values, key),
      do: {:error, :invalid_http_entry_options},
      else: entry_options(rest, Map.put(values, key, value), remaining - 1)
  end

  defp entry_options(_opts, _values, _remaining), do: {:error, :invalid_http_entry_options}
end
