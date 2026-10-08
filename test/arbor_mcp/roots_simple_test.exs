defmodule Arbor.MCP.RootsSimpleTest do
  use ExUnit.Case, async: true

  @moduletag :roots

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.DefaultHandler
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule SimpleServerHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "simple-roots-server",
           version: "1.0.0"
         },
         capabilities: %{
           tools: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_call_tool(_name, _arguments, state) do
      {:error, "No tools", state}
    end
  end

  defmodule TestClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts) do
      roots = Keyword.get(opts, :roots, [])
      {:ok, %{roots: roots}}
    end

    @impl true
    def handle_ping(state) do
      {:ok, %{}, state}
    end

    @impl true
    def handle_list_roots(state) do
      {:ok, state.roots, state}
    end

    @impl true
    def handle_create_message(_params, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def terminate(_reason, _state) do
      :ok
    end
  end

  describe "roots basic functionality" do
    test "client handler can provide roots" do
      # Test the handler directly
      roots = [
        %{uri: "file:///workspace/project", name: "Project"},
        %{uri: "file:///home/user", name: "Home"}
      ]

      {:ok, handler_state} = TestClientHandler.init(roots: roots)
      {:ok, returned_roots, _new_state} = TestClientHandler.handle_list_roots(handler_state)

      assert returned_roots == roots
      assert length(returned_roots) == 2
      assert Enum.at(returned_roots, 0).uri == "file:///workspace/project"
      assert Enum.at(returned_roots, 0).name == "Project"
    end

    test "client with no roots returns empty list" do
      {:ok, handler_state} = TestClientHandler.init([])
      {:ok, returned_roots, _new_state} = TestClientHandler.handle_list_roots(handler_state)

      assert returned_roots == []
    end

    test "server can use list_roots API" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SimpleServerHandler
        )

      # Start client with roots
      roots = [%{uri: "file:///test", name: "Test"}]

      {:ok, _client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler: TestClientHandler,
          handler_state: [roots: roots]
        )

      # Wait for connection
      Process.sleep(100)

      # Server can request roots (this tests the protocol flow)
      case Arbor.MCP.Server.list_roots(server, 1000) do
        {:ok, result} ->
          received_roots = result["roots"]
          assert length(received_roots) == 1
          assert hd(received_roots)["uri"] == "file:///test"
          assert hd(received_roots)["name"] == "Test"

        {:error, reason} ->
          flunk("Expected success but got error: #{inspect(reason)}")
      end
    end

    test "default handler provides current directory as root" do
      # Test the default handler
      {:ok, state} = DefaultHandler.init([])
      {:ok, roots, _} = DefaultHandler.handle_list_roots(state)

      assert length(roots) == 1
      root = hd(roots)

      assert root.name == "Current Directory"
      assert String.starts_with?(root.uri, "file://")
      assert String.contains?(root.uri, File.cwd!())
    end

    test "multiple servers can request roots from same client" do
      # Start two servers
      {:ok, server1} =
        Server.start_link(
          transport: :test,
          handler: SimpleServerHandler
        )

      {:ok, server2} =
        Server.start_link(
          transport: :test,
          handler: SimpleServerHandler
        )

      # Start client with roots
      roots = [%{uri: "file:///shared", name: "Shared"}]

      {:ok, _client1} =
        Client.start_link(
          transport: :test,
          server: server1,
          handler: TestClientHandler,
          handler_state: [roots: roots]
        )

      {:ok, _client2} =
        Client.start_link(
          transport: :test,
          server: server2,
          handler: TestClientHandler,
          handler_state: [roots: roots]
        )

      Process.sleep(100)

      # Both servers can request roots
      {:ok, result1} = Arbor.MCP.Server.list_roots(server1, 1000)
      {:ok, result2} = Arbor.MCP.Server.list_roots(server2, 1000)

      assert result1["roots"] == result2["roots"]
      assert length(result1["roots"]) == 1
      assert hd(result1["roots"])["name"] == "Shared"
    end
  end
end
