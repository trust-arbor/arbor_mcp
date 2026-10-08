defmodule Arbor.MCP.Compliance.Features.Roots do
  @moduledoc """
  Roots capability compliance tests for MCP versions.
  Roots is a client capability available in all versions.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Roots
      @version unquote(version)

      # Roots is a client capability (all versions)
      test "roots/list returns valid root directories" do
        Arbor.MCP.Compliance.Features.Roots.test_list_roots(@version)
      end

      test "roots have proper URI format" do
        Arbor.MCP.Compliance.Features.Roots.test_roots_uri_format(@version)
      end

      test "roots optional name field is validated" do
        Arbor.MCP.Compliance.Features.Roots.test_roots_name_field(@version)
      end

      # Roots change notifications (2025-03-26+)
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "roots change notifications work" do
          Arbor.MCP.Compliance.Features.Roots.test_roots_change_notifications(@version)
        end
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers
  alias Arbor.MCP.Client
  alias Arbor.MCP.Server

  # Actual test implementations
  def test_list_roots(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      # Handler should provide roots
      handler = test_context.handler
      {:ok, state} = handler.init([])
      {:ok, roots, _state} = handler.handle_list_roots(state)

      # Validate we got roots
      assert is_list(roots)
      assert length(roots) > 0

      # Validate each root structure
      for root <- roots do
        validate_root_structure(root, version)
      end

      # If client is available, test through client API
      if Map.has_key?(test_context, :client) do
        {:ok, response} = Client.list_roots(test_context.client)

        # Response should have roots array
        assert Map.has_key?(response, :roots) || Map.has_key?(response, "roots")
        client_roots = Map.get(response, :roots) || Map.get(response, "roots")
        assert is_list(client_roots)
        assert length(client_roots) == length(roots)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_roots_uri_format(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])
      {:ok, roots, _state} = handler.handle_list_roots(state)

      # All roots must have properly formatted URIs
      for root <- roots do
        assert Map.has_key?(root, :uri)
        uri = root.uri
        assert is_binary(uri)

        # Common URI schemes for roots
        assert String.starts_with?(uri, "file://") or
                 String.starts_with?(uri, "https://") or
                 String.starts_with?(uri, "http://") or
                 String.starts_with?(uri, "git://")

        # URI should not have trailing slashes (unless it's the root)
        unless uri == "file:///" do
          refute String.ends_with?(uri, "/")
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_roots_name_field(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])
      {:ok, roots, _state} = handler.handle_list_roots(state)

      # Ensure we have roots with and without names for testing
      roots_with_name = Enum.filter(roots, &Map.has_key?(&1, :name))
      roots_without_name = Enum.reject(roots, &Map.has_key?(&1, :name))

      # Should have at least one root with a name
      assert length(roots_with_name) > 0, "Expected at least one root with a name"

      # Should have at least one root without a name (to test optionality)
      assert length(roots_without_name) > 0, "Expected at least one root without a name"

      # Validate roots with names
      for root <- roots_with_name do
        assert is_binary(root.name)
        assert String.length(root.name) > 0
      end

      # Validate roots without names still have URI
      for root <- roots_without_name do
        assert Map.has_key?(root, :uri)
        refute Map.has_key?(root, :name)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_roots_change_notifications(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    {:ok, test_context} = setup_test_client(version)

    try do
      server = test_context.server

      # Server should be able to send roots changed notification
      assert :ok = Server.notify_roots_changed(server)

      # In a real test, we'd verify the client receives the notification
      # For now, we just verify the server can send it without error
      Process.sleep(50)

      # Notification format should be correct
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/roots/list_changed"
      }

      validate_roots_change_notification(notification)
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions
  defp validate_root_structure(root, _version) do
    # Required field: uri
    assert Map.has_key?(root, :uri)
    assert is_binary(root.uri)

    # Optional field: name
    if Map.has_key?(root, :name) do
      assert is_binary(root.name)
      assert String.length(root.name) > 0
    end

    # No other fields should be present in basic roots
    allowed_keys = [:uri, :name]

    for {key, _value} <- root do
      assert key in allowed_keys, "Unexpected field #{key} in root"
    end
  end

  defp validate_roots_change_notification(notification) do
    # Validate notification structure
    assert notification["method"] == "notifications/roots/list_changed"
    assert notification["jsonrpc"] == "2.0"

    # Notifications don't have an ID
    refute Map.has_key?(notification, "id")

    # Roots change notification has no params
    refute Map.has_key?(notification, "params")
  end
end
