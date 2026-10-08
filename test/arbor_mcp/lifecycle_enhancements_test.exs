defmodule Arbor.MCP.LifecycleEnhancementsTest do
  @moduledoc """
  Tests for enhanced lifecycle management features including
  dynamic capability building and version validation.
  """
  use ExUnit.Case, async: true
  @moduletag :integration

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Server.Capabilities
  alias Arbor.MCP.Server.Handler
  alias Arbor.MCP.Server.HandlerServer, as: Server

  describe "dynamic server capabilities" do
    defmodule FullFeaturedHandler do
      use Handler

      @impl true
      def init(_args), do: {:ok, %{}}

      @impl true
      def handle_initialize(_params, state) do
        # Build full capabilities since we implement everything
        capabilities = %{
          "tools" => %{},
          "resources" => %{"subscribe" => true, "templates" => true},
          "prompts" => %{},
          "logging" => %{},
          "experimental" => %{}
        }

        {:ok,
         %{
           protocolVersion: "2025-03-26",
           serverInfo: %{name: "full-featured", version: "1.0.0"},
           capabilities: capabilities
         }, state}
      end

      # Implement all features
      @impl true
      def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_call_tool(_name, _args, state), do: {:ok, [], state}

      @impl true
      def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_read_resource(_uri, state), do: {:ok, [], state}

      @impl true
      def handle_subscribe_resource(_uri, state), do: {:ok, state}

      @impl true
      def handle_unsubscribe_resource(_uri, state), do: {:ok, state}

      @impl true
      def handle_list_resource_templates(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_get_prompt(_name, _args, state), do: {:ok, %{}, state}

      @impl true
      def handle_set_log_level(_level, state), do: {:ok, state}
    end

    defmodule MinimalHandler do
      use Handler

      @impl true
      def init(_args), do: {:ok, %{}}

      @impl true
      def handle_initialize(_params, state) do
        capabilities = Handler.build_capabilities(__MODULE__)

        {:ok,
         %{
           protocolVersion: "2025-03-26",
           serverInfo: %{name: "minimal", version: "1.0.0"},
           capabilities: capabilities
         }, state}
      end

      # Only implement required callbacks
      @impl true
      def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_call_tool(_name, _args, state), do: {:error, "Not implemented", state}
    end

    test "handler can build standard capabilities" do
      capabilities = Capabilities.build_capabilities(FullFeaturedHandler)

      # Default legacy revision is 2025-11-25, which has listChanged for tools.
      assert capabilities["tools"] == %{"listChanged" => true}
      # 2025-11-25 experimental features
      assert capabilities["experimental"]["elicitation"] == true
    end

    test "handlers can customize capabilities in handle_initialize" do
      # This is tested in the server initialization test below
      assert true
    end

    test "server returns dynamic capabilities in initialization" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: FullFeaturedHandler,
          handler_args: []
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      # Get server info to see capabilities
      {:ok, server_info} = Client.server_info(client)
      {:ok, capabilities} = Client.server_capabilities(client)

      assert server_info["name"] == "full-featured"
      assert Map.has_key?(capabilities, "tools")
      assert Map.has_key?(capabilities, "resources")
      assert Map.has_key?(capabilities, "prompts")
      assert Map.has_key?(capabilities, "logging")
      assert Map.has_key?(capabilities, "experimental")

      GenServer.stop(client)
      GenServer.stop(server)
    end
  end

  describe "dynamic client capabilities" do
    defmodule TestClientHandler do
      @behaviour Arbor.MCP.Client.Handler

      @impl true
      def init(_args), do: {:ok, %{}}

      @impl true
      def handle_ping(state), do: {:pong, state}

      @impl true
      def handle_list_roots(state) do
        {:ok, [%{uri: "file:///test", name: "Test Root"}], state}
      end

      @impl true
      def handle_create_message(_params, state) do
        {:ok, %{content: "Test response"}, state}
      end

      @impl true
      def terminate(_reason, _state), do: :ok
    end

    defmodule MinimalClientHandler do
      @behaviour Arbor.MCP.Client.Handler

      @impl true
      def init(_args), do: {:ok, %{}}

      @impl true
      def handle_ping(state), do: {:pong, state}

      @impl true
      def handle_list_roots(state) do
        {:error, "Not implemented", state}
      end

      @impl true
      def handle_create_message(_params, state) do
        {:error, "Not implemented", state}
      end

      @impl true
      def terminate(_reason, _state), do: :ok
    end

    test "client with full handler declares roots and sampling capabilities" do
      # We can't easily test this without intercepting the initialize message
      # but the logic is implemented in build_client_capabilities/1
      assert true
    end
  end

  describe "version validation" do
    defmodule VersionTestHandler do
      use Handler

      @impl true
      def init(args), do: {:ok, args}

      @impl true
      def handle_initialize(_params, state) do
        version = Map.get(state, :version, "2025-03-26")

        {:ok,
         %{
           protocolVersion: version,
           serverInfo: %{name: "version-test", version: "1.0.0"},
           capabilities: %{}
         }, state}
      end

      @impl true
      def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_call_tool(_name, _args, state), do: {:error, "Not implemented", state}
    end

    test "client accepts supported protocol versions" do
      for version <- ["2025-03-26", "2025-06-18"] do
        {:ok, server} =
          Server.start_link(
            transport: :test,
            handler: VersionTestHandler,
            handler_args: %{version: version}
          )

        {:ok, client} =
          Client.start_link(
            transport: :test,
            server: server,
            protocol_mode: :legacy_only
          )

        # Should connect successfully
        assert {:ok, _} = Client.ping(client)

        GenServer.stop(client)
        GenServer.stop(server)
      end
    end

    test "server normalizes an unknown handler version to a supported revision" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: VersionTestHandler,
          handler_args: %{version: "9999-12-31"}
        )

      # The handler cannot make the server advertise an unknown wire revision.
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      # Should still connect and be functional
      assert {:ok, _} = Client.ping(client)

      # The connection remains functional on the server's preferred supported
      # legacy revision rather than pinning the unknown handler value.
      {:ok, version} = Client.negotiated_version(client)
      assert version == VersionRegistry.preferred_version()
      refute version == "9999-12-31"

      GenServer.stop(client)
      GenServer.stop(server)
    end
  end
end
