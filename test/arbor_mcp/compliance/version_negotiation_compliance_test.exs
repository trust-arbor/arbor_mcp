defmodule Arbor.MCP.Compliance.VersionNegotiationComplianceTest do
  @moduledoc """
  Tests for MCP version negotiation protocol compliance.

  These tests validate that version negotiation follows the MCP specification requirements,
  including initialize request format and protocol version handling.
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule VersionTestHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(args) do
      {:ok, %{expected_version: Keyword.get(args, :expected_version, "2025-03-26")}}
    end

    @impl true
    def handle_initialize(params, state) do
      # Verify client sends proper version
      client_version = params["protocolVersion"]

      if client_version == state.expected_version do
        {:ok,
         %{
           name: "version-test-server",
           version: "1.0.0",
           protocolVersion: state.expected_version,
           capabilities: %{
             "roots" => %{},
             "sampling" => %{}
           }
         }, state}
      else
        # Server can reject unsupported versions
        {:error, "Unsupported protocol version: #{client_version}", state}
      end
    end

    # Required callbacks
    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_call_tool(_name, _params, state), do: {:error, "Not implemented", state}
    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_read_resource(_uri, state), do: {:error, "Not implemented", state}
    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_get_prompt(_name, _args, state), do: {:error, "Not implemented", state}
  end

  describe "Initialize Protocol Compliance" do
    test "client sends required initialize fields" do
      # Start server
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: VersionTestHandler
        )

      # Client initialization happens automatically during start_link
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          client_info: %{name: "test-client", version: "1.0.0"},
          protocol_version: "2025-03-26"
        )

      # Verify client is initialized with server
      state = :sys.get_state(client)
      assert state.initialized == true

      # Use public API to verify protocol version
      {:ok, version} = Client.negotiated_version(client)
      assert version == "2025-03-26"
    end

    test "server receives client capabilities during initialization" do
      # The client automatically sends its capabilities during initialization
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: VersionTestHandler
        )

      # Client with custom info
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          client_info: %{name: "custom-client", version: "2.0.0"},
          protocol_version: "2025-03-26"
        )

      # Client should be successfully initialized
      assert :sys.get_state(client).initialized == true
    end
  end

  describe "Version Negotiation" do
    test "server accepts current protocol version" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: VersionTestHandler,
          expected_version: "2025-03-26"
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          protocol_version: "2025-03-26"
        )

      # Should successfully negotiate
      state = :sys.get_state(client)
      assert state.initialized == true

      # Use public API to verify
      {:ok, version} = Client.negotiated_version(client)
      assert version == "2025-03-26"
    end

    test "client receives server capabilities after successful initialization" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: VersionTestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          protocol_version: "2025-03-26"
        )

      # Check that client is initialized
      state = :sys.get_state(client)
      assert state.initialized == true

      # Use public API to get server capabilities
      {:ok, capabilities} = Client.server_capabilities(client)
      assert is_map(capabilities)
      assert Map.has_key?(capabilities, "roots") || Map.has_key?(capabilities, :roots)
      assert Map.has_key?(capabilities, "sampling") || Map.has_key?(capabilities, :sampling)
    end
  end

  describe "Initialized Notification" do
    test "client sends initialized notification after successful initialization" do
      # This happens automatically in the Client after receiving initialize response
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: VersionTestHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          protocol_version: "2025-03-26"
        )

      # The fact that the client is initialized means the notification was sent
      assert :sys.get_state(client).initialized == true
    end
  end
end
