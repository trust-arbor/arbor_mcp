defmodule Arbor.MCP.Testing.MockTransportTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{ConnectionManager, Deadline}
  alias Arbor.MCP.Testing.{MockServer, MockTransport}

  test "all explicit mock configurations retain the mock server protocol" do
    server = start_supervised!({MockServer, []})

    for transport <- [
          :mock,
          {:mock, [server_pid: server]},
          [type: :mock, server_pid: server]
        ] do
      assert {:ok, [transports: [{MockTransport, opts}]]} =
               ConnectionManager.prepare_transport_config(
                 transport: transport,
                 server_pid: server
               )

      assert opts[:server_pid] == server
      refute Keyword.has_key?(opts, :server)
    end
  end

  test "clients share a mock server without receiver tasks or stale replies on reconnect" do
    server = start_supervised!({MockServer, tools: [MockServer.sample_tool()]})
    handler_id = "mock-reconnect-#{System.unique_integer([:positive])}"
    event = [:arbor_mcp, :client, :reconnect, :success]

    :telemetry.attach(
      handler_id,
      event,
      fn _event, _measurements, metadata, test_pid ->
        send(test_pid, {:reconnected, metadata.pid})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    client1 =
      start_supervised!(
        {Client,
         transport: [type: :mock, server_pid: server],
         reconnect_backoff: [initial: 5, max: 5, multiplier: 1]},
        id: :first_client
      )

    client2 =
      start_supervised!(
        {Client,
         transport: {:mock, [server_pid: server]},
         reconnect_backoff: [initial: 5, max: 5, multiplier: 1]},
        id: :second_client
      )

    for client <- [client1, client2] do
      assert {:ok, result} = Client.list_tools(client, format: :map)
      assert [%{"name" => "sample_tool"}] = result["tools"]
      assert %{transport_mod: MockTransport, receiver_task: nil} = :sys.get_state(client)
      send(client, {:transport_closed, :connection_lost})
      assert_receive {:reconnected, ^client}, 1000
      assert {:ok, result} = Client.list_tools(client, format: :map)
      assert [%{"name" => "sample_tool"}] = result["tools"]
      assert {:messages, []} = Process.info(client, :messages)
      assert :ok = Client.disconnect(client)
    end

    assert MockServer.get_call_count(server)["tools/list"] == 4
  end

  test "protocol error replies remain protocol errors and notifications queue no response" do
    server = start_supervised!({MockServer, []})
    assert {:ok, transport} = MockTransport.connect(server_pid: server)

    assert {:ok, ^transport, encoded} =
             MockTransport.send_message(request("missing", 7), transport)

    assert %{"id" => 7, "error" => %{"code" => -32601}} = Jason.decode!(encoded)

    assert {:ok, ^transport} =
             MockTransport.send_message(
               Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
               transport
             )

    refute_receive {:transport_message, _}
  end

  test "legacy receive helpers preserve unrelated mailbox messages" do
    server = start_supervised!({MockServer, []})
    assert {:ok, transport} = MockTransport.connect(server_pid: server)
    assert {:ok, transport} = MockTransport.send(transport, request("tools/list", 9))

    send(self(), {:unrelated, :keep})
    assert {:ok, encoded, transport} = MockTransport.recv(transport, 0)
    assert %{"id" => 9, "result" => %{"tools" => []}} = Jason.decode!(encoded)
    assert_receive {:unrelated, :keep}
    assert {:error, :no_response} = MockTransport.receive(transport)
  end

  test "mock timeout and peer death remain bounded transport failures" do
    server = start_supervised!({MockServer, latency: 200})
    assert {:ok, transport} = MockTransport.connect(server_pid: server, timeout: 20)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} = MockTransport.send_message(request("tools/list", 1), transport)
    assert System.monotonic_time(:millisecond) - started < 150

    GenServer.stop(server)
    refute MockTransport.connected?(transport)
    assert {:error, :closed} = MockTransport.send_message(request("tools/list", 2), transport)

    assert {:error, {:invalid_mock_timeout, :infinity}} =
             MockTransport.connect(server_pid: self(), timeout: :infinity)
  end

  test "absolute caller deadlines shorten exchanges and expired requests never reach the server" do
    server = start_supervised!({MockServer, latency: 200})
    assert {:ok, transport} = MockTransport.connect(server_pid: server, timeout: 1000)
    expired = Deadline.put_on_transport(MockTransport, transport, Deadline.after_ms(-1))

    assert {:error, :timeout} = MockTransport.send_message(request("tools/list", 1), expired)
    assert MockServer.get_call_count(server) == %{}

    short = Deadline.put_on_transport(MockTransport, transport, Deadline.after_ms(20))
    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = MockTransport.send_message(request("tools/list", 2), short)
    assert System.monotonic_time(:millisecond) - started < 150
  end

  test "test transport does not fall back to a plain mock server" do
    server = start_supervised!({MockServer, []})

    assert {:error, {:connection_error, :server_not_available}} =
             Arbor.MCP.Transport.Test.connect(server: server)
  end

  defp request(method, id),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "id" => id})
end
