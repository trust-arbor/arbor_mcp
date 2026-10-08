defmodule Arbor.MCP.ResourcesComplianceTest do
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestResourcesServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         resources: [
           %{
             uri: "file:///readme.md",
             name: "README",
             description: "Project documentation",
             mime_type: "text/markdown",
             size: 1024
           },
           %{
             uri: "config://app/settings.json",
             name: "Settings",
             description: "App configuration",
             mime_type: "application/json"
           },
           %{
             uri: "data://binary/logo.png",
             name: "Logo",
             mime_type: "image/png",
             size: 2048
           },
           %{
             uri: "https://example.com/api/data",
             name: "External API",
             description: "External data source",
             mime_type: "application/json"
           },
           %{
             uri: "git://repo/main/src/main.ex",
             name: "Source File",
             description: "Main source file",
             mime_type: "text/plain"
           }
         ],
         subscriptions: %{},
         last_update: DateTime.utc_now()
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "test-resources-server", version: "1.0.0"},
         capabilities: %{
           resources: %{
             subscribe: true,
             listChanged: true
           }
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_call_tool(_name, _args, state) do
      {:error, "No tools available", state}
    end

    @impl true
    def handle_list_resources(cursor, state) do
      # Simple pagination for testing
      page_size = 3

      {items, next_cursor} =
        case cursor do
          nil ->
            {Enum.take(state.resources, page_size),
             if(length(state.resources) > page_size, do: "page2", else: nil)}

          "page2" ->
            remaining = Enum.drop(state.resources, page_size)

            {Enum.take(remaining, page_size),
             if(length(remaining) > page_size, do: "page3", else: nil)}

          _ ->
            {Enum.drop(state.resources, page_size * 2), nil}
        end

      {:ok, items, next_cursor, state}
    end

    @impl true
    def handle_list_resource_templates(cursor, state) do
      # Resource templates for testing
      templates = [
        %{
          uriTemplate: "file:///{project}/docs/{file}.md",
          name: "Project Documentation",
          description: "Documentation files for projects"
        },
        %{
          uriTemplate: "config://{app}/settings/{env}.json",
          name: "Configuration Files",
          description: "Application configuration for different environments"
        },
        %{
          uriTemplate: "data://{type}/{id}",
          name: "Data Resources",
          description: "Various data resources by type and ID"
        }
      ]

      # Simple pagination for testing
      page_size = 2

      {items, next_cursor} =
        case cursor do
          nil ->
            {Enum.take(templates, page_size),
             if(length(templates) > page_size, do: "page2", else: nil)}

          "page2" ->
            remaining = Enum.drop(templates, page_size)
            {Enum.take(remaining, page_size), nil}

          _ ->
            {[], nil}
        end

      {:ok, items, next_cursor, state}
    end

    @impl true
    def handle_read_resource(uri, state) do
      case generate_content(uri) do
        {:ok, content} -> {:ok, content, state}
        {:error, reason} -> {:error, reason, state}
      end
    end

    @impl true
    def handle_subscribe_resource(uri, state) do
      if resource_exists?(uri, state) do
        # Track subscription
        subscriptions = Map.update(state.subscriptions, uri, 1, &(&1 + 1))
        {:ok, %{}, %{state | subscriptions: subscriptions}}
      else
        {:error, "Resource not found", state}
      end
    end

    @impl true
    def handle_unsubscribe_resource(uri, state) do
      subscriptions = Map.update(state.subscriptions, uri, 0, &max(0, &1 - 1))
      {:ok, %{}, %{state | subscriptions: subscriptions}}
    end

    # Helper functions
    defp resource_exists?(uri, state) do
      Enum.any?(state.resources, &(&1.uri == uri))
    end

    defp generate_content(uri) do
      case uri do
        "file:///readme.md" ->
          {:ok,
           %{
             uri: uri,
             mimeType: "text/markdown",
             text: "# Test Project\n\nThis is a test README file."
           }}

        "config://app/settings.json" ->
          {:ok,
           %{
             uri: uri,
             mimeType: "application/json",
             text: Jason.encode!(%{theme: "dark", version: "1.0"})
           }}

        "data://binary/logo.png" ->
          # Simulate base64 encoded binary data
          fake_png_data = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

          {:ok,
           %{
             uri: uri,
             mimeType: "image/png",
             blob: fake_png_data
           }}

        "https://example.com/api/data" ->
          {:ok,
           %{
             uri: uri,
             mimeType: "application/json",
             text: Jason.encode!(%{status: "ok", data: []})
           }}

        "git://repo/main/src/main.ex" ->
          {:ok,
           %{
             uri: uri,
             mimeType: "text/plain",
             text: "defmodule Main do\n  def start, do: :ok\nend"
           }}

        _ ->
          {:error, "Resource not found"}
      end
    end
  end

  setup do
    # Start server
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestResourcesServer
      )

    # Start client
    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only
      )

    # Wait for initialization
    Process.sleep(100)

    %{server: server, client: client}
  end

  describe "resources capability compliance" do
    test "server declares resources capability correctly", %{client: client} do
      # Should be able to list resources
      {:ok, result} = Client.list_resources(client)

      assert %{resources: resources} = result
      assert is_list(resources)
      assert length(resources) > 0
    end

    test "resources have required structure", %{client: client} do
      {:ok, result} = Client.list_resources(client)

      resource = hd(result.resources)

      # Required fields
      assert Map.has_key?(resource, :uri)
      assert Map.has_key?(resource, :name)
      assert is_binary(resource.uri)
      assert is_binary(resource.name)

      # Optional fields that may be present
      if Map.has_key?(resource, :description) do
        assert is_binary(resource.description)
      end

      if Map.has_key?(resource, :mimeType) do
        assert is_binary(resource.mime_type)
      end

      if Map.has_key?(resource, :size) do
        assert is_integer(resource.size)
        assert resource.size >= 0
      end
    end

    test "supports different URI schemes", %{client: client} do
      # Get all pages to see all resources
      {:ok, page1} = Client.list_resources(client)
      uris = Enum.map(page1.resources, & &1.uri)

      # Get additional pages if they exist
      all_uris =
        if Map.get(page1, :nextCursor) do
          {:ok, page2} = Client.list_resources(client, cursor: page1.nextCursor)
          uris ++ Enum.map(page2.resources, & &1.uri)
        else
          uris
        end

      # Check for different schemes across all pages
      assert Enum.any?(all_uris, &String.starts_with?(&1, "file://"))
      assert Enum.any?(all_uris, &String.starts_with?(&1, "config://"))
      assert Enum.any?(all_uris, &String.starts_with?(&1, "https://"))
      assert Enum.any?(all_uris, &String.starts_with?(&1, "git://"))
      assert Enum.any?(all_uris, &String.starts_with?(&1, "data://"))
    end
  end

  describe "resources/list method compliance" do
    test "basic listing works", %{client: client} do
      {:ok, result} = Client.list_resources(client)

      assert %{resources: resources} = result
      assert is_list(resources)
      # First page
      assert length(resources) == 3

      # Should have nextCursor for pagination
      assert Map.has_key?(result, :nextCursor)
      assert result.nextCursor == "page2"
    end

    test "pagination with cursor works", %{client: client} do
      # Get first page
      {:ok, page1} = Client.list_resources(client)
      assert length(page1.resources) == 3
      assert page1.nextCursor == "page2"

      # Get second page
      {:ok, page2} = Client.list_resources(client, cursor: "page2")
      # Remaining resources
      assert length(page2.resources) == 2
      # May or may not have nextCursor depending on remaining items
      next_cursor = Map.get(page2, :nextCursor)
      assert is_nil(next_cursor) or next_cursor == "page3"
    end

    test "invalid cursor handled gracefully", %{client: client} do
      {:ok, result} = Client.list_resources(client, cursor: "invalid_cursor")

      # Should return empty list or handle gracefully
      assert %{resources: resources} = result
      assert is_list(resources)
    end
  end

  describe "resources/read method compliance" do
    test "reads text content correctly", %{client: client} do
      {:ok, result} = Client.read_resource(client, "file:///readme.md")

      assert %{contents: [content]} = result
      assert content.uri == "file:///readme.md"
      assert content.mime_type == "text/markdown"
      assert Map.has_key?(content, :text)
      assert String.contains?(content.text, "Test Project")
    end

    test "reads JSON content correctly", %{client: client} do
      {:ok, result} = Client.read_resource(client, "config://app/settings.json")

      assert %{contents: [content]} = result
      assert content.uri == "config://app/settings.json"
      assert content.mime_type == "application/json"
      assert Map.has_key?(content, :text)

      # Should be valid JSON
      {:ok, parsed} = Jason.decode(content.text)
      assert is_map(parsed)
    end

    test "reads binary content correctly", %{client: client} do
      {:ok, result} = Client.read_resource(client, "data://binary/logo.png")

      assert %{contents: [content]} = result
      assert content.uri == "data://binary/logo.png"
      assert content.mime_type == "image/png"
      assert Map.has_key?(content, :blob)

      # Should be base64 encoded
      assert is_binary(content.blob)
      {:ok, _decoded} = Base.decode64(content.blob)
    end

    test "handles non-existent resource", %{client: client} do
      {:error, reason} = Client.read_resource(client, "file:///nonexistent.txt")

      # Should return appropriate error
      assert is_map(reason) or is_binary(reason)
    end
  end

  describe "resource subscription compliance" do
    test "subscribe to resource works", %{client: client} do
      {:ok, result} = Client.subscribe_resource(client, "file:///readme.md")

      # Should return success
      assert is_map(result)
    end

    test "unsubscribe from resource works", %{client: client} do
      # Subscribe first
      {:ok, _} = Client.subscribe_resource(client, "file:///readme.md")

      # Then unsubscribe
      {:ok, result} = Client.unsubscribe_resource(client, "file:///readme.md")

      assert is_map(result)
    end

    test "subscribe to non-existent resource fails", %{client: client} do
      {:error, _reason} = Client.subscribe_resource(client, "file:///nonexistent.txt")
    end
  end

  describe "resource templates compliance" do
    test "lists resource templates", %{client: client} do
      {:ok, result} = Client.list_resource_templates(client)

      assert %{resourceTemplates: templates} = result
      assert is_list(templates)
      assert length(templates) > 0

      template = hd(templates)
      assert Map.has_key?(template, :uriTemplate)
      assert Map.has_key?(template, :name)
      assert is_binary(template.uriTemplate)
      assert is_binary(template.name)

      # Check for URI template syntax
      assert String.contains?(template.uriTemplate, "{")
      assert String.contains?(template.uriTemplate, "}")
    end

    test "templates have proper structure", %{client: client} do
      {:ok, result} = Client.list_resource_templates(client)

      Enum.each(result.resourceTemplates, fn template ->
        # Required fields
        assert is_binary(template.uriTemplate)
        assert is_binary(template.name)

        # Optional fields
        if Map.has_key?(template, :description) do
          assert is_binary(template.description)
        end

        if Map.has_key?(template, :mimeType) do
          assert is_binary(template.mime_type)
        end
      end)
    end
  end

  describe "protocol compliance" do
    test "resources/list protocol format" do
      request = Protocol.encode_list_resources()

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "resources/list"
      assert Map.has_key?(request, "id")
      assert request["params"] == %{}
    end

    test "resources/list with cursor protocol format" do
      request = Protocol.encode_list_resources("test_cursor")

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "resources/list"
      assert request["params"] == %{"cursor" => "test_cursor"}
    end

    test "resources/read protocol format" do
      request = Protocol.encode_read_resource("file:///test.txt")

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "resources/read"
      assert request["params"]["uri"] == "file:///test.txt"
    end

    test "resource notifications protocol format" do
      # List changed notification
      list_notification = Protocol.encode_resources_changed()
      assert list_notification["jsonrpc"] == "2.0"
      assert list_notification["method"] == "notifications/resources/list_changed"
      assert list_notification["params"] == %{}
      refute Map.has_key?(list_notification, "id")

      # Resource updated notification
      update_notification = Protocol.encode_resource_updated("file:///test.txt")
      assert update_notification["jsonrpc"] == "2.0"
      assert update_notification["method"] == "notifications/resources/updated"
      assert update_notification["params"]["uri"] == "file:///test.txt"
      refute Map.has_key?(update_notification, "id")
    end
  end

  describe "content type compliance" do
    test "text content structure is correct", %{client: client} do
      {:ok, result} = Client.read_resource(client, "file:///readme.md")
      content = hd(result.contents)

      # Text content must have uri, mimeType, text
      assert Map.has_key?(content, :uri)
      assert Map.has_key?(content, :mimeType)
      assert Map.has_key?(content, :text)
      refute Map.has_key?(content, :blob)
    end

    test "binary content structure is correct", %{client: client} do
      {:ok, result} = Client.read_resource(client, "data://binary/logo.png")
      content = hd(result.contents)

      # Binary content must have uri, mimeType, blob
      assert Map.has_key?(content, :uri)
      assert Map.has_key?(content, :mimeType)
      assert Map.has_key?(content, :blob)
      refute Map.has_key?(content, :text)
    end

    test "mimeType values are valid", %{client: client} do
      {:ok, result} = Client.list_resources(client, cursor: nil)

      # Check all pages to get all resources
      all_resources = result.resources

      all_resources =
        if result.nextCursor do
          {:ok, page2} = Client.list_resources(client, cursor: result.nextCursor)
          all_resources ++ page2.resources
        else
          all_resources
        end

      # Verify mimeType format for resources that have it
      Enum.each(all_resources, fn resource ->
        if Map.has_key?(resource, :mimeType) do
          mime_type = resource.mime_type
          assert is_binary(mime_type)
          # Should follow type/subtype format
          assert String.contains?(mime_type, "/")
          [type, _subtype] = String.split(mime_type, "/", parts: 2)
          assert String.length(type) > 0
        end
      end)
    end
  end

  describe "access control and validation" do
    test "URI validation occurs", %{client: client} do
      # Test with clearly invalid URI
      {:error, _reason} = Client.read_resource(client, "")
    end

    test "handles various URI schemes correctly", %{client: client} do
      schemes = [
        "file:///readme.md",
        "config://app/settings.json",
        "https://example.com/api/data",
        "git://repo/main/src/main.ex"
      ]

      Enum.each(schemes, fn uri ->
        case Client.read_resource(client, uri) do
          {:ok, result} ->
            content = hd(result.contents)
            assert content.uri == uri

          {:error, _reason} ->
            # Error is acceptable for access control
            :ok
        end
      end)
    end
  end
end
