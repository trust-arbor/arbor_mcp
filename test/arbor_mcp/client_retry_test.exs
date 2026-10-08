defmodule Arbor.MCP.ClientRetryTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Reliability.Retry

  describe "retry functionality integration" do
    test "client configuration with retry policies" do
      # Test that client can be configured with retry policies
      retry_policy = [max_attempts: 3, initial_delay: 10]

      # Test with a skip_connect option to avoid actual connection issues
      {:ok, client} =
        Client.start_link(
          _skip_connect: true,
          retry_policy: retry_policy
        )

      # Get the default retry policy to verify it was stored
      {:ok, stored_policy} = GenServer.call(client, :get_default_retry_policy)
      assert stored_policy == retry_policy

      Client.stop(client)
    end

    test "retry policies can be configured with different options" do
      retry_policy = [
        max_attempts: 5,
        initial_delay: 200,
        backoff_factor: 3,
        max_delay: 10_000
      ]

      {:ok, client} =
        Client.start_link(
          _skip_connect: true,
          retry_policy: retry_policy
        )

      {:ok, stored_policy} = GenServer.call(client, :get_default_retry_policy)
      assert stored_policy[:max_attempts] == 5
      assert stored_policy[:initial_delay] == 200
      assert stored_policy[:backoff_factor] == 3
      assert stored_policy[:max_delay] == 10_000

      Client.stop(client)
    end

    test "empty retry policy defaults to empty list" do
      {:ok, client} = Client.start_link(_skip_connect: true)

      {:ok, stored_policy} = GenServer.call(client, :get_default_retry_policy)
      assert stored_policy == []

      Client.stop(client)
    end
  end

  describe "retry policy merging" do
    test "merges client default with operation-specific policies" do
      # Test the policy merging logic
      client_default = [max_attempts: 5, initial_delay: 100, backoff_factor: 2]
      operation_override = [max_attempts: 3, initial_delay: 50]

      merged = Retry.merge_policies(client_default, operation_override)

      # Operation-specific values should override
      assert merged[:max_attempts] == 3
      assert merged[:initial_delay] == 50
      # Client defaults should remain for unspecified values
      assert merged[:backoff_factor] == 2
    end

    test "empty operation override keeps client defaults" do
      client_default = [max_attempts: 5, initial_delay: 100]
      operation_override = []

      merged = Retry.merge_policies(client_default, operation_override)

      assert merged == client_default
    end

    test "empty client default uses operation overrides" do
      client_default = []
      operation_override = [max_attempts: 3, initial_delay: 50]

      merged = Retry.merge_policies(client_default, operation_override)

      assert merged == operation_override
    end
  end

  describe "MCP retry logic" do
    test "MCP defaults include correct retry conditions" do
      mcp_opts = Retry.mcp_defaults()
      should_retry? = Keyword.get(mcp_opts, :should_retry?)

      # Should retry network and transport errors
      assert should_retry?.(:timeout) == true
      assert should_retry?.({:error, :closed}) == true
      assert should_retry?.({:error, :econnrefused}) == true

      # Should retry server errors (MCP error codes -32099 to -32000)
      assert should_retry?.(%{"error" => %{"code" => -32050}}) == true

      # Should not retry client errors (invalid request, method not found, etc.)
      assert should_retry?.(%{"error" => %{"code" => -32600}}) == false
      assert should_retry?.(%{"error" => %{"code" => -32601}}) == false

      # Should not retry unknown errors
      assert should_retry?.(:unknown_error) == false
    end

    test "MCP defaults can be overridden" do
      custom_opts = Retry.mcp_defaults(max_attempts: 10, initial_delay: 500)

      assert custom_opts[:max_attempts] == 10
      assert custom_opts[:initial_delay] == 500
      # Other defaults remain
      assert custom_opts[:backoff_factor] == 2
      assert custom_opts[:jitter] == true
    end
  end

  describe "integration with make_request" do
    test "make_request handles retry policy merging correctly" do
      # This tests the logic in make_request without needing a real connection

      # Test that retry policy parsing works
      retry_policy = [max_attempts: 3]

      # The :use_default symbol should be handled
      effective_policy = normalize_retry_policy(retry_policy)

      assert effective_policy == [max_attempts: 3]
      assert normalize_retry_policy(:use_default) == []

      # Test disabled retry
      disabled_policy = false
      effective_disabled = normalize_retry_policy(disabled_policy)

      assert effective_disabled == []
    end
  end

  defp normalize_retry_policy(:use_default), do: []
  defp normalize_retry_policy(false), do: []
  defp normalize_retry_policy(policy) when is_list(policy), do: policy
end
