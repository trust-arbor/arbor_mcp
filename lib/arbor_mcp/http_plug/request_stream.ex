defmodule Arbor.MCP.HttpPlug.RequestStream do
  @moduledoc false

  alias Arbor.MCP.HttpPlug.SSEConnection
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.RPC.JSONRPC

  @type process_result ::
          {:ok, map()}
          | {:http_error, pos_integer(), map()}
          | {:notification, term()}
          | {:error, term()}

  @spec serve(Plug.Conn.t(), Arbor.MCP.Types.request_id(), map(), (-> process_result())) ::
          Plug.Conn.t()
  def serve(conn, request_id, opts, process_fun) when is_function(process_fun, 0) do
    owner = self()
    {worker, worker_ref} = spawn_monitor(fn -> run_worker(owner, process_fun) end)
    watchdog = start_owner_watchdog(owner, worker)
    conn_module = SSEConnection.resolve(opts)

    try do
      stream(conn, conn_module, worker, worker_ref, request_id)
    after
      Process.demonitor(worker_ref, [:flush])
      stop_watchdog(watchdog)
      stop_worker(worker)
    end
  end

  defp run_worker(owner, process_fun) do
    send(owner, {:ex_mcp_request_stream_result, self(), process_fun.()})
  end

  defp stream(conn, conn_module, worker, worker_ref, request_id) do
    receive do
      {:ex_mcp_request_notification, sender, ref, notification} ->
        handle_notification(
          conn,
          conn_module,
          worker,
          worker_ref,
          request_id,
          sender,
          ref,
          notification
        )

      {:ex_mcp_request_stream_result, ^worker, result} ->
        write_final(conn, conn_module, final_response(result, request_id))

      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        write_final(conn, conn_module, worker_error(request_id, reason))
    end
  end

  defp handle_notification(
         conn,
         conn_module,
         worker,
         worker_ref,
         request_id,
         sender,
         ref,
         notification
       ) do
    case validate_notification(notification) do
      :ok ->
        case conn_module.chunk(conn, encode_message(notification)) do
          {:ok, conn} ->
            send(sender, {:ex_mcp_request_notification_ack, ref, :ok})
            stream(conn, conn_module, worker, worker_ref, request_id)

          {:error, reason} ->
            send(sender, {:ex_mcp_request_notification_ack, ref, {:error, reason}})
            emit_cancelled(reason)
            stop_worker(worker)
            conn
        end

      {:error, reason} ->
        send(sender, {:ex_mcp_request_notification_ack, ref, {:error, reason}})
        stop_worker(worker)
        write_final(conn, conn_module, worker_error(request_id, reason))
    end
  end

  defp validate_notification(
         %{"jsonrpc" => "2.0", "method" => method, "params" => params} = notification
       )
       when method in ["notifications/progress", "notifications/message"] and is_map(params) do
    if Map.has_key?(notification, "id"),
      do: {:error, :independent_request_on_response_stream},
      else: :ok
  end

  defp validate_notification(_notification), do: {:error, :invalid_request_stream_message}

  defp final_response({:ok, response}, _request_id) when is_map(response), do: response

  defp final_response({:http_error, _status, response}, _request_id) when is_map(response),
    do: response

  defp final_response({:error, reason}, request_id),
    do: worker_error(request_id, reason)

  defp final_response(_result, request_id),
    do: worker_error(request_id, :invalid_processor_result)

  defp worker_error(request_id, reason) do
    JSONRPC.error(
      request_id,
      ErrorCodes.internal_error(),
      "Internal error",
      %{"type" => "request_stream_failed", "reason" => reason_name(reason)}
    )
  end

  defp write_final(conn, conn_module, response) do
    case conn_module.chunk(conn, encode_message(response)) do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        emit_cancelled(reason)
        conn
    end
  end

  defp encode_message(message), do: ["data: ", Jason.encode!(message), "\r\n\r\n"]

  defp start_owner_watchdog(owner, worker) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> stop_worker(worker)
        {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
      end
    end)
  end

  defp stop_watchdog(watchdog) do
    Process.exit(watchdog, :shutdown)
    :ok
  end

  defp stop_worker(worker) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)
    :ok
  end

  defp emit_cancelled(reason) do
    :telemetry.execute(
      [:arbor_mcp, :server, :http, :stream, :cancelled],
      %{count: 1},
      %{reason: cancellation_reason(reason), stream: :request}
    )
  end

  defp cancellation_reason(reason) when is_atom(reason), do: reason
  defp cancellation_reason({reason, _detail}) when is_atom(reason), do: reason
  defp cancellation_reason(_reason), do: :connection_error

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(_reason), do: "request_processing_failed"
end
