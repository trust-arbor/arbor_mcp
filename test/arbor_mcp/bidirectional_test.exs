defmodule Arbor.MCP.BidirectionalTest do
  use ExUnit.Case
  @moduletag :integration

  import Arbor.MCP.TestHelpers, only: [wait_until: 1]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(args) do
      {:ok, args}
    end

    @impl true
    def handle_ping(state) do
      {:ok, %{}, state}
    end

    @impl true
    def handle_list_roots(state) do
      roots = [
        %{"uri" => "file:///home/test", "name" => "Test Home"},
        %{"uri" => "file:///projects", "name" => "Projects"}
      ]

      {:ok, roots, state}
    end

    @impl true
    def handle_create_message(params, state) do
      # Simulate user approval and LLM response
      messages = params["messages"] || []

      result = %{
        "role" => "assistant",
        "content" => %{
          "type" => "text",
          "text" => "This is a simulated response to: #{inspect(messages)}"
        },
        "model" => "test-model"
      }

      {:ok, result, state}
    end
  end

  defmodule TestServerHandler do
    @behaviour Arbor.MCP.Server.Handler

    def init(_args) do
      {:ok, %{}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok, %{capabilities: %{}}, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_call_tool(_name, _arguments, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_list_resources(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_read_resource(_uri, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_list_prompts(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_get_prompt(_name, _arguments, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_complete(_ref, _argument, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_create_message(_params, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_list_roots(state) do
      {:ok, [], state}
    end

    @impl true
    def handle_list_resource_templates(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_subscribe_resource(_uri, state) do
      {:ok, %{}, state}
    end

    @impl true
    def handle_unsubscribe_resource(_uri, state) do
      {:ok, %{}, state}
    end

    def terminate(_reason, _state) do
      :ok
    end
  end

  describe "server to client requests" do
    test "server can ping client" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler,
          handler_state: %{}
        )

      # Start client with handler
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler: TestClientHandler,
          handler_state: %{},
          client_info: %{name: "test_client", version: "1.0"}
        )

      # Wait for client to be ready
      wait_until(fn -> Process.alive?(client) end)

      # Server pings client
      assert {:ok, %{}} = Arbor.MCP.Server.ping(server)

      # Clean up
      :ok = GenServer.stop(client)
      :ok = GenServer.stop(server)
    end

    test "server can list client roots" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler,
          handler_state: %{}
        )

      # Start client with handler
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler: TestClientHandler,
          handler_state: %{},
          client_info: %{name: "test_client", version: "1.0"}
        )

      # Wait for client to be ready
      wait_until(fn -> Process.alive?(client) end)

      # Server requests client's roots
      assert {:ok, %{"roots" => roots}} = Arbor.MCP.Server.list_roots(server)
      assert length(roots) == 2

      assert [
               %{"uri" => "file:///home/test", "name" => "Test Home"},
               %{"uri" => "file:///projects", "name" => "Projects"}
             ] = roots

      # Clean up
      :ok = GenServer.stop(client)
      :ok = GenServer.stop(server)
    end

    test "server can request client to create message" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler,
          handler_state: %{}
        )

      # Start client with handler
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          handler: TestClientHandler,
          handler_state: %{},
          client_info: %{name: "test_client", version: "1.0"}
        )

      # Wait for client to be ready
      wait_until(fn -> Process.alive?(client) end)

      # Server requests client to sample LLM
      params = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
        ],
        "temperature" => 0.7
      }

      assert {:ok, result} = Arbor.MCP.Server.create_message(server, params)
      assert result["role"] == "assistant"
      assert result["content"]["type"] == "text"
      assert result["model"] == "test-model"

      # Clean up
      :ok = GenServer.stop(client)
      :ok = GenServer.stop(server)
    end

    test "client without handler still responds to ping" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestServerHandler,
          handler_state: %{}
        )

      # Start client WITHOUT handler
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          client_info: %{name: "test_client", version: "1.0"}
        )

      # Wait for client to be ready
      wait_until(fn -> Process.alive?(client) end)

      # Ping is a protocol-level operation - always succeeds even without handler
      assert {:ok, %{}} = Arbor.MCP.Server.ping(server)

      # Clean up
      :ok = GenServer.stop(client)
      :ok = GenServer.stop(server)
    end
  end
end
