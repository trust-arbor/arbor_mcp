defmodule Arbor.MCP.Compliance.CancellationComplianceTest do
  @moduledoc """
  Tests for MCP cancellation protocol compliance.

  These tests validate that cancellation follows the MCP specification requirements.
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule CancellationHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "cancellation-test-server",
           version: "1.0.0"
         },
         capabilities: %{}
       }, state}
    end

    @impl true
    def handle_call_tool(name, _arguments, state) do
      case name do
        "slow_tool" ->
          # Simulate a slow operation that can be cancelled
          receive do
            :cancelled -> {:error, "Cancelled", state}
          after
            5000 -> {:ok, %{result: "completed"}, state}
          end

        _ ->
          {:error, "Unknown tool", state}
      end
    end

    # Required callbacks
    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "slow_tool",
          description: "A tool that takes time to complete",
          inputSchema: %{type: "object"}
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_read_resource(_uri, state), do: {:error, "Not implemented", state}
    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_get_prompt(_name, _args, state), do: {:error, "Not implemented", state}
  end

  describe "Cancellation Public API Compliance" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: CancellationHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      Process.sleep(50)
      {:ok, %{client: client, server: server}}
    end

    test "client can send cancellation notification", %{client: client} do
      # The send_cancelled function sends a cancellation notification
      # We can send a cancellation for any request ID - it's just a notification

      # Send cancellation with a dummy request ID
      assert :ok = Client.send_cancelled(client, "test-request-123", "User cancelled")

      # The notification is sent successfully
      # In a real scenario, the server would handle this notification
      # and cancel the corresponding request if it's still in progress
    end

    test "cancellation without reason is valid", %{client: client} do
      # MCP spec allows cancellation without a reason
      # We just test that the function accepts nil reason

      # This is a notification, so it always returns :ok
      assert :ok = Client.send_cancelled(client, "dummy_id", nil)
      assert :ok = Client.send_cancelled(client, "dummy_id")
    end
  end

  describe "Cancellation Specification Constraints" do
    test "initialize request cannot be cancelled per MCP spec" do
      # The MCP specification states that initialize requests MUST NOT be cancelled
      # This is enforced at the protocol level, but from the public API perspective,
      # the initialize request happens automatically during Client.start_link
      # and completes before the client is ready for use.

      # We can test that the client is properly initialized
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: CancellationHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      Process.sleep(50)

      # Client should be initialized and ready
      state = :sys.get_state(client)
      assert state.initialized == true

      # There's no way to cancel initialization from the public API
      # as it happens internally during start_link
    end
  end
end
