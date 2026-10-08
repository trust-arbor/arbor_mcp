defmodule Arbor.MCP.TransportManager do
  @moduledoc """
  Transport abstraction layer with fallback mechanisms.

  Provides a unified interface for transport selection and automatic fallback
  when primary transports fail. Supports configuration-based transport priority
  and health checking.

  ## Features

  - **Smart transport selection**: Automatically choose best available transport
  - **Fallback mechanisms**: Try multiple transports in priority order
  - **Health checking**: Verify transport availability before use
  - **Configuration-driven**: Define transport priorities via config
  - **Error recovery**: Handle transport failures gracefully

  ## Example

      opts = [
        transports: [
          {Arbor.MCP.Transport.HTTP, [url: "http://localhost:8080"]},
          {Arbor.MCP.Transport.Stdio, [command: "my-server"]}
        ],
        fallback_strategy: :sequential,
        health_check_timeout: 5_000
      ]

      {:ok, {transport_mod, transport_state}} = TransportManager.connect(opts)
  """

  require Logger

  @type transport_spec :: {module(), keyword()}
  @type fallback_strategy :: :sequential | :parallel | :fastest
  @type connect_result :: {:ok, {module(), any()}} | {:error, any()}

  @doc """
  Connects using the best available transport from the provided list.

  ## Options

  - `:transports` - List of `{transport_module, opts}` tuples in priority order
  - `:fallback_strategy` - How to handle fallbacks (`:sequential`, `:parallel`, `:fastest`)
  - `:health_check_timeout` - Timeout for transport health checks (default: 5000ms)
  - `:max_retries` - Maximum retries per transport (default: 2)
  - `:retry_interval` - Interval between retries (default: 1000ms)
  """
  @spec connect(keyword()) :: connect_result()
  def connect(opts) do
    transports = Keyword.get(opts, :transports, [])
    strategy = Keyword.get(opts, :fallback_strategy, :sequential)

    if Enum.empty?(transports) do
      {:error, :no_transports_configured}
    else
      do_connect(transports, strategy, opts)
    end
  end

  @doc """
  Checks if a transport module is available and healthy.
  """
  @spec health_check(module(), keyword(), timeout()) :: :ok | {:error, any()}
  def health_check(transport_mod, transport_opts, timeout \\ 5_000) do
    case transport_mod.connect(transport_opts) do
      {:ok, state} ->
        # Try a simple operation to verify health
        case transport_mod.send(state, "ping") do
          {:ok, _new_state} ->
            transport_mod.close(state)
            :ok

          {:error, reason} ->
            transport_mod.close(state)
            {:error, {:health_check_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  catch
    kind, reason ->
      {:error, {:health_check_exception, {kind, reason}}}
  after
    # Brief pause
    :timer.sleep(min(timeout, 100))
  end

  @doc """
  Gets the default transport configuration for common scenarios.
  """
  @spec default_config(atom()) :: keyword()
  def default_config(:local_development) do
    [
      transports: [
        {Arbor.MCP.Transport.HTTP, [url: "http://localhost:8080"]},
        {Arbor.MCP.Transport.Stdio, [command: "mcp-server"]}
      ],
      fallback_strategy: :sequential,
      health_check_timeout: 3_000
    ]
  end

  def default_config(:production) do
    [
      transports: [
        {Arbor.MCP.Transport.HTTP, [url: System.get_env("MCP_SERVER_URL")]},
        {Arbor.MCP.Transport.HTTP, [url: System.get_env("MCP_SSE_URL"), use_sse: true]}
      ],
      fallback_strategy: :sequential,
      health_check_timeout: 10_000,
      max_retries: 3
    ]
  end

  def default_config(:testing) do
    [
      transports: [
        {Arbor.MCP.Transport.Test, []}
      ],
      fallback_strategy: :sequential,
      health_check_timeout: 1_000
    ]
  end

  # Private implementation

  defp do_connect(transports, :sequential, opts) do
    connect_sequential(transports, opts)
  end

  defp do_connect(transports, :parallel, opts) do
    connect_parallel(transports, opts)
  end

  defp do_connect(transports, :fastest, opts) do
    connect_fastest(transports, opts)
  end

  defp connect_sequential([], _opts) do
    {:error, :all_transports_failed}
  end

  defp connect_sequential([{transport_mod, transport_opts} | rest], opts) do
    max_retries = Keyword.get(opts, :max_retries, 2)
    retry_interval = Keyword.get(opts, :retry_interval, 1_000)

    Logger.debug("Attempting connection with #{inspect(transport_mod)}")

    case connect_with_retries(transport_mod, transport_opts, max_retries, retry_interval) do
      {:ok, state} ->
        Logger.info("Successfully connected using #{inspect(transport_mod)}")
        {:ok, {transport_mod, state}}

      {:error, reason} ->
        Logger.warning("Transport #{inspect(transport_mod)} failed: #{inspect(reason)}")
        connect_sequential(rest, opts)
    end
  end

  defp connect_parallel(transports, opts) do
    timeout = Keyword.get(opts, :health_check_timeout, 5_000)

    tasks =
      Enum.map(transports, fn {transport_mod, transport_opts} ->
        Task.async(fn ->
          case connect_with_retries(transport_mod, transport_opts, 1, 0) do
            {:ok, state} -> {:ok, {transport_mod, state}}
            {:error, reason} -> {:error, {transport_mod, reason}}
          end
        end)
      end)

    case Task.yield_many(tasks, timeout) do
      results when is_list(results) ->
        # Find first successful result
        case find_successful_result(results) do
          {:ok, result} ->
            # Cancel remaining tasks
            cancel_remaining_tasks(tasks, results)
            {:ok, result}

          nil ->
            cancel_remaining_tasks(tasks, results)
            {:error, :all_transports_failed}
        end
    end
  end

  defp connect_fastest(transports, opts) do
    # Similar to parallel but returns the first to complete successfully
    connect_parallel(transports, opts)
  end

  defp connect_with_retries(transport_mod, transport_opts, max_retries, retry_interval) do
    do_connect_with_retries(transport_mod, transport_opts, max_retries, retry_interval, 0)
  end

  defp do_connect_with_retries(
         _transport_mod,
         _transport_opts,
         max_retries,
         _retry_interval,
         attempts
       )
       when attempts >= max_retries do
    {:error, :max_retries_exceeded}
  end

  defp do_connect_with_retries(
         transport_mod,
         transport_opts,
         max_retries,
         retry_interval,
         attempts
       ) do
    case transport_mod.connect(transport_opts) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} when attempts < max_retries - 1 ->
        if retry_interval > 0 do
          Process.sleep(retry_interval)
        end

        do_connect_with_retries(
          transport_mod,
          transport_opts,
          max_retries,
          retry_interval,
          attempts + 1
        )

      {:error, reason} ->
        {:error, reason}
    end
  catch
    kind, reason ->
      Logger.warning(
        "Transport #{inspect(transport_mod)} raised exception: #{inspect({kind, reason})}"
      )

      {:error, {:transport_exception, {kind, reason}}}
  end

  defp find_successful_result(results) do
    Enum.find_value(results, fn
      {_task, {:ok, {:ok, result}}} -> {:ok, result}
      _ -> nil
    end)
  end

  defp cancel_remaining_tasks(tasks, completed_results) do
    completed_tasks = Enum.map(completed_results, fn {task, _} -> task end)
    remaining_tasks = tasks -- completed_tasks

    Enum.each(remaining_tasks, fn task ->
      Task.shutdown(task, 1_000)
    end)
  end
end
