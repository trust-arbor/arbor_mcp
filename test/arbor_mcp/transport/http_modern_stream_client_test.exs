defmodule Arbor.MCP.Transport.HTTP.ModernStreamClientTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.HTTP.ModernStreamClient

  @request_id 42

  test "ordinary request streams accept only related notifications and their final response" do
    assert :ok =
             validate(:request, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "job", "progress" => 1}
             })

    assert :ok =
             validate(:request, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/message",
               "params" => %{"level" => "info", "data" => "working"}
             })

    assert :ok = validate(:request, %{"jsonrpc" => "2.0", "id" => @request_id, "result" => %{}})

    assert :ok =
             validate(:request, %{
               "jsonrpc" => "2.0",
               "id" => @request_id,
               "error" => %{"code" => -32603, "message" => "failed"}
             })
  end

  test "ordinary request streams reject independent requests and cross-stream messages" do
    assert {:error, :invalid_stream_message} =
             validate(:request, %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "method" => "sampling/createMessage",
               "params" => %{}
             })

    assert {:error, :invalid_stream_message} =
             validate(:request, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/tools/list_changed",
               "params" => %{}
             })

    assert {:error, :response_id_mismatch} =
             validate(:request, %{"jsonrpc" => "2.0", "id" => 99, "result" => %{}})

    assert {:error, :invalid_stream_message} =
             validate(:request, %{
               "jsonrpc" => "2.0",
               "id" => @request_id,
               "result" => %{},
               "error" => %{}
             })
  end

  test "subscription streams reject request-scoped notifications" do
    assert :ok =
             validate(:subscription, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/subscriptions/acknowledged",
               "params" => %{}
             })

    assert :ok =
             validate(:subscription, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/resources/updated",
               "params" => %{"uri" => "file:///one"}
             })

    assert :ok =
             validate(:subscription, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/tasks",
               "params" => %{"taskId" => "task-1"}
             })

    assert {:error, :invalid_stream_message} =
             validate(:subscription, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "job", "progress" => 1}
             })
  end

  test "incomplete stream buffers enforce the configured byte limit" do
    assert {:ok, "abcd"} = ModernStreamClient.append_chunk("ab", "cd", 4)

    assert {:error, :stream_buffer_limit_exceeded} =
             ModernStreamClient.append_chunk("ab", "cde", 4)
  end

  test "non-streaming response bodies accept the exact limit and reject one byte over" do
    exact = Bypass.open()

    Bypass.expect_once(exact, "POST", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 500, "1234")
    end)

    assert {:ok, exact_pid} = start_stream(exact, max_response_bytes: 4)

    assert_receive {:modern_http_stream_closed, ^exact_pid, @request_id, {:http_error, 500}},
                   1_000

    over = Bypass.open()

    Bypass.expect_once(over, "POST", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 500, "12345")
    end)

    assert {:ok, over_pid} = start_stream(over, max_response_bytes: 4)

    assert_receive {:modern_http_stream_closed, ^over_pid, @request_id, :response_too_large},
                   1_000
  end

  test "a stalled consumer gets at most one complete SSE event before the stream closes" do
    bypass = Bypass.open()

    first = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"progressToken" => "job", "progress" => 1}
    }

    second = put_in(first, ["params", "progress"], 2)
    body = "data: #{Jason.encode!(first)}\n\ndata: #{Jason.encode!(second)}\n\n"

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, pid} = start_stream(bypass, consumer_ack_timeout: 30)
    # The HTTP handshake can take several seconds on loaded CI runners. Once
    # the first event is delivered, the much shorter consumer ACK deadline is
    # what this test is exercising.
    assert_receive {:modern_http_stream_message, ^pid, @request_id, ^first}, 5_000

    assert_receive {:modern_http_stream_closed, ^pid, @request_id, :stream_consumer_timeout},
                   500

    refute_receive {:modern_http_stream_message, ^pid, @request_id, ^second}, 100
  end

  defp validate(kind, message) do
    ModernStreamClient.validate_message(message, @request_id, kind)
  end

  defp start_stream(bypass, overrides) do
    defaults = [
      parent: self(),
      request_id: @request_id,
      stream_kind: :request,
      url: "http://127.0.0.1:#{bypass.port}/mcp",
      headers: [{"accept", "application/json, text/event-stream"}],
      body: "{}",
      http_options: [connect_timeout: 500],
      # Bypass can take longer to schedule while the integration suite is
      # running at full CI concurrency. Keep this comfortably above the
      # consumer-ack deadlines exercised by these tests.
      handshake_timeout: 5_000,
      idle_timeout: 1_000,
      max_response_bytes: 1_024,
      max_buffer_bytes: 1_024
    ]

    ModernStreamClient.start(Keyword.merge(defaults, overrides))
  end
end
