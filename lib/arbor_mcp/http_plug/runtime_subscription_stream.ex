defmodule Arbor.MCP.HttpPlug.RuntimeSubscriptionStream do
  @moduledoc false

  alias Arbor.MCP.HttpPlug.RuntimeWriter
  alias Arbor.MCP.Server.Runtime.{Deadline, HTTPListenerBinding, HTTPWriterRegistry, OutputCodec}
  alias Arbor.MCP.Server.SubscriptionListener
  alias Arbor.MCP.Server.Subscriptions.Origin

  def serve(conn, binding, listener, registration, opts) do
    monitor = Process.monitor(listener)
    keepalive = Map.fetch!(opts, :subscription_keepalive_interval_ms)

    context = %{
      binding: binding,
      listener: listener,
      registration: registration,
      monitor: monitor,
      keepalive: keepalive,
      next_keepalive: next_keepalive(keepalive)
    }

    try do
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
        |> RuntimeWriter.send_chunked(200)

      stream(conn, context)
    after
      Process.demonitor(monitor, [:flush])
      SubscriptionListener.cancel_http(listener, binding, registration)
    end
  end

  defp stream(conn, context) do
    case HTTPWriterRegistry.listener_wait_deadline(context.binding, RuntimeWriter.runtime(conn)) do
      {:ok, deadline} -> receive_delivery(conn, context, min(50, Deadline.remaining(deadline)))
      _closed -> conn
    end
  end

  defp receive_delivery(conn, context, wait) do
    receive do
      {:ex_mcp_subscription_ready, listener, id, cutoff} when listener == context.listener ->
        case write_delivery(conn, context, id, cutoff) do
          {:ok, conn, :complete} -> conn
          {:ok, conn, _kind} -> stream(conn, context)
          _closed -> conn
        end

      {:DOWN, monitor, :process, listener, _reason}
      when monitor == context.monitor and listener == context.listener ->
        conn
    after
      wait -> keepalive(conn, context)
    end
  end

  defp write_delivery(conn, context, id, cutoff) do
    listener = context.listener
    binding = context.binding

    case SubscriptionListener.checkout_http(listener, id, binding, cutoff) do
      {:ok, kind, message, origin} ->
        deadline = Origin.deadline(origin, cutoff)

        try do
          with true <- Origin.valid?(origin),
               {:ok, effect} <- prepare_delivery(conn, binding, kind, message, origin, deadline),
               :ok <- HTTPWriterRegistry.publish(effect),
               {:ok, _ticket, wire} <- HTTPWriterRegistry.peek(RuntimeWriter.binding(conn)) do
            case RuntimeWriter.perform_if_ready(conn, effect, wire, &Plug.Conn.chunk/2) do
              {:ok, conn} -> {:ok, conn, kind}
              {:error, :http_io_not_entered} -> stale_source(conn, context, origin)
              _failed -> {:error, :subscription_closed}
            end
          else
            _closed -> stale_source(conn, context, origin)
          end
        after
          # This synchronous path acknowledges only after actual IO returned,
          # or after a failure before IO entry. A blocked borrowed write keeps
          # both the checked-out listener loan and root IO liability charged.
          SubscriptionListener.delivered_http(listener, id, binding)
        end

      {:error, :source_retired} ->
        continue_target(conn, context)

      _closed ->
        {:error, :subscription_closed}
    end
  end

  defp stale_source(conn, context, origin) do
    if Origin.valid?(origin),
      do: {:error, :subscription_closed},
      else: continue_target(conn, context)
  end

  defp continue_target(conn, context) do
    case HTTPListenerBinding.validate(context.binding, RuntimeWriter.runtime(conn)) do
      {:ok, _proof} -> {:ok, conn, :discarded}
      _closed -> {:error, :subscription_closed}
    end
  end

  defp prepare_delivery(_conn, _binding, :complete, _message, origin, _deadline),
    do: HTTPWriterRegistry.prepare_listener_completion(Origin.completion(origin))

  defp prepare_delivery(conn, binding, _kind, message, origin, deadline) do
    with {:ok, %{wire: json}} <-
           OutputCodec.prepare(message, codec: :protocol, deadline: deadline) do
      HTTPWriterRegistry.prepare(RuntimeWriter.binding(conn), "data: " <> json <> "\r\n\r\n",
        deadline: deadline,
        metadata: %{subscription_origin: origin, listener: binding}
      )
    end
  end

  defp keepalive(conn, %{keepalive: :infinity} = context), do: stream(conn, context)

  defp keepalive(conn, context) do
    if Deadline.now() >= context.next_keepalive and
         match?(
           {:ok, _},
           HTTPListenerBinding.validate(context.binding, RuntimeWriter.runtime(conn))
         ) do
      case RuntimeWriter.chunk(conn, ":\r\n\r\n") do
        {:ok, conn} ->
          stream(conn, %{context | next_keepalive: next_keepalive(context.keepalive)})

        _closed ->
          conn
      end
    else
      stream(conn, context)
    end
  end

  defp next_keepalive(:infinity), do: :infinity
  defp next_keepalive(interval), do: Deadline.now() + interval
end
