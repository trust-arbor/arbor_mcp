defmodule Arbor.MCP.BatchIntegrationTest do
  use ExUnit.Case
  @moduletag :integration
  @moduletag :batch

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestHandler do
    @behaviour Arbor.MCP.Server.Handler

    def init(_args) do
      {:ok, %{}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok, %{protocolVersion: "2025-03-26", capabilities: %{}}, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [%{name: "test_tool", description: "A test tool"}], nil, state}
    end

    @impl true
    def handle_call_tool(name, _arguments, state) do
      {:ok, %{result: "Called #{name}"}, state}
    end

    @impl true
    def handle_list_resources(_cursor, state) do
      {:ok, [%{uri: "test://resource", name: "Test Resource"}], nil, state}
    end

    @impl true
    def handle_read_resource(uri, state) do
      {:ok, %{"uri" => uri, "text" => "Contents of #{uri}"}, state}
    end

    @impl true
    def handle_list_prompts(_cursor, state) do
      {:ok, %{prompts: []}, nil, state}
    end

    @impl true
    def handle_get_prompt(_name, _arguments, state) do
      {:error, "Prompt not found", state}
    end

    @impl true
    def handle_complete(_ref, _argument, state) do
      {:ok, %{completion: %{values: ["test"]}}, state}
    end

    @impl true
    def handle_create_message(_params, state) do
      {:ok, %{success: true}, state}
    end

    @impl true
    def handle_list_roots(state) do
      {:ok, %{roots: []}, state}
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

  describe "batch requests" do
    test "client can send batch requests and receive batch responses" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler,
          handler_state: %{}
        )

      # Start client
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          client_info: %{name: "test_client", version: "1.0"}
        )

      # Wait for initialization to complete
      Process.sleep(100)

      # Send batch request
      batch_requests = [
        {"tools/list", %{}},
        {"tools/call", %{"name" => "test_tool", "arguments" => %{}}},
        {"resources/list", %{}},
        {"resources/read", %{"uri" => "test://resource"}}
      ]

      # Make batch request
      assert {:ok, results} = Client.batch_request(client, batch_requests, 5000)

      # Verify results
      assert length(results) == 4
      assert [tools_result, call_result, resources_result, read_result] = results

      assert {:ok, %{"tools" => [%{"name" => "test_tool", "description" => "A test tool"}]}} =
               tools_result

      assert {:ok, %{"content" => _}} = call_result

      assert {:ok, %{"resources" => [%{"uri" => "test://resource", "name" => "Test Resource"}]}} =
               resources_result

      assert {:ok, %{"contents" => [%{"text" => "Contents of test://resource"}]}} =
               read_result

      # Clean up
      :ok = GenServer.stop(client)
      :ok = GenServer.stop(server)
    end

    test "handles mixed success and error responses in batch" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler,
          handler_state: %{}
        )

      # Start client
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          client_info: %{name: "test_client", version: "1.0"}
        )

      # Wait for initialization to complete
      Process.sleep(100)

      # Send batch request with some that will fail
      batch_requests = [
        {"tools/list", %{}},
        # This will fail
        {"prompts/get", %{"name" => "nonexistent", "arguments" => %{}}},
        {"resources/list", %{}}
      ]

      # Make batch request
      assert {:ok, results} = Client.batch_request(client, batch_requests, 5000)

      # Verify results
      assert length(results) == 3
      assert [tools_result, prompt_result, resources_result] = results

      assert {:ok, %{"tools" => _}} = tools_result
      assert {:error, %{"code" => _, "message" => _}} = prompt_result
      assert {:ok, %{"resources" => _}} = resources_result

      # Clean up
      :ok = GenServer.stop(client)
      :ok = GenServer.stop(server)
    end
  end
end
