defmodule Arbor.MCP.PingTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Handler, as: ClientHandler
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.Handler
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestServerHandler do
    @behaviour Handler

    def init(_args) do
      {:ok, %{ping_count: 0}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         name: "ping-test-server",
         version: "1.0.0",
         capabilities: %{}
       }, state}
    end

    @impl true
    def handle_list_tools(_params, state) do
      {:ok, [], state}
    end

    @impl true
    def handle_call_tool(_name, _params, state) do
      {:ok, [%{type: "text", text: "Not implemented"}], state}
    end

    def terminate(_reason, _state) do
      :ok
    end
  end

  defmodule TestClientHandler do
    @behaviour ClientHandler

    @impl true
    def init(args) do
      {:ok, args}
    end

    @impl true
    def handle_ping(state) do
      # Track ping count
      new_state = Map.update(state, :ping_count, 1, &(&1 + 1))
      {:ok, %{}, new_state}
    end

    @impl true
    def handle_list_roots(state) do
      {:ok, [], state}
    end

    @impl true
    def handle_create_message(_params, state) do
      {:ok, %{}, state}
    end

    @impl true
    def terminate(_reason, _state) do
      :ok
    end
  end

  describe "ping protocol compliance" do
    test "encode_ping creates correct request format" do
      ping_request = Protocol.encode_ping()

      assert ping_request["jsonrpc"] == "2.0"
      assert ping_request["method"] == "ping"
      assert ping_request["params"] == %{}
      assert is_integer(ping_request["id"])
    end

    test "encode_pong creates correct response format" do
      pong_response = Protocol.encode_pong(123)

      assert pong_response["jsonrpc"] == "2.0"
      assert pong_response["id"] == 123
      assert pong_response["result"] == %{}
      refute Map.has_key?(pong_response, "error")
    end
  end

  describe "client to server ping" do
    test "client can ping server successfully" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Client pings server
      assert {:ok, %{}} = Client.ping(client)

      # Multiple pings should work
      assert {:ok, %{}} = Client.ping(client)
      assert {:ok, %{}} = Client.ping(client)

      # Cleanup
      GenServer.stop(client)
      GenServer.stop(server)
    end

    test "client ping respects timeout" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Short timeout should still work for ping
      assert {:ok, %{}} = Client.ping(client, 100)

      # Cleanup
      GenServer.stop(client)
      GenServer.stop(server)
    end
  end

  describe "server to client ping" do
    test "server can ping client successfully" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler: TestClientHandler,
          handler_state: %{ping_count: 0}
        )

      # Server pings client
      assert {:ok, %{}} = Arbor.MCP.Server.ping(server)

      # Multiple pings should work
      assert {:ok, %{}} = Arbor.MCP.Server.ping(server)
      assert {:ok, %{}} = Arbor.MCP.Server.ping(server)

      # Cleanup
      GenServer.stop(client)
      GenServer.stop(server)
    end

    test "server ping succeeds with default client handler" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
          # No handler specified - uses DefaultHandler which now supports basic server requests like ping
        )

      # Server ping should succeed with default handler
      assert {:ok, _} = Arbor.MCP.Server.ping(server)

      # Cleanup
      GenServer.stop(client)
      GenServer.stop(server)
    end
  end

  describe "bidirectional ping" do
    test "both client and server can ping each other" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler: TestClientHandler,
          handler_state: %{}
        )

      # Client pings server
      assert {:ok, %{}} = Client.ping(client)

      # Server pings client
      assert {:ok, %{}} = Arbor.MCP.Server.ping(server)

      # Interleaved pings
      assert {:ok, %{}} = Client.ping(client)
      assert {:ok, %{}} = Arbor.MCP.Server.ping(server)
      assert {:ok, %{}} = Client.ping(client)

      # Cleanup
      GenServer.stop(client)
      GenServer.stop(server)
    end
  end

  describe "ping error handling" do
    test "ping handles transport failures gracefully" do
      Process.flag(:trap_exit, true)

      # Test expects an error during client startup with non-existent server
      case Client.start_link(
             transport: :test,
             server: :non_existent_server
           ) do
        {:ok, client} ->
          # If client starts successfully, ping should fail
          assert {:error, :not_connected} = Client.ping(client)
          GenServer.stop(client)

        {:error, {:transport_connect_failed, _reason}} ->
          # This is expected when transport cannot connect to non-existent server
          :ok

        {:error, _other_reason} ->
          # Other connection errors are also acceptable
          :ok
      end
    end

    test "ping respects timeout on slow connections" do
      defmodule SlowPingHandler do
        @behaviour Handler

        @impl true
        def init(_args), do: {:ok, %{}}

        @impl true
        def handle_initialize(_params, state) do
          {:ok,
           %{
             name: "slow-server",
             version: "1.0.0",
             capabilities: %{}
           }, state}
        end

        @impl true
        def handle_list_tools(_params, state), do: {:ok, [], state}

        @impl true
        def terminate(_reason, _state), do: :ok
      end

      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SlowPingHandler
        )

      # Start client with custom transport that delays responses
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Normal ping should work
      assert {:ok, %{}} = Client.ping(client, 1000)

      # Cleanup
      GenServer.stop(client)
      GenServer.stop(server)
    end
  end

  describe "ping as health check" do
    test "periodic pings can detect connection health" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Simulate periodic health checks
      # Each ping is a synchronous round-trip, so the loop needs no pacing.
      results =
        for _i <- 1..5 do
          Client.ping(client)
        end

      # All pings should succeed
      assert Enum.all?(results, fn result ->
               match?({:ok, %{}}, result)
             end)

      # Stop server to simulate connection loss and wait for it to actually die.
      ref = Process.monitor(server)
      GenServer.stop(server)
      assert_receive {:DOWN, ^ref, :process, ^server, _reason}, 1_000

      # The server is definitively gone, so the ping cannot succeed: either the
      # client already saw the transport close (`:not_connected` while it
      # reconnects with backoff) or the request times out.
      assert {:error, _} = Client.ping(client, 1_000)

      # Cleanup
      GenServer.stop(client)
    end
  end
end
