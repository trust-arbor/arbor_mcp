defmodule Arbor.MCP.Compliance.CrossVersionCompatibilityTest do
  @moduledoc """
  Tests cross-version compatibility for the Model Context Protocol.

  This suite validates that the server correctly handles clients with different
  protocol versions, enforcing version-specific capabilities and behaviors
  as outlined in the MCP specifications. It focuses on identified gaps:

  1.  **Version Negotiation**: Ensures the server correctly accepts or rejects
      clients based on the requested protocol version.
  2.  **Batch Processing**: Verifies that batch requests are only allowed in
      protocol versions that support them (e.g., rejected in 2025-06-18).
  3.  **Capability Enforcement**: Confirms that features are correctly gated
      by the negotiated protocol version (e.g., `resources/subscribe`).
  """
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.HandlerServer, as: Server

  # A test handler that simulates a server supporting only one specific
  # protocol version. This allows testing how the system behaves when
  # a client requests a version that the server may or may not support.
  defmodule MultiVersionHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(args) do
      supported_version = Keyword.get(args, :supported_version, "2025-06-18")
      {:ok, %{supported_version: supported_version}}
    end

    @impl true
    def handle_initialize(params, state) do
      client_version = params["protocolVersion"]

      if client_version == state.supported_version do
        capabilities =
          case state.supported_version do
            "2025-06-18" ->
              %{
                "tools" => %{"outputSchema" => true},
                "resources" => %{"subscribe" => true},
                "experimental" => %{"structuredOutput" => true}
              }

            "2025-03-26" ->
              %{
                "resources" => %{"subscribe" => true},
                "completion" => %{"values" => true},
                "experimental" => %{"batchProcessing" => true}
              }

            "2024-11-05" ->
              %{
                "experimental" => %{"batchProcessing" => true}
              }
          end

        result = %{
          "protocolVersion" => state.supported_version,
          "serverInfo" => %{
            "name" => "multi-version-test-server",
            "version" => "1.0.0"
          },
          "capabilities" => capabilities
        }

        {:ok, result, state}
      else
        {:error, "Unsupported protocol version: #{client_version}", state}
      end
    end

    @impl true
    def handle_subscribe_resource(_uri, state) do
      if state.supported_version in ["2025-06-18", "2025-03-26"] do
        {:ok, %{}, state}
      else
        {:error, "Method not supported in version #{state.supported_version}", state}
      end
    end

    @impl true
    def handle_complete(_ref, _arg, state) do
      if state.supported_version in ["2025-06-18", "2025-03-26"] do
        {:ok, %{"completion" => ["test completion"]}, state}
      else
        {:error, "Method not supported in version #{state.supported_version}", state}
      end
    end

    # Required callbacks
    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_call_tool(_name, _params, state), do: {:ok, [%{type: "text", text: "ok"}], state}
    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_read_resource(uri, state),
      do: {:ok, %{uri: uri, mimeType: "text/plain", text: "ok"}, state}

    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}
    @impl true
    def handle_get_prompt(_name, _args, state), do: {:ok, %{messages: []}, state}
    @impl true
    def handle_unsubscribe_resource(_uri, state), do: {:ok, %{}, state}
    @impl true
    def handle_set_log_level(_level, state), do: {:ok, state}
  end

  defp setup_connection(version) do
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: MultiVersionHandler,
        handler_args: [supported_version: version]
      )

    # Allow server to start its message loop
    Process.sleep(10)

    # The client must be configured to request the specific version for the test.
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        protocol_version: version
      )

    Process.sleep(50)
    {:ok, %{client: client, server: server}}
  end

  describe "1. Version Negotiation Edge Cases" do
    test "initialization fails if client requests a version the server does not support" do
      # Server only supports an older version
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: MultiVersionHandler,
          handler_args: [supported_version: "2024-11-05"]
        )

      # Allow server to start its message loop
      Process.sleep(10)

      # Client requests a newer version, which should be rejected
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          protocol_version: "2025-06-18"
        )

      case result do
        {:error, %{reason: "initialize_failed"}} ->
          # This is the expected format if GenServer returns error properly
          :ok

        {:error, {:initialize_error, %{"code" => code}}} when code in [-32600, -32000] ->
          # This is the new format - initialization error with JSON-RPC error code
          :ok

        {:ok, pid} ->
          # If the client starts successfully, wait for a potential delayed exit
          receive do
            {:EXIT, ^pid, %{reason: "initialize_failed"}} ->
              # This is also acceptable - initialization failed after start
              :ok

            {:EXIT, ^pid, reason} ->
              # Some other exit reason
              assert %{reason: "initialize_failed"} == reason,
                     "Expected initialize_failed but got: #{inspect(reason)}"
          after
            1000 ->
              flunk("Expected client initialization to fail but it succeeded and didn't exit")
          end

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "initialization fails for malformed or unknown version strings" do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: MultiVersionHandler
        )

      # Allow server to start its message loop
      Process.sleep(10)

      # Client requests an invalid version, which should be rejected
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          protocol_version: "not-a-real-version"
        )

      case result do
        {:error, %{reason: "initialize_failed"}} ->
          # This is the expected format if GenServer returns error properly
          :ok

        {:error, {:initialize_error, %{"code" => code}}} when code in [-32600, -32000] ->
          # This is the new format - initialization error with JSON-RPC error code
          :ok

        {:ok, pid} ->
          # If the client starts successfully, wait for a potential delayed exit
          receive do
            {:EXIT, ^pid, %{reason: "initialize_failed"}} ->
              # This is also acceptable - initialization failed after start
              :ok

            {:EXIT, ^pid, reason} ->
              # Some other exit reason
              assert %{reason: "initialize_failed"} == reason,
                     "Expected initialize_failed but got: #{inspect(reason)}"
          after
            1000 ->
              flunk("Expected client initialization to fail but it succeeded and didn't exit")
          end

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "2. Batch Processing Cross-Version Validation" do
    test "server rejects batch requests with 2025-06-18 (no batch support)" do
      {:ok, %{client: client}} = setup_connection("2025-06-18")

      batch = [
        Protocol.encode_list_tools(),
        Protocol.encode_list_resources()
      ]

      # Per the 2025-06-18 spec, batch requests are not supported.
      # The server should return a single error response for the entire batch.
      # Note: This test will fail if the MessageValidator does not correctly
      # check the protocol version before processing a batch.
      case Client.batch_request(client, batch) do
        {:error, %Arbor.MCP.Error.ProtocolError{code: -32600} = error} ->
          # Invalid Request - error is an Arbor.MCP.Error struct
          assert error.message =~ "Batch requests are not supported"

        {:error, %{"code" => -32600, "message" => message}} ->
          # Invalid Request - error is a plain map
          assert message =~ "Batch requests are not supported in protocol version 2025-06-18"

        {:ok, _responses} ->
          flunk("Server incorrectly accepted a batch request for protocol version 2025-06-18.")
      end
    end

    test "server accepts batch requests with 2025-03-26 (batch support)" do
      {:ok, %{client: client}} = setup_connection("2025-03-26")

      batch = [
        Protocol.encode_list_tools(),
        Protocol.encode_list_resources()
      ]

      {:ok, responses} = Client.batch_request(client, batch)
      assert length(responses) == 2
      assert {:ok, tools_result} = hd(responses)
      assert Map.has_key?(tools_result, "tools")
      assert {:ok, resources_result} = Enum.at(responses, 1)
      assert Map.has_key?(resources_result, "resources")
    end

    test "server accepts batch requests with 2024-11-05 (batch support)" do
      {:ok, %{client: client}} = setup_connection("2024-11-05")

      batch = [
        Protocol.encode_list_tools(),
        Protocol.encode_list_resources()
      ]

      {:ok, responses} = Client.batch_request(client, batch)
      assert length(responses) == 2
      assert {:ok, tools_result} = hd(responses)
      assert Map.has_key?(tools_result, "tools")
      assert {:ok, resources_result} = Enum.at(responses, 1)
      assert Map.has_key?(resources_result, "resources")
    end
  end

  describe "3. Capability Enforcement Testing" do
    test "resources/subscribe is allowed in 2025-06-18" do
      {:ok, %{client: client}} = setup_connection("2025-06-18")
      assert {:ok, %{}} = Client.subscribe_resource(client, "res://test")
    end

    test "resources/subscribe is allowed in 2025-03-26" do
      {:ok, %{client: client}} = setup_connection("2025-03-26")
      assert {:ok, %{}} = Client.subscribe_resource(client, "res://test")
    end

    test "resources/subscribe is rejected in 2024-11-05" do
      {:ok, %{client: client}} = setup_connection("2024-11-05")
      {:error, error} = Client.subscribe_resource(client, "res://test")
      assert error.message =~ "Method not supported in version 2024-11-05"
    end

    test "completion/complete is allowed in 2025-06-18" do
      {:ok, %{client: client}} = setup_connection("2025-06-18")
      ref = %{"type" => "ref/prompt", "name" => "test_prompt"}
      {:ok, result} = Client.complete(client, ref, %{"name" => "p", "value" => "v"})
      assert result.completion == ["test completion"]
    end

    test "completion/complete is allowed in 2025-03-26" do
      {:ok, %{client: client}} = setup_connection("2025-03-26")
      ref = %{"type" => "ref/prompt", "name" => "test_prompt"}
      {:ok, result} = Client.complete(client, ref, %{"name" => "p", "value" => "v"})
      assert result.completion == ["test completion"]
    end

    test "completion/complete is rejected in 2024-11-05" do
      {:ok, %{client: client}} = setup_connection("2024-11-05")
      ref = %{"type" => "ref/prompt", "name" => "test_prompt"}
      {:error, error} = Client.complete(client, ref, %{"name" => "p", "value" => "v"})
      assert error.message =~ "Method not supported in version 2024-11-05"
    end
  end
end
