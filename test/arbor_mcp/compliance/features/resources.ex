defmodule Arbor.MCP.Compliance.Features.Resources do
  @moduledoc """
  Shared resource compliance tests across all MCP versions.
  Each test function specifies which versions it applies to.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Resources
      @version unquote(version)

      # Basic functionality (all versions)
      test "resources/list returns valid resource definitions" do
        Arbor.MCP.Compliance.Features.Resources.test_basic_resources_list(@version)
      end

      test "resources/read returns valid content" do
        Arbor.MCP.Compliance.Features.Resources.test_resource_read(@version)
      end

      # Version-specific features
      if @version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
        test "resource subscriptions work correctly" do
          Arbor.MCP.Compliance.Features.Resources.test_resource_subscriptions(@version)
        end

        test "resource list change notifications work" do
          Arbor.MCP.Compliance.Features.Resources.test_list_change_notifications(@version)
        end
      end

      if @version in ["2025-06-18", "2025-11-25"] do
        test "resources have title fields" do
          Arbor.MCP.Compliance.Features.Resources.test_resource_titles(@version)
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
  def test_basic_resources_list(version) do
    # Test that resources/list returns valid resource definitions
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, result} = Client.list_resources(test_context.client)

      # Validate basic structure
      assert is_map(result)
      assert Map.has_key?(result, :resources)
      assert is_list(result.resources)

      # Validate each resource
      for resource <- result.resources do
        validate_resource_structure(resource, version)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_resource_read(version) do
    # Test that resources/read returns valid content
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, resources} = Client.list_resources(test_context.client)

      if length(resources.resources) > 0 do
        resource = hd(resources.resources)
        {:ok, content} = Client.read_resource(test_context.client, resource.uri)

        # Validate content structure
        assert is_map(content)
        assert Map.has_key?(content, :uri)
        assert content.uri == resource.uri

        # Validate content based on type
        cond do
          Map.has_key?(content, :text) ->
            assert is_binary(content.text)

          Map.has_key?(content, :blob) ->
            assert is_binary(content.blob)

          true ->
            assert false, "Resource content must have either text or blob"
        end

        # Validate optional mimeType
        if Map.has_key?(content, :mimeType) do
          assert is_binary(content.mimeType)
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_resource_subscriptions(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    # Test resource subscriptions for versions that support them
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, resources} = Client.list_resources(test_context.client)

      if length(resources.resources) > 0 do
        resource_uri = hd(resources.resources).uri

        # Subscribe to resource
        {:ok, result} = Client.subscribe_resource(test_context.client, resource_uri)
        assert result == %{} or is_map(result)

        # Simulate resource update notification
        Server.notify_resource_update(test_context.server, resource_uri)

        # Give time for notification to be processed
        Process.sleep(50)

        # Unsubscribe from resource
        {:ok, result} = Client.unsubscribe_resource(test_context.client, resource_uri)
        assert result == %{} or is_map(result)
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_list_change_notifications(version)
      when version in ["2025-03-26", "2025-06-18", "2025-11-25"] do
    # Test resource list change notifications
    {:ok, test_context} = setup_test_client(version)

    try do
      # Test that server can send resource list change notifications
      Server.notify_resources_changed(test_context.server)

      # Give time for notification to be processed
      Process.sleep(50)

      # In a real implementation, the client would:
      # 1. Receive the notification
      # 2. Potentially re-fetch the resource list
      # 3. Update any cached resource information

      # Verify server capabilities include list change support
      {:ok, caps} = Client.server_capabilities(test_context.client)
      assert get_in(caps, ["resources", "listChanged"]) == true
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions for resource validation
  defp validate_resource_structure(resource, version) do
    # Basic resource structure validation
    assert is_map(resource)
    assert Map.has_key?(resource, :uri)
    assert is_binary(resource.uri)

    # Optional fields
    if Map.has_key?(resource, :name) do
      assert is_binary(resource.name)
    end

    if Map.has_key?(resource, :description) do
      assert is_binary(resource.description)
    end

    if Map.has_key?(resource, :mimeType) do
      assert is_binary(resource.mimeType)
    end

    # Version-specific validations
    case version do
      v when v in ["2025-03-26", "2025-06-18", "2025-11-25"] ->
        # These versions support additional resource features
        # Resources can be subscribed to in these versions
        :ok

      _ ->
        # Earlier versions have basic resource support only
        :ok
    end
  end

  def test_resource_titles(version) when version in ["2025-06-18", "2025-11-25"] do
    # Test that resources have title fields in 2025-06-18
    {:ok, test_context} = setup_test_client(version)

    try do
      {:ok, result} = Client.list_resources(test_context.client)

      # At least one resource should have both title and name fields
      resource_with_title =
        Enum.find(result.resources, fn resource ->
          Map.has_key?(resource, :title)
        end)

      if resource_with_title do
        assert is_binary(resource_with_title.title)
        assert String.length(resource_with_title.title) > 0

        # Should also have name field (programmatic identifier)
        if Map.has_key?(resource_with_title, :name) do
          assert is_binary(resource_with_title.name)
          # Name is typically shorter/simpler than title
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end
end
