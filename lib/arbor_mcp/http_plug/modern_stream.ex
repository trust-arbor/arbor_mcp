defmodule Arbor.MCP.HttpPlug.ModernStream do
  @moduledoc false

  alias Arbor.MCP.HttpPlug.SSEConnection
  alias Arbor.MCP.Server.Subscriptions

  @keepalive_message :ex_mcp_modern_stream_keepalive

  @spec serve(term(), Arbor.MCP.Server.Subscriptions.Entry.t(), map(), keyword()) :: term()
  def serve(conn, entry, opts, subscription_options) do
    conn_module = SSEConnection.resolve(opts)
    listener_ref = Process.monitor(entry.listener_pid)
    keepalive_interval = Map.fetch!(opts, :subscription_keepalive_interval_ms)
    timer = schedule_keepalive(keepalive_interval, entry.listener_pid)

    try do
      {conn, timer} =
        stream(conn, conn_module, entry.listener_pid, listener_ref, keepalive_interval, timer)

      cancel_timer(timer)
      conn
    after
      Process.demonitor(listener_ref, [:flush])
      cancel_subscription(entry.subscription_id, subscription_options)
    end
  end

  defp stream(conn, conn_module, listener, listener_ref, keepalive_interval, timer) do
    receive do
      {:ex_mcp_subscription_message, ^listener, kind, message} ->
        case conn_module.chunk(conn, encode_message(message)) do
          {:ok, conn} ->
            Subscriptions.delivered(listener)

            if kind == :complete do
              {conn, timer}
            else
              stream(conn, conn_module, listener, listener_ref, keepalive_interval, timer)
            end

          {:error, reason} ->
            emit_cancelled(reason)
            {conn, timer}
        end

      {@keepalive_message, ^listener} ->
        case conn_module.chunk(conn, ":\r\n\r\n") do
          {:ok, conn} ->
            timer = schedule_keepalive(keepalive_interval, listener)
            stream(conn, conn_module, listener, listener_ref, keepalive_interval, timer)

          {:error, reason} ->
            emit_cancelled(reason)
            {conn, nil}
        end

      {:DOWN, ^listener_ref, :process, ^listener, _reason} ->
        {conn, timer}
    end
  end

  defp encode_message(message), do: ["data: ", Jason.encode!(message), "\r\n\r\n"]

  defp schedule_keepalive(:infinity, _listener), do: nil

  defp schedule_keepalive(interval, listener) do
    Process.send_after(self(), {@keepalive_message, listener}, interval)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer, async: false, info: false)
    :ok
  end

  defp emit_cancelled(reason) do
    :telemetry.execute(
      [:arbor_mcp, :server, :http, :stream, :cancelled],
      %{count: 1},
      %{reason: cancellation_reason(reason)}
    )
  end

  defp cancel_subscription(subscription_id, subscription_options) do
    Subscriptions.cancel(self(), subscription_id, subscription_options)
  catch
    :exit, _reason -> :ok
  end

  defp cancellation_reason(reason) when is_atom(reason), do: reason
  defp cancellation_reason({reason, _detail}) when is_atom(reason), do: reason
  defp cancellation_reason(_reason), do: :connection_error
end
