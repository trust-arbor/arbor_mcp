defmodule Arbor.MCP.Compliance.Features.Batch do
  @moduledoc """
  JSON-RPC batch request compliance tests.
  Batch support is available in 2025-03-26 only (removed in 2025-06-18).
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Batch
      @version unquote(version)

      # Batch processing features only in 2025-03-26 (removed in 2025-06-18)
      if @version == "2025-03-26" do
        test "JSON-RPC batch requests work correctly" do
          Arbor.MCP.Compliance.Features.Batch.test_batch_requests(@version)
        end

        test "batch responses maintain order" do
          Arbor.MCP.Compliance.Features.Batch.test_batch_response_order(@version)
        end

        test "batch with mixed success and errors" do
          Arbor.MCP.Compliance.Features.Batch.test_batch_mixed_results(@version)
        end

        test "empty batch request is rejected" do
          Arbor.MCP.Compliance.Features.Batch.test_empty_batch(@version)
        end

        test "initialize cannot be in batch" do
          Arbor.MCP.Compliance.Features.Batch.test_initialize_not_in_batch(@version)
        end

        test "batch size limits are enforced" do
          Arbor.MCP.Compliance.Features.Batch.test_batch_size_limits(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  import Arbor.MCP.ComplianceTestHelpers

  # Actual test implementations
  def test_batch_requests(version) when version == "2025-03-26" do
    {:ok, %{client: client, server: server}} = setup_test_client(version)

    # Create batch request
    batch = [
      Protocol.encode_list_tools(),
      Protocol.encode_list_resources(),
      Protocol.encode_list_prompts()
    ]

    # Send batch
    {:ok, responses} = Client.send_batch(client, batch)

    assert length(responses) == 3
    # Results should be maps with content (not {"result" => ...} structure)
    assert Enum.all?(responses, fn r -> is_map(r) end)

    # Verify each response has expected structure
    [tools_response, resources_response, prompts_response] = responses

    assert Map.has_key?(tools_response, :tools) or Map.has_key?(tools_response, "tools")

    assert Map.has_key?(resources_response, :resources) or
             Map.has_key?(resources_response, "resources")

    assert Map.has_key?(prompts_response, :prompts) or Map.has_key?(prompts_response, "prompts")

    cleanup_test_client(%{client: client, server: server})
  end

  def test_batch_response_order(version) when version == "2025-03-26" do
    {:ok, %{client: client, server: server}} = setup_test_client(version)

    # Create batch with identifiable requests
    batch = [
      Map.put(Protocol.encode_list_tools(), "id", 1),
      Map.put(Protocol.encode_list_resources(), "id", 2),
      Map.put(Protocol.encode_list_prompts(), "id", 3)
    ]

    # Send batch
    {:ok, responses} = Client.send_batch(client, batch)

    # Responses should maintain order
    assert length(responses) == 3

    # Each response should have the corresponding ID
    response_ids =
      Enum.map(responses, fn r ->
        Map.get(r, "id") || Map.get(r, :id)
      end)

    assert response_ids == [1, 2, 3]

    cleanup_test_client(%{client: client, server: server})
  end

  def test_batch_mixed_results(version) when version == "2025-03-26" do
    {:ok, %{client: client, server: server}} = setup_test_client(version)

    # Create batch with valid and invalid requests
    batch = [
      Protocol.encode_list_tools(),
      # Invalid method
      %{
        "jsonrpc" => "2.0",
        "method" => "invalid/method",
        "params" => %{},
        "id" => 2
      },
      Protocol.encode_list_resources()
    ]

    # Send batch
    {:ok, responses} = Client.send_batch(client, batch)

    assert length(responses) == 3

    # First response should be success
    first = Enum.at(responses, 0)
    assert Map.has_key?(first, :tools) or Map.has_key?(first, "tools")

    # Second response should be error
    second = Enum.at(responses, 1)
    assert Map.has_key?(second, "error")
    assert is_map(second["error"])
    assert Map.has_key?(second["error"], "code")
    assert Map.has_key?(second["error"], "message")

    # Third response should be success
    third = Enum.at(responses, 2)
    assert Map.has_key?(third, :resources) or Map.has_key?(third, "resources")

    cleanup_test_client(%{client: client, server: server})
  end

  def test_empty_batch(version) when version == "2025-03-26" do
    {:ok, %{client: client, server: server}} = setup_test_client(version)

    # Empty batch should be rejected
    result = Client.send_batch(client, [])

    # Should return error
    assert {:error, _reason} = result

    cleanup_test_client(%{client: client, server: server})
  end

  def test_initialize_not_in_batch(version) when version == "2025-03-26" do
    {:ok, %{client: client, server: server}} = setup_test_client(version)

    # Batch with initialize should be rejected
    batch = [
      %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => version,
          "clientInfo" => %{
            "name" => "test",
            "version" => "1.0"
          }
        },
        "id" => 1
      },
      Protocol.encode_list_tools()
    ]

    # Should return error
    result = Client.send_batch(client, batch)
    assert {:error, _reason} = result

    cleanup_test_client(%{client: client, server: server})
  end

  def test_batch_size_limits(version) when version == "2025-03-26" do
    {:ok, %{client: client, server: server}} = setup_test_client(version)

    # Test reasonable batch size (should succeed)
    small_batch =
      for i <- 1..10 do
        Map.put(Protocol.encode_list_tools(), "id", i)
      end

    {:ok, responses} = Client.send_batch(client, small_batch)
    assert length(responses) == 10

    # Test excessive batch size (implementation-specific limit)
    # Most implementations limit to 100-1000 requests per batch
    # This is not specified in the spec but is a practical limit
    large_batch =
      for i <- 1..101 do
        Map.put(Protocol.encode_list_tools(), "id", i)
      end

    # This might succeed or fail depending on implementation
    result = Client.send_batch(client, large_batch)

    case result do
      {:ok, responses} ->
        # If it succeeds, verify response count
        assert length(responses) == 101

      {:error, reason} ->
        # If it fails, it should be due to batch size
        assert String.contains?(to_string(reason), "batch") or
                 String.contains?(to_string(reason), "size") or
                 String.contains?(to_string(reason), "limit")
    end

    cleanup_test_client(%{client: client, server: server})
  end
end
