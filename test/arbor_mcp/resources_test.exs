defmodule Arbor.MCP.ResourcesTest do
  use ExUnit.Case, async: true

  @moduletag :resources

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestResourcesHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         resources: default_resources(),
         subscriptions: MapSet.new(),
         resource_data: %{
           "file:///config.json" => ~s({"version": "1.0.0", "debug": true}),
           "file:///data.csv" => "name,age\nAlice,30\nBob,25",
           "file:///image.png" => Base.encode64("fake png data")
         }
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "test-resources-server",
           version: "1.0.0"
         },
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
    def handle_call_tool(_name, _arguments, state) do
      {:error, "No tools available", state}
    end

    @impl true
    def handle_list_resources(cursor, state) do
      resources = state.resources

      # Simple pagination: return 2 resources at a time
      case cursor do
        nil ->
          {:ok, Enum.take(resources, 2), "page2", state}

        "page2" ->
          {:ok, Enum.drop(resources, 2), nil, state}

        _ ->
          {:error, "Invalid cursor", state}
      end
    end

    @impl true
    def handle_read_resource(uri, state) do
      case Map.get(state.resource_data, uri) do
        nil ->
          {:error, "Resource not found: #{uri}", state}

        data ->
          content = build_resource_content(uri, data)
          {:ok, content, state}
      end
    end

    @impl true
    def handle_subscribe_resource(uri, state) do
      if Map.has_key?(state.resource_data, uri) do
        new_subscriptions = MapSet.put(state.subscriptions, uri)
        {:ok, %{}, %{state | subscriptions: new_subscriptions}}
      else
        {:error, "Resource not found: #{uri}", state}
      end
    end

    @impl true
    def handle_unsubscribe_resource(uri, state) do
      new_subscriptions = MapSet.delete(state.subscriptions, uri)
      {:ok, %{}, %{state | subscriptions: new_subscriptions}}
    end

    @impl true
    def handle_list_resource_templates(_cursor, state) do
      templates = [
        %{
          uriTemplate: "file:///{path}",
          name: "File Resource",
          description: "Access files by path",
          mime_type: "text/plain"
        },
        %{
          uriTemplate: "db://{table}/{id}",
          name: "Database Record",
          description: "Access database records",
          mime_type: "application/json"
        }
      ]

      {:ok, templates, nil, state}
    end

    defp default_resources do
      [
        %{
          uri: "file:///config.json",
          name: "Application Config",
          description: "Main configuration file",
          mime_type: "application/json"
        },
        %{
          uri: "file:///data.csv",
          name: "Sample Data",
          description: "CSV data file",
          mime_type: "text/csv"
        },
        %{
          uri: "file:///image.png",
          name: "Logo Image",
          description: "Company logo",
          mime_type: "image/png"
        }
      ]
    end

    defp build_resource_content(uri, data) do
      case uri do
        "file:///image.png" ->
          %{
            uri: uri,
            mime_type: "image/png",
            # Already base64 encoded
            blob: data
          }

        "file:///config.json" ->
          %{
            uri: uri,
            mime_type: "application/json",
            text: data
          }

        _ ->
          %{
            uri: uri,
            text: data
          }
      end
    end
  end

  setup do
    # Start server with resources handler using BEAM transport
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestResourcesHandler
      )

    # Start client connecting to the server
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

  describe "resources functionality" do
    test "client can list resources with pagination", %{client: client} do
      # First page
      {:ok, %{resources: page1, nextCursor: cursor}} = Client.list_resources(client)
      assert length(page1) == 2
      assert cursor == "page2"

      # Check first page resources
      assert Enum.at(page1, 0).uri == "file:///config.json"
      assert Enum.at(page1, 0).mime_type == "application/json"
      assert Enum.at(page1, 1).uri == "file:///data.csv"

      # Second page
      {:ok, result2} = Client.list_resources(client, cursor: cursor)
      page2 = result2.resources
      assert is_nil(result2[:nextCursor])
      assert length(page2) == 1
      assert Enum.at(page2, 0).uri == "file:///image.png"
    end

    test "client can read text resources", %{client: client} do
      # Read JSON resource
      {:ok, content} = Client.read_resource(client, "file:///config.json")
      assert content.contents
      assert length(content.contents) == 1

      resource = hd(content.contents)
      assert resource.uri == "file:///config.json"
      assert resource.mime_type == "application/json"
      assert resource.text =~ "version"
      assert resource.text =~ "1.0.0"

      # Read CSV resource
      {:ok, content2} = Client.read_resource(client, "file:///data.csv")
      resource2 = hd(content2.contents)
      assert resource2.text =~ "name,age"
      assert resource2.text =~ "Alice,30"
    end

    test "client can read binary resources", %{client: client} do
      {:ok, content} = Client.read_resource(client, "file:///image.png")
      resource = hd(content.contents)

      assert resource.uri == "file:///image.png"
      assert resource.mime_type == "image/png"
      # Base64 encoded
      assert resource.blob
      # Binary resources don't have text
      refute Map.has_key?(resource, :text)
    end

    test "read_resource returns error for unknown resource", %{client: client} do
      {:error, error} = Client.read_resource(client, "file:///unknown.txt")
      assert error.message =~ "Resource not found"
    end

    test "client can subscribe to resources", %{client: client} do
      # Subscribe to a resource
      {:ok, _result} = Client.subscribe_resource(client, "file:///config.json")

      # Subscribe to another resource
      {:ok, _result} = Client.subscribe_resource(client, "file:///data.csv")

      # Try to subscribe to non-existent resource
      {:error, error} = Client.subscribe_resource(client, "file:///nonexistent.txt")
      assert error.message =~ "Resource not found"
    end

    test "client can unsubscribe from resources", %{client: client} do
      # First subscribe
      {:ok, _} = Client.subscribe_resource(client, "file:///config.json")

      # Then unsubscribe
      {:ok, _result} = Client.unsubscribe_resource(client, "file:///config.json")

      # Unsubscribing from non-subscribed resource should still succeed
      {:ok, _result} = Client.unsubscribe_resource(client, "file:///data.csv")
    end

    test "client can list resource templates", %{client: client} do
      {:ok, result} = Client.list_resource_templates(client)
      templates = result.resourceTemplates

      assert length(templates) == 2

      file_template = Enum.find(templates, &(&1.uriTemplate == "file:///{path}"))
      assert file_template.name == "File Resource"
      assert file_template.mime_type == "text/plain"

      db_template = Enum.find(templates, &(&1.uriTemplate == "db://{table}/{id}"))
      assert db_template.name == "Database Record"
      assert db_template.description =~ "database records"
    end

    test "multiple resources can be read in sequence", %{client: client} do
      # Read all three resources
      {:ok, config} = Client.read_resource(client, "file:///config.json")
      {:ok, data} = Client.read_resource(client, "file:///data.csv")
      {:ok, image} = Client.read_resource(client, "file:///image.png")

      # Verify each has correct content type
      assert hd(config.contents).mime_type == "application/json"
      assert hd(data.contents).text =~ "name,age"
      # Binary data
      assert hd(image.contents).blob
    end
  end
end
