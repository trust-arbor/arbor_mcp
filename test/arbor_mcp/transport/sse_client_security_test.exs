defmodule Arbor.MCP.Transport.SSEClientSecurityTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.SSEClient

  test "incomplete event buffers accept the limit and reject one byte over" do
    assert {:ok, "1234"} = SSEClient.append_chunk("12", "34", 4)

    assert {:error, :stream_buffer_limit_exceeded} =
             SSEClient.append_chunk("12", "345", 4)
  end

  test "a stream that never returns headers is stopped by the handshake deadline" do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    holder =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        receive do
          :stop -> :ok
        end

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      send(holder, :stop)
      :gen_tcp.close(listener)
    end)

    assert {:ok, pid} =
             SSEClient.start_link(
               url: "http://127.0.0.1:#{port}/mcp",
               parent: parent,
               connect_timeout: 100,
               handshake_timeout: 30,
               idle_timeout: 1_000
             )

    assert_receive {:sse_error, ^pid, :stream_handshake_timeout}, 500
    stop_sse_safely(pid)
  end

  test "non-streaming error bodies accept the exact limit and reject one byte over" do
    exact = Bypass.open()
    Bypass.stub(exact, "GET", "/mcp", &Plug.Conn.resp(&1, 500, "1234"))

    assert {:ok, exact_pid} =
             start_sse(exact,
               max_response_bytes: 4,
               initial_retry_delay: 1_000,
               max_retry_delay: 1_000
             )

    assert_receive {:sse_error, ^exact_pid, {:http_error, 500}}, 1_000
    SSEClient.stop(exact_pid)

    over = Bypass.open()
    Bypass.stub(over, "GET", "/mcp", &Plug.Conn.resp(&1, 500, "12345"))

    assert {:ok, over_pid} = start_sse(over, max_response_bytes: 4)
    assert_receive {:sse_error, ^over_pid, :response_too_large}, 1_000
  end

  test "a stalled event consumer receives only one event before fail-closed shutdown" do
    bypass = Bypass.open()
    body = "data: first\n\ndata: second\n\n"

    Bypass.expect_once(bypass, "GET", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, pid} = start_sse(bypass, consumer_ack_timeout: 30)

    # Match the configured handshake allowance so loaded CI runners do not
    # fail before the consumer ACK behavior under test begins.
    assert_receive {:sse_connected, ^pid}, 5_000
    assert_receive {:sse_event, ^pid, %{data: "first"}}, 1_000
    assert_receive {:sse_error, ^pid, :stream_consumer_timeout}, 500
    refute_receive {:sse_event, ^pid, %{data: "second"}}, 100
  end

  test "an empty priming event applies retry and id without blocking reconnection" do
    bypass = Bypass.open()
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:sse_get, attempt, System.monotonic_time(:millisecond), conn.req_headers})

      body =
        if attempt == 1,
          do: "id: event-1\nretry: 100\ndata: \n\n",
          else: "data: {\"type\":\"keep-alive\"}\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, pid} =
             start_sse(bypass,
               initial_retry_delay: 1_000,
               max_retry_delay: 1_000,
               consumer_ack_timeout: 30
             )

    assert_receive {:sse_get, 1, first_at, _headers}, 1_000
    refute_receive {:sse_event, ^pid, %{data: ""}}, 100
    assert_receive {:sse_get, 2, second_at, headers}, 1_000
    assert second_at - first_at >= 100
    assert {"last-event-id", "event-1"} in headers

    stop_sse_safely(pid)
  end

  defp stop_sse_safely(pid) do
    SSEClient.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp start_sse(bypass, overrides) do
    defaults = [
      url: "http://127.0.0.1:#{bypass.port}/mcp",
      parent: self(),
      connect_timeout: 500,
      # Bypass can take longer to schedule while the unit suite is running at
      # full CI concurrency. Deadline behavior is covered above with an
      # explicit 30 ms override.
      handshake_timeout: 5_000,
      idle_timeout: 1_000,
      max_response_bytes: 1_024,
      max_buffer_bytes: 1_024
    ]

    SSEClient.start_link(Keyword.merge(defaults, overrides))
  end
end
