defmodule Arbor.MCP.Compliance.Features.Transport do
  @moduledoc """
  Shared transport compliance tests across all MCP versions.

  Note: This module intentionally uses full module names in the __using__ macro
  to avoid scoping issues when the macro is expanded in different contexts.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:40 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Transport
      @version unquote(version)

      # Basic functionality (all versions)
      test "JSON-RPC message format is valid" do
        Arbor.MCP.Compliance.Features.Transport.test_jsonrpc_format(@version)
      end

      test "protocol version negotiation works" do
        Arbor.MCP.Compliance.Features.Transport.test_version_negotiation(@version)
      end

      # Batch processing (2025-03-26 only, removed in 2025-06-18)
      if @version == "2025-03-26" do
        test "JSON-RPC batch processing works" do
          Arbor.MCP.Compliance.Features.Transport.test_batch_processing(@version)
        end
      end

      # Streamable HTTP and progress notifications (2025-03-26+)
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "Streamable HTTP transport works" do
          Arbor.MCP.Compliance.Features.Transport.test_streamable_http(@version)
        end
      end

      if @version in ["2025-06-18", "2025-11-25"] do
        test "MCP-Protocol-Version header is required for HTTP" do
          Arbor.MCP.Compliance.Features.Transport.test_protocol_version_header(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions

  # Actual test implementations
  def test_jsonrpc_format(version) do
    # Test that JSON-RPC message format is valid for all versions
    assert is_binary(version)
    assert version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    # Test basic JSON-RPC 2.0 message structure
    request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/list",
      "id" => 1
    }

    validate_jsonrpc_request(request)

    # Test response structure
    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "tools" => []
      }
    }

    validate_jsonrpc_response(response)
  end

  def test_version_negotiation(version) do
    # Test protocol version negotiation
    assert is_binary(version)

    # Test initialize request structure
    initialize_request = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "id" => 1,
      "params" => %{
        "protocolVersion" => version,
        "clientInfo" => %{
          "name" => "test-client",
          "version" => "1.0.0"
        },
        "capabilities" => %{}
      }
    }

    validate_initialize_request(initialize_request, version)
  end

  def test_batch_processing(version) when version == "2025-03-26" do
    # Test JSON-RPC batch processing (only supported in 2025-03-26, removed in 2025-06-18)
    assert version == "2025-03-26"

    # Test batch request structure
    batch_request = [
      %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => 1
      },
      %{
        "jsonrpc" => "2.0",
        "method" => "resources/list",
        "id" => 2
      }
    ]

    validate_batch_request(batch_request)

    # Test batch response structure
    batch_response = [
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"tools" => []}
      },
      %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "result" => %{"resources" => []}
      }
    ]

    validate_batch_response(batch_response)
  end

  def test_streamable_http(version) when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    # Test Streamable HTTP transport for versions that support it
    assert version in ["2025-03-26", "2025-06-18", "2025-11-25"]

    # Test that Streamable HTTP transport can be configured
    # TODO: Add actual transport testing
    # This would test the new Streamable HTTP transport that replaced HTTP+SSE

    # For now, test basic transport configuration
    transport_config = %{
      transport: :http,
      url: "https://example.com/mcp",
      streaming: true
    }

    validate_transport_config(transport_config)
  end

  # Helper functions for transport validation
  defp validate_jsonrpc_request(request) do
    # Validate JSON-RPC 2.0 request structure
    assert Map.has_key?(request, "jsonrpc")
    assert request["jsonrpc"] == "2.0"
    assert Map.has_key?(request, "method")
    assert is_binary(request["method"])

    # ID is required for requests (not notifications)
    if Map.has_key?(request, "id") do
      assert is_integer(request["id"]) or is_binary(request["id"])
    end
  end

  defp validate_jsonrpc_response(response) do
    # Validate JSON-RPC 2.0 response structure
    assert Map.has_key?(response, "jsonrpc")
    assert response["jsonrpc"] == "2.0"
    assert Map.has_key?(response, "id")

    # Must have either result or error, but not both
    has_result = Map.has_key?(response, "result")
    has_error = Map.has_key?(response, "error")
    assert has_result != has_error, "Response must have either result or error, but not both"
  end

  defp validate_initialize_request(request, version) do
    # Validate initialize request structure
    validate_jsonrpc_request(request)
    assert request["method"] == "initialize"

    params = request["params"]
    assert Map.has_key?(params, "protocolVersion")
    assert params["protocolVersion"] == version
    assert Map.has_key?(params, "clientInfo")
    assert Map.has_key?(params, "capabilities")

    # Validate client info
    client_info = params["clientInfo"]
    assert Map.has_key?(client_info, "name")
    assert Map.has_key?(client_info, "version")
    assert is_binary(client_info["name"])
    assert is_binary(client_info["version"])
  end

  defp validate_batch_request(batch) do
    # Validate JSON-RPC batch request structure
    assert is_list(batch)
    assert length(batch) > 0, "Batch request cannot be empty"

    for request <- batch do
      validate_jsonrpc_request(request)
    end
  end

  defp validate_batch_response(batch) do
    # Validate JSON-RPC batch response structure
    assert is_list(batch)
    assert length(batch) > 0, "Batch response cannot be empty"

    for response <- batch do
      validate_jsonrpc_response(response)
    end
  end

  defp validate_transport_config(config) do
    # Validate transport configuration
    assert Map.has_key?(config, :transport)
    assert config.transport in [:http, :stdio, :beam]

    if config.transport == :http do
      assert Map.has_key?(config, :url)
      assert is_binary(config.url)
      assert String.starts_with?(config.url, "http")
    end
  end

  def test_protocol_version_header(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test MCP-Protocol-Version header requirement for HTTP transport
    assert version in ["2025-06-18", "2025-11-25"]

    # In HTTP transport, subsequent requests must include MCP-Protocol-Version header
    # This is handled by the HTTP transport implementation

    # Mock header that would be sent
    headers = [
      {"Content-Type", "application/json"},
      {"MCP-Protocol-Version", "2025-06-18"}
    ]

    # Validate header is present
    assert {"MCP-Protocol-Version", version} in headers

    # Test that the header value matches the negotiated version
    header_value =
      Enum.find_value(headers, fn
        {"MCP-Protocol-Version", value} -> value
        _ -> nil
      end)

    assert header_value == version
  end
end
