defmodule Arbor.MCP.Compliance.RootsComplianceTest do
  @moduledoc """
  Tests for MCP roots functionality protocol compliance.

  These tests validate that roots functionality follows the MCP specification requirements
  for the roots/list request and notifications/roots/list_changed notification.
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule ComplianceHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "roots-compliance-server",
           version: "1.0.0"
         },
         capabilities: %{
           roots: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_roots(state) do
      # Return roots in spec-compliant format
      roots = [
        %{uri: "file:///test", name: "Test"},
        # name is optional per spec
        %{uri: "file:///another"}
      ]

      {:ok, roots, state}
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

  describe "Roots Request Protocol Compliance" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: ComplianceHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      Process.sleep(50)
      {:ok, %{client: client, server: server}}
    end

    test "roots request returns spec-compliant response", %{client: client} do
      # Make roots request through public API
      {:ok, response} = Client.list_roots(client)

      # Verify response contains roots array (may have atom keys)
      assert Map.has_key?(response, :roots) || Map.has_key?(response, "roots")
      roots = Map.get(response, :roots) || Map.get(response, "roots")
      assert is_list(roots)
      assert length(roots) == 2

      # Verify first root has required uri and optional name
      first_root = hd(roots)
      assert Map.get(first_root, :uri) == "file:///test"
      assert Map.get(first_root, :name) == "Test"

      # Verify second root has uri but no name (optional per spec)
      second_root = Enum.at(roots, 1)
      assert Map.get(second_root, :uri) == "file:///another"
      refute Map.has_key?(second_root, :name)
    end
  end

  describe "Roots Change Notification Compliance" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: ComplianceHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      Process.sleep(50)
      {:ok, %{client: client, server: server}}
    end

    test "roots change notification can be sent", %{server: server} do
      # Server can send roots changed notification
      assert :ok = Arbor.MCP.Server.notify_roots_changed(server)
    end
  end

  describe "Roots Data Format Compliance" do
    test "handler returns roots in MCP specification format" do
      {:ok, state} = ComplianceHandler.init([])
      {:ok, roots, _new_state} = ComplianceHandler.handle_list_roots(state)

      # Each root object must have:
      # - uri: string (required) - URI identifying the root
      # - name: string (optional) - Human-readable name for the root

      # All roots must have URI
      Enum.each(roots, fn root ->
        assert Map.has_key?(root, :uri)
        assert is_binary(root.uri)
      end)

      # Name is optional but if present must be string
      Enum.each(roots, fn root ->
        case Map.get(root, :name) do
          nil -> :ok
          name -> assert is_binary(name)
        end
      end)

      # Verify our test data follows the spec
      assert length(roots) == 2

      # First root has both uri and name
      first = hd(roots)
      assert first.uri == "file:///test"
      assert first.name == "Test"

      # Second root has only uri (name is optional)
      second = Enum.at(roots, 1)
      assert second.uri == "file:///another"
      refute Map.has_key?(second, :name)
    end
  end
end
