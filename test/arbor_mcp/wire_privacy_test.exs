defmodule Arbor.MCP.WirePrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Client.RequestHandler
  alias Arbor.MCP.HttpPlug.SSEHandler
  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Protocol.RequestTracker
  alias Arbor.MCP.Server.{HandlerServer, Runtime, StdioServer}
  alias Arbor.MCP.Test.StdioRuntimeFixture.{Device, Handler}

  defmodule FailingNotificationHandler do
    def handle_log_message(_request_id, _params, state),
      do: {:error, state.secret, state}
  end

  defmodule RaisingNotificationHandler do
    def handle_log_message(_request_id, _params, state), do: raise(state.secret)
  end

  defmodule CaptureConn do
    @behaviour Arbor.MCP.HttpPlug.SSEConnection

    defstruct [:test_pid]

    @impl true
    def chunk(%__MODULE__{test_pid: test_pid} = conn, data) do
      send(test_pid, {:sse_chunk, data})
      {:ok, conn}
    end

    @impl true
    def get_req_header(_conn, _header), do: []
  end

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test "peer-controlled IDs and malformed frames are summarized in logs" do
    secret = "wire-log-secret-#{System.unique_integer([:positive])}"
    input = start_supervised!({Device, [owner: self()]}, id: make_ref())
    output = start_supervised!({Device, [owner: self()]}, id: make_ref())

    log =
      capture_log([level: :debug], fn ->
        notification = %{"jsonrpc" => "2.0", "method" => secret, "params" => secret}
        _conn = MessageProcessor.process(MessageProcessor.new(notification), %{})

        state = RequestTracker.cancel_request(secret, RequestTracker.init())
        assert {:noreply, _state} = RequestTracker.handle_cancellation(secret, state)

        assert {:noreply, _state} =
                 HandlerServer.handle_info({:cancelled, secret}, %{pending_requests: %{}})

        {:ok, root} =
          StdioServer.start_link(
            module: Handler,
            handler_args: [test_pid: self()],
            stdio_input: input,
            stdio_output: output,
            stdio_startup_delay: 0
          )

        Process.unlink(root)
        on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)

        valid = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "inc", "arguments" => %{}}
        }

        :ok =
          GenServer.call(input, {:input, secret <> "\n" <> Jason.encode!(valid) <> "\n", false})

        assert_receive {:invoked, 1}, 1_000
        assert_receive {:written, frame}, 1_000
        assert %{"id" => 1, "result" => %{}} = Jason.decode!(String.trim(frame))
        assert :ok = Runtime.stop(root)

        assert {:noreply, _state} = SSEHandler.handle_info({:unexpected, secret}, %SSEHandler{})
      end)

    refute log =~ secret
    assert log =~ "Request not found in pending requests"
  end

  test "client notification handler errors and exception messages stay out of logs" do
    secret = "handler-log-secret-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        error_state = %Arbor.MCP.Client{
          client_handler: {FailingNotificationHandler, %{secret: secret}}
        }

        assert {:noreply, _state} =
                 RequestHandler.handle_request_stream_message(
                   secret,
                   %{"method" => "notifications/message", "params" => %{"secret" => secret}},
                   error_state
                 )

        raising_state = %Arbor.MCP.Client{
          client_handler: {RaisingNotificationHandler, %{secret: secret}}
        }

        assert {:noreply, _state} =
                 RequestHandler.handle_request_stream_message(
                   secret,
                   %{"method" => "notifications/message", "params" => %{"secret" => secret}},
                   raising_state
                 )
      end)

    refute log =~ secret
    assert log =~ "Client request notification handler failed"
    assert log =~ "Client request notification handler raised"
  end

  test "arbitrary SSE error terms are replaced before reaching the peer" do
    secret = "sse-peer-secret-#{System.unique_integer([:positive])}"

    {:ok, handler} =
      SSEHandler.start_link(%CaptureConn{test_pid: self()}, "session", %{conn_module: CaptureConn})

    assert_receive {:sse_chunk, _connected}
    ref = Process.monitor(handler)
    SSEHandler.send_error(handler, {:transport_error, secret})

    assert_receive {:sse_chunk, error_chunk}
    assert error_chunk =~ "transport_error: internal error"
    refute error_chunk =~ secret
    assert_receive {:DOWN, ^ref, :process, ^handler, _reason}
  end
end
