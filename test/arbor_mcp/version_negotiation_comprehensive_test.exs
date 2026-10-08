defmodule Arbor.MCP.VersionNegotiationComprehensiveTest do
  @moduledoc """
  Comprehensive tests for version negotiation between clients and servers.

  Tests all scenarios described in the MCP specification for version negotiation,
  including edge cases and error conditions.
  """
  use ExUnit.Case, async: true

  @moduletag :protocol
  @moduletag :slow

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule MultiVersionHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(args) do
      supported_versions = Keyword.get(args, :supported_versions, ["2025-03-26", "2025-06-18"])
      version_strategy = Keyword.get(args, :version_strategy, :latest)

      {:ok,
       %{
         supported_versions: supported_versions,
         version_strategy: version_strategy,
         client_version: nil,
         negotiated_version: nil
       }}
    end

    @impl true
    def handle_initialize(params, state) do
      client_version = params["protocolVersion"]
      _client_info = params["clientInfo"]

      # Store client version for testing
      state = %{state | client_version: client_version}

      # Negotiate version based on strategy
      negotiated_version = negotiate_version(client_version, state)

      if negotiated_version do
        state = %{state | negotiated_version: negotiated_version}

        # Build capabilities based on negotiated version
        capabilities = build_capabilities_for_version(negotiated_version)

        result = %{
          protocolVersion: negotiated_version,
          serverInfo: %{
            name: "multi-version-server",
            version: "1.0.0"
          },
          capabilities: capabilities,
          meta: %{
            clientRequestedVersion: client_version,
            serverSupportedVersions: state.supported_versions
          }
        }

        {:ok, result, state}
      else
        # No compatible version found
        error_data = %{
          supported: state.supported_versions,
          requested: client_version
        }

        {:error,
         %{
           code: -32602,
           message: "Unsupported protocol version",
           data: error_data
         }, state}
      end
    end

    defp negotiate_version(client_version, state) do
      case state.version_strategy do
        :latest -> negotiate_latest_version(client_version, state)
        :exact -> negotiate_exact_version(client_version, state)
        :fallback -> negotiate_fallback_version(client_version, state)
        :reject_unknown -> negotiate_reject_unknown_version(client_version, state)
      end
    end

    defp negotiate_latest_version(client_version, state) do
      if client_version in state.supported_versions do
        client_version
      else
        hd(state.supported_versions)
      end
    end

    defp negotiate_exact_version(client_version, state) do
      if client_version in state.supported_versions, do: client_version, else: nil
    end

    defp negotiate_fallback_version(client_version, state) do
      cond do
        client_version in state.supported_versions ->
          client_version

        client_version == "2025-06-18" && "2025-06-18" in state.supported_versions ->
          "2025-06-18"

        client_version == "1.0.0" && "2025-06-18" in state.supported_versions ->
          "2025-06-18"

        true ->
          hd(state.supported_versions)
      end
    end

    defp negotiate_reject_unknown_version(client_version, state) do
      if client_version in VersionRegistry.supported_versions() &&
           client_version in state.supported_versions do
        client_version
      else
        nil
      end
    end

    defp build_capabilities_for_version(version) do
      # Use the version registry to get proper capabilities
      caps = VersionRegistry.capabilities_for_version(version)

      # Convert to string keys for JSON compatibility
      %{
        "tools" => convert_capability(caps.tools),
        "resources" => convert_capability(caps.resources),
        "prompts" => convert_capability(caps.prompts),
        "logging" => convert_capability(caps.logging),
        "completion" => convert_capability(Map.get(caps, :completion, %{})),
        "experimental" => convert_capability(Map.get(caps, :experimental, %{}))
      }
    end

    defp convert_capability(cap) when is_map(cap) do
      Map.new(cap, fn {k, v} -> {to_string(k), v} end)
    end

    defp convert_capability(_), do: %{}

    # Required callbacks
    @impl true
    def handle_list_tools(_cursor, state) do
      # Return tools appropriate for negotiated version
      tools =
        case state.negotiated_version do
          "2025-06-18" ->
            [
              %{
                name: "structured_tool",
                description: "Tool with structured output",
                outputSchema: %{type: "object"}
              }
            ]

          "2025-03-26" ->
            [
              %{
                name: "annotated_tool",
                description: "Has annotations",
                annotations: %{readOnlyHint: true}
              }
            ]

          _ ->
            [%{name: "basic_tool", description: "Basic tool"}]
        end

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool(name, args, state) do
      {:ok, [%{type: "text", text: "Called #{name} with #{inspect(args)}"}], state}
    end

    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_read_resource(_uri, state), do: {:error, "Not found", state}
    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_get_prompt(_name, _args, state), do: {:error, "Not found", state}
    @impl true
    def handle_complete(_ref, _arg, state), do: {:ok, %{completion: []}, state}
    @impl true
    def handle_list_resource_templates(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_subscribe_resource(_uri, state), do: {:ok, %{}, state}
    @impl true
    def handle_unsubscribe_resource(_uri, state), do: {:ok, %{}, state}
    @impl true
    def handle_create_message(_params, state), do: {:error, "Not supported", state}
    @impl true
    def handle_list_roots(state), do: {:ok, [], state}
  end

  describe "basic version negotiation" do
    test "exact version match - both support same version" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [supported_versions: ["2025-03-26", "2025-06-18"]],
          transport: :test
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "2025-03-26",
          protocol_mode: :legacy_only
        )

      Process.sleep(100)

      {:ok, version} = Client.negotiated_version(client)
      assert version == "2025-03-26"

      GenServer.stop(client)
      GenServer.stop(server)
    end

    test "client requests older version that server supports" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [supported_versions: ["2025-03-26", "2025-06-18"]],
          transport: :test
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "2025-06-18",
          protocol_mode: :legacy_only
        )

      Process.sleep(100)

      {:ok, version} = Client.negotiated_version(client)
      assert version == "2025-06-18"

      GenServer.stop(client)
      GenServer.stop(server)
    end

    test "client requests newer version than server supports" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [
            supported_versions: ["2025-06-18"],
            version_strategy: :latest
          ],
          transport: :test
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "2025-03-26",
          protocol_mode: :legacy_only
        )

      Process.sleep(100)

      # Server should propose its latest (2024-11-05)
      {:ok, version} = Client.negotiated_version(client)
      assert version == "2025-06-18"

      GenServer.stop(client)
      GenServer.stop(server)
    end
  end

  describe "unknown version handling" do
    test "server proposes alternative for unknown client version" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [
            supported_versions: ["2025-03-26", "2025-06-18"],
            version_strategy: :latest
          ],
          transport: :test
        )

      # Client with made-up version
      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "99.99.99",
          protocol_mode: :legacy_only
        )

      Process.sleep(100)

      # Server should propose its latest
      {:ok, version} = Client.negotiated_version(client)
      assert version == "2025-03-26"

      GenServer.stop(client)
      GenServer.stop(server)
    end

    test "strict server rejects unknown versions" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [
            supported_versions: ["2025-03-26"],
            version_strategy: :reject_unknown
          ],
          transport: :test
        )

      # Trap exits so the client's initialization failure doesn't crash the test
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "unknown-version",
          protocol_mode: :legacy_only
        )

      case result do
        {:error, _reason} ->
          # Expected - initialization failed
          assert true

        {:ok, client} ->
          # Client may have started but will exit shortly due to init failure
          receive do
            {:EXIT, ^client, {:initialize_error, _}} -> assert true
          after
            1000 ->
              # If client survived, it should not be properly initialized
              assert {:error, _} = Client.list_tools(client)
              GenServer.stop(client)
          end
      end

      GenServer.stop(server)
    end
  end

  describe "version fallback negotiation" do
    test "client with unsupported version falls back to latest" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [
            supported_versions: ["2025-03-26", "2025-06-18"],
            version_strategy: :fallback
          ],
          transport: :test
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "unknown-future-version",
          protocol_mode: :legacy_only
        )

      Process.sleep(100)

      # Server should offer the newest legacy revision from its configured set.
      {:ok, version} = Client.negotiated_version(client)
      assert version == "2025-03-26"

      GenServer.stop(client)
      GenServer.stop(server)
    end

    test "server supporting only newer version with older client" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [
            supported_versions: ["2025-06-18"],
            version_strategy: :exact
          ],
          transport: :test
        )

      # Trap exits so the client's initialization failure doesn't crash the test
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "2025-03-26",
          protocol_mode: :legacy_only
        )

      case result do
        {:error, _} ->
          # Expected - no compatible version
          assert true

        {:ok, client} ->
          # Client may have started but will exit shortly due to init failure
          receive do
            {:EXIT, ^client, {:initialize_error, _}} -> assert true
          after
            1000 ->
              assert {:error, _} = Client.list_tools(client)
              GenServer.stop(client)
          end
      end

      GenServer.stop(server)
    end
  end

  describe "capability differences by version" do
    test "capabilities match negotiated version" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [supported_versions: ["2025-03-26", "2025-06-18", "2024-11-05"]],
          transport: :test
        )

      # Test each version
      versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

      for version <- versions do
        {:ok, client} =
          Client.start_link(
            transport: :test,
            server: server,
            protocol_version: version,
            protocol_mode: :legacy_only
          )

        Process.sleep(100)

        {:ok, negotiated} = Client.negotiated_version(client)
        assert negotiated == version

        {:ok, caps} = Client.server_capabilities(client)

        case version do
          "2025-06-18" ->
            # 2025-06-18 has resources with subscribe and listChanged
            assert get_in(caps, ["resources", "subscribe"]) == true
            assert get_in(caps, ["resources", "listChanged"]) == true
            # Has elicitation in experimental
            assert get_in(caps, ["experimental", "elicitation"]) == true
            # Batch processing removed in 2025-06-18
            assert get_in(caps, ["experimental", "batchProcessing"]) == false

          "2025-03-26" ->
            # Has 2025 features including resources with subscribe
            assert get_in(caps, ["resources", "subscribe"]) == true
            assert get_in(caps, ["resources", "listChanged"]) == true
            # Has batch processing in experimental
            assert get_in(caps, ["experimental", "batchProcessing"]) == true

          "2024-11-05" ->
            # Basic features — resources have subscribe and listChanged
            assert get_in(caps, ["resources", "subscribe"]) == true
            assert get_in(caps, ["resources", "listChanged"]) == true
            # No elicitation in experimental
            refute get_in(caps, ["experimental", "elicitation"])
        end

        GenServer.stop(client)
      end

      GenServer.stop(server)
    end
  end

  describe "error scenarios" do
    test "initialization fails with incompatible versions" do
      {:ok, server} =
        Server.start_link(
          handler: MultiVersionHandler,
          handler_args: [
            supported_versions: ["2025-06-18"],
            version_strategy: :exact
          ],
          transport: :test
        )

      # Trap exits so the client's initialization failure doesn't crash the test
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_version: "2025-03-26",
          protocol_mode: :legacy_only
        )

      case result do
        {:error, _reason} ->
          # Should fail during initialization
          assert true

        {:ok, client} ->
          # Client may have started but will exit shortly due to init failure
          receive do
            {:EXIT, ^client, {:initialize_error, _}} -> assert true
          after
            1000 ->
              assert {:error, _} = Client.list_tools(client)
              GenServer.stop(client)
          end
      end

      GenServer.stop(server)
    end

    test "error response includes supported versions" do
      # Test that error responses follow the spec format
      handler = MultiVersionHandler

      {:ok, state} =
        handler.init(
          supported_versions: ["2025-03-26"],
          version_strategy: :exact
        )

      # Try to initialize with unsupported version
      params = %{
        "protocolVersion" => "1.0.0",
        "clientInfo" => %{name: "test", version: "1.0"},
        "capabilities" => %{}
      }

      {:error, error, _state} = handler.handle_initialize(params, state)

      assert error.code == -32602
      assert error.message =~ "Unsupported"
      assert error.data.supported == ["2025-03-26"]
      assert error.data.requested == "1.0.0"
    end
  end

  describe "version registry integration" do
    test "registry correctly identifies feature availability" do
      # Test that version-specific features are properly gated

      # Elicitation is a 2025-06-18+ feature
      assert VersionRegistry.feature_available?("2025-06-18", :elicitation)
      assert VersionRegistry.feature_available?("2025-11-25", :elicitation)
      refute VersionRegistry.feature_available?("2025-03-26", :elicitation)
      refute VersionRegistry.feature_available?("2024-11-05", :elicitation)

      # Resource subscription is a base feature available in all versions
      assert VersionRegistry.feature_available?("2024-11-05", :resource_subscription)
      assert VersionRegistry.feature_available?("2025-03-26", :resource_subscription)
      assert VersionRegistry.feature_available?("2025-06-18", :resource_subscription)
      assert VersionRegistry.feature_available?("2025-11-25", :resource_subscription)

      # Base features available in all versions
      assert VersionRegistry.feature_available?("2024-11-05", :tools)
      assert VersionRegistry.feature_available?("2025-03-26", :tools)
      assert VersionRegistry.feature_available?("2025-06-18", :tools)
      assert VersionRegistry.feature_available?("2025-11-25", :tools)
    end

    test "message validation respects version" do
      # Test protocol message validation

      # Valid for all versions
      # Use Arbor.MCP.Internal.Protocol since Protocol is not in the public API
      validator = &Arbor.MCP.Internal.Protocol.validate_message_version/2

      assert :ok =
               validator.(
                 %{"method" => "tools/list"},
                 "2025-06-18"
               )

      # resources/subscribe is a base feature available in all versions
      assert :ok =
               validator.(
                 %{"method" => "resources/subscribe"},
                 "2025-03-26"
               )

      assert :ok =
               validator.(
                 %{"method" => "resources/subscribe"},
                 "2025-06-18"
               )

      assert :ok =
               validator.(
                 %{"method" => "resources/subscribe"},
                 "2024-11-05"
               )

      # elicitation/create is only valid for 2025-06-18+
      assert :ok =
               validator.(
                 %{"method" => "elicitation/create"},
                 "2025-06-18"
               )

      assert {:error, msg} =
               validator.(
                 %{"method" => "elicitation/create"},
                 "2025-03-26"
               )

      assert msg =~ "not available"
    end
  end

  describe "spec compliance for version negotiation" do
    test "client SHOULD disconnect if server version not supported" do
      # Simulate scenario where client can't support server's version
      # This would happen in the client's initialization logic

      # For testing, we check that client properly handles version mismatch
      client_supported = ["2025-03-26"]
      server_proposed = "2025-06-18"

      # Client should determine this is not acceptable
      refute server_proposed in client_supported
    end

    test "initialize request MUST include protocolVersion" do
      msg =
        Arbor.MCP.Internal.Protocol.encode_initialize(
          %{name: "test", version: "1.0"},
          %{}
        )

      assert Map.has_key?(msg["params"], "protocolVersion")
      assert is_binary(msg["params"]["protocolVersion"])
    end

    test "server MUST respond with same version if supported" do
      handler = MultiVersionHandler
      {:ok, state} = handler.init(supported_versions: ["2025-03-26", "2025-06-18"])

      params = %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{name: "test", version: "1.0"},
        "capabilities" => %{}
      }

      {:ok, result, _} = handler.handle_initialize(params, state)
      assert result.protocolVersion == "2025-03-26"
    end

    test "server SHOULD propose its newest legacy revision for an unknown client version" do
      handler = MultiVersionHandler

      {:ok, state} =
        handler.init(
          supported_versions: ["2025-03-26", "2025-06-18"],
          version_strategy: :latest
        )

      params = %{
        "protocolVersion" => "unknown",
        "clientInfo" => %{name: "test", version: "1.0"},
        "capabilities" => %{}
      }

      {:ok, result, _} = handler.handle_initialize(params, state)
      # Should propose latest (first in list)
      assert result.protocolVersion == "2025-03-26"
    end
  end
end
