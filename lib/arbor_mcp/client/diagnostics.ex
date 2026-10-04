defmodule Arbor.MCP.Client.Diagnostics do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.Diagnostics, as: RuntimeDiagnostics

  @cooperative_modules [
    Arbor.MCP.Client,
    Arbor.MCP.Client.ConnectionScope.Observer,
    Arbor.MCP.Client.Lifetime,
    Arbor.MCP.Client.Subscription,
    Arbor.MCP.Transport.HTTP.ModernStreamClient,
    Arbor.MCP.Transport.SSEClient
  ]
  @counts [
    :pending_requests,
    :pending_batches,
    :async_post_tasks,
    :server_request_tasks,
    :mrtr_tasks,
    :subscriptions,
    :notification_listeners,
    :workers,
    :reservations,
    :transports
  ]

  # Only built-in owners explicitly understand this private constructor. A
  # custom native module still receives its supplied initialization term.
  def argument(module, argument) when module in @cooperative_modules, do: fn -> argument end
  def argument(_module, argument), do: argument

  def child_spec(spec), do: RuntimeDiagnostics.child_spec(spec)

  def format_status(status, module) do
    formatted = RuntimeDiagnostics.format_status(status, module)
    summary = Map.get(formatted, :state, %{component: module, payloads: :redacted})
    state = Map.get(status, :state)

    summary =
      Enum.reduce(@counts, summary, fn key, acc ->
        case count(state, key) do
          count when is_integer(count) -> Map.put(acc, key, count)
          _other -> acc
        end
      end)

    Map.put(formatted, :state, summary)
  end

  defp count(state, key) when is_map(state) do
    case Map.get(state, key) do
      values when is_map(values) -> map_size(values)
      _other -> nil
    end
  end

  defp count(_state, _key), do: nil

  # OTP's native failure ACK and the diagnostic process exception are distinct.
  # Keep the caller's exact typed startup result, actual parent and native
  # constructor wait while the process report uses one fixed failure reason.
  @spec fail_init(term()) :: no_return()
  def fail_init(reason),
    do: :proc_lib.init_fail({:error, reason}, {:exit, :client_init_failed})

  def initialize(callback) do
    result =
      try do
        callback.()
      catch
        :error, reason -> {:stop, {reason, __STACKTRACE__}}
        :exit, reason -> {:stop, reason}
        # Native GenServer init interprets a thrown term as its init return.
        :throw, result -> result
      end

    finish_initialize(result)
  end

  defp finish_initialize({:stop, reason}), do: fail_init(reason)
  defp finish_initialize({:ok, _state} = result), do: result

  defp finish_initialize({:ok, _state, timeout} = result)
       when (is_integer(timeout) and timeout >= 0) or timeout in [:infinity, :hibernate],
       do: result

  defp finish_initialize({:ok, _state, {:continue, _term}} = result), do: result
  defp finish_initialize({:error, _reason} = result), do: result
  defp finish_initialize(:ignore), do: :ignore
  defp finish_initialize(invalid), do: fail_init({:bad_return_value, invalid})
end
