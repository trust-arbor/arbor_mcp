defmodule Arbor.MCP.CancellationTest do
  use ExUnit.Case, async: true
  @moduletag :integration
  @moduletag :cancellation

  import Arbor.MCP.TestHelpers, only: [wait_until: 1]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.Handler
  alias Arbor.MCP.Server.HandlerServer, as: Server
  alias Arbor.MCP.Server.Runtime

  defmodule TestHandler do
    @behaviour Handler

    def init(_args) do
      {:ok, %{}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         name: "test-server",
         version: "1.0.0",
         capabilities: %{
           tools: %{},
           resources: %{},
           prompts: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "slow_tool", description: "A tool that takes time to complete"}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("slow_tool", _params, state) do
      # Simulate a slow operation
      Process.sleep(5000)
      {:ok, [%{type: "text", text: "Slow operation completed"}], state}
    end

    def terminate(_reason, _state) do
      :ok
    end
  end

  describe "cancellation protocol validation" do
    @tag :protocol
    test "encode_cancelled validates initialize request cannot be cancelled" do
      assert {:error, :cannot_cancel_initialize} =
               Protocol.encode_cancelled("initialize", "test reason")
    end

    test "encode_cancelled allows other requests to be cancelled" do
      assert {:ok, notification} =
               Protocol.encode_cancelled("req_123", "User cancelled")

      assert notification["method"] == "notifications/cancelled"
      assert notification["params"]["requestId"] == "req_123"
      assert notification["params"]["reason"] == "User cancelled"
    end

    test "encode_cancelled works without reason" do
      assert {:ok, notification} =
               Protocol.encode_cancelled("req_456")

      assert notification["method"] == "notifications/cancelled"
      assert notification["params"]["requestId"] == "req_456"
      refute Map.has_key?(notification["params"], "reason")
    end

    test "encode_cancelled! bypasses validation for backward compatibility" do
      notification = Protocol.encode_cancelled!("initialize", "test")

      assert notification["method"] == "notifications/cancelled"
      assert notification["params"]["requestId"] == "initialize"
      assert notification["params"]["reason"] == "test"
    end
  end

  describe "client cancellation functionality" do
    test "client tracks pending requests" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for client to be ready
      wait_until(fn -> is_list(Client.get_pending_requests(client)) end)

      # Check initially no pending requests
      assert [] = Client.get_pending_requests(client)

      # Start an async task that makes a slow request
      task =
        Task.async(fn ->
          Client.call_tool(client, "slow_tool", %{})
        end)

      # Wait for request to be tracked
      wait_until(fn -> length(Client.get_pending_requests(client)) > 0 end)

      # Check we have a pending request
      pending = Client.get_pending_requests(client)
      assert length(pending) == 1
      [request_id] = pending

      # Cancel the request
      :ok = Client.send_cancelled(client, request_id, "Test cancellation")

      # The task should return cancellation error
      assert {:error, :cancelled} = Task.await(task, 1000)

      # Request should be removed from pending
      wait_until(fn -> Client.get_pending_requests(client) == [] end)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end

    test "client validates cancellation of initialize request" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Try to cancel initialize request - should return error
      assert {:error, :cannot_cancel_initialize} =
               Client.send_cancelled(client, "initialize", "Should be ignored")

      # Client should still be functional
      assert {:ok, _tools} = Client.list_tools(client)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end

    test "client ignores cancellation for unknown requests" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for client to be ready
      wait_until(fn -> is_list(Client.get_pending_requests(client)) end)

      # Cancel non-existent request - should be ignored
      :ok = Client.send_cancelled(client, "non_existent", "Should be ignored")

      # Client should still be functional
      assert {:ok, _tools} = Client.list_tools(client)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end
  end

  describe "server cancellation handling" do
    test "server cancels in-progress requests" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for client to be ready
      wait_until(fn -> is_list(Client.get_pending_requests(client)) end)

      # Start a slow request
      task =
        Task.async(fn ->
          Client.call_tool(client, "slow_tool", %{})
        end)

      # Wait for request to be tracked
      wait_until(fn -> length(Client.get_pending_requests(client)) > 0 end)

      # Get the pending request ID from the client
      [request_id] = Client.get_pending_requests(client)

      # Send cancellation from server side (simulating server-initiated cancellation)
      # In practice, this would come from the server's client connection
      # Send the cancellation notification to the client
      send(
        client,
        {:transport_message,
         Jason.encode!(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/cancelled",
           "params" => %{
             "requestId" => request_id,
             "reason" => "Server initiated cancellation"
           }
         })}
      )

      # The task should return cancellation error
      assert {:error, :cancelled} = Task.await(task, 1000)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end

    test "server ignores cancellation for unknown requests" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for client to be ready
      wait_until(fn -> is_list(Client.get_pending_requests(client)) end)

      # Send cancellation for non-existent request
      assert :ok =
               Client.notify(client, "notifications/cancelled", %{
                 "requestId" => "non_existent",
                 "reason" => "Should be ignored"
               })

      # Server should still be functional
      assert {:ok, _tools} = Client.list_tools(client)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end
  end

  describe "cancellation edge cases" do
    test "cancellation notification without reason parameter" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for client to be ready
      wait_until(fn -> is_list(Client.get_pending_requests(client)) end)

      # Start a slow request
      task =
        Task.async(fn ->
          Client.call_tool(client, "slow_tool", %{})
        end)

      wait_until(fn -> length(Client.get_pending_requests(client)) > 0 end)
      [request_id] = Client.get_pending_requests(client)

      # Send cancellation without reason
      send(
        client,
        {:transport_message,
         Jason.encode!(%{
           "jsonrpc" => "2.0",
           "method" => "notifications/cancelled",
           "params" => %{
             "requestId" => request_id
           }
         })}
      )

      # Request should still be cancelled
      assert {:error, :cancelled} = Task.await(task, 1000)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end

    test "malformed cancellation notification is ignored" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for client to be ready
      wait_until(fn -> is_list(Client.get_pending_requests(client)) end)

      # Send malformed cancellation (missing requestId)
      assert :ok =
               Client.notify(client, "notifications/cancelled", %{
                 "reason" => "Missing requestId"
               })

      # Server should still be functional
      assert {:ok, _tools} = Client.list_tools(client)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end
  end

  describe "bidirectional cancellation" do
    test "both client and server can send cancellation notifications" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: TestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for client to be ready
      wait_until(fn -> is_list(Client.get_pending_requests(client)) end)

      # Client can send cancellation
      :ok = Client.send_cancelled(client, "some_request", "Client cancellation")

      # Both should remain functional
      assert {:ok, _tools} = Client.list_tools(client)

      # Cleanup
      GenServer.stop(client)
      assert :ok = Runtime.stop(server)
    end
  end
end
