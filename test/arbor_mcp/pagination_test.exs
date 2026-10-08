defmodule Arbor.MCP.PaginationTest do
  use ExUnit.Case, async: true

  @moduletag :resources

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestPaginationHandler do
    use Arbor.MCP.Server.Handler

    @items_per_page 3

    @impl true
    def handle_initialize(params, state) do
      # Accept client's version if supported, otherwise use latest
      client_version = params["protocolVersion"]

      negotiated_version =
        case client_version do
          "2025-03-26" -> "2025-03-26"
          "2024-11-05" -> "2024-11-05"
          # Default to latest
          _ -> "2025-03-26"
        end

      result = %{
        protocolVersion: negotiated_version,
        serverInfo: %{
          name: "test-pagination-server",
          version: "1.0.0"
        },
        capabilities: %{
          tools: %{},
          resources: %{},
          prompts: %{}
        }
      }

      {:ok, result, state}
    end

    @impl true
    def handle_list_tools(cursor, state) do
      all_tools = [
        %{name: "tool1", description: "First tool"},
        %{name: "tool2", description: "Second tool"},
        %{name: "tool3", description: "Third tool"},
        %{name: "tool4", description: "Fourth tool"},
        %{name: "tool5", description: "Fifth tool"},
        %{name: "tool6", description: "Sixth tool"},
        %{name: "tool7", description: "Seventh tool"}
      ]

      {tools, next_cursor} = paginate_items(all_tools, cursor, @items_per_page)
      {:ok, tools, next_cursor, state}
    end

    @impl true
    def handle_list_resources(cursor, state) do
      all_resources = [
        %{uri: "file:///1", name: "Resource 1"},
        %{uri: "file:///2", name: "Resource 2"},
        %{uri: "file:///3", name: "Resource 3"},
        %{uri: "file:///4", name: "Resource 4"},
        %{uri: "file:///5", name: "Resource 5"}
      ]

      {resources, next_cursor} = paginate_items(all_resources, cursor, @items_per_page)
      {:ok, resources, next_cursor, state}
    end

    @impl true
    def handle_list_prompts(cursor, state) do
      all_prompts = [
        %{name: "prompt1", description: "First prompt"},
        %{name: "prompt2", description: "Second prompt"},
        %{name: "prompt3", description: "Third prompt"},
        %{name: "prompt4", description: "Fourth prompt"}
      ]

      {prompts, next_cursor} = paginate_items(all_prompts, cursor, @items_per_page)
      {:ok, prompts, next_cursor, state}
    end

    defp paginate_items(all_items, cursor, per_page) do
      start_index = parse_cursor(cursor)
      items = Enum.slice(all_items, start_index, per_page)

      next_cursor =
        if start_index + per_page < length(all_items) do
          encode_cursor(start_index + per_page)
        else
          nil
        end

      {items, next_cursor}
    end

    defp parse_cursor(nil), do: 0

    defp parse_cursor(cursor) do
      case Base.decode64(cursor) do
        {:ok, decoded} -> String.to_integer(decoded)
        _ -> 0
      end
    end

    defp encode_cursor(index) do
      Base.encode64(to_string(index))
    end

    # Required callbacks that aren't used in this test
    @impl true
    def handle_call_tool(_name, _arguments, state) do
      {:error, %{"code" => -32601, "message" => "Tool not found"}, state}
    end

    @impl true
    def handle_read_resource(_uri, state) do
      {:error, %{"code" => -32602, "message" => "Resource not found"}, state}
    end

    @impl true
    def handle_get_prompt(_name, _arguments, state) do
      {:error, %{"code" => -32602, "message" => "Prompt not found"}, state}
    end

    @impl true
    def handle_complete(_ref, _argument, state) do
      {:ok, %{completion: []}, state}
    end

    @impl true
    def handle_list_resource_templates(_cursor, state) do
      {:ok, [], nil, state}
    end

    @impl true
    def handle_subscribe_resource(_uri, state) do
      {:ok, %{}, state}
    end

    @impl true
    def handle_unsubscribe_resource(_uri, state) do
      {:ok, %{}, state}
    end

    @impl true
    def handle_create_message(_params, state) do
      {:error, %{"code" => -32601, "message" => "Create message not supported"}, state}
    end

    @impl true
    def handle_list_roots(state) do
      {:ok, [], state}
    end
  end

  describe "pagination support" do
    setup do
      {:ok, server} =
        Server.start_link(
          handler: TestPaginationHandler,
          transport: :test
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Wait for initialization
      Process.sleep(100)

      {:ok, server: server, client: client}
    end

    test "list_tools supports pagination", %{client: client} do
      # First page
      assert {:ok, %{tools: tools1, nextCursor: cursor1}} = Client.list_tools(client)
      assert length(tools1) == 3
      assert [%{name: "tool1"}, %{name: "tool2"}, %{name: "tool3"}] = tools1
      assert cursor1 != nil

      # Second page
      assert {:ok, %{tools: tools2, nextCursor: cursor2}} =
               Client.list_tools(client, cursor: cursor1)

      assert length(tools2) == 3
      assert [%{name: "tool4"}, %{name: "tool5"}, %{name: "tool6"}] = tools2
      assert cursor2 != nil

      # Third page - last page should not have nextCursor
      assert {:ok, result3} = Client.list_tools(client, cursor: cursor2)
      assert %{tools: tools3} = result3
      assert length(tools3) == 1
      assert [%{name: "tool7"}] = tools3
      # No more pages
      assert result3.nextCursor == nil
    end

    test "list_resources supports pagination", %{client: client} do
      # First page
      assert {:ok, %{resources: resources1, nextCursor: cursor1}} = Client.list_resources(client)
      assert length(resources1) == 3
      assert [%{uri: "file:///1"}, %{uri: "file:///2"}, %{uri: "file:///3"}] = resources1
      assert cursor1 != nil

      # Second page - last page should not have nextCursor
      assert {:ok, result2} = Client.list_resources(client, cursor: cursor1)
      assert %{resources: resources2} = result2
      assert length(resources2) == 2
      assert [%{uri: "file:///4"}, %{uri: "file:///5"}] = resources2
      # No more pages
      assert result2.nextCursor == nil
    end

    test "list_prompts supports pagination", %{client: client} do
      # First page
      assert {:ok, %{prompts: prompts1, nextCursor: cursor1}} = Client.list_prompts(client)
      assert length(prompts1) == 3
      assert [%{name: "prompt1"}, %{name: "prompt2"}, %{name: "prompt3"}] = prompts1
      assert cursor1 != nil

      # Second page - last page should not have nextCursor
      assert {:ok, result2} = Client.list_prompts(client, cursor: cursor1)
      assert %{prompts: prompts2} = result2
      assert length(prompts2) == 1
      assert [%{name: "prompt4"}] = prompts2
      # No more pages
      assert result2.nextCursor == nil
    end

    test "pagination with nil cursor starts from beginning", %{client: client} do
      assert {:ok, %{tools: tools1}} = Client.list_tools(client)
      assert {:ok, %{tools: tools2}} = Client.list_tools(client, cursor: nil)
      assert tools1 == tools2
    end

    test "invalid cursor is handled gracefully", %{client: client} do
      # Should start from beginning with invalid cursor
      assert {:ok, %{tools: tools}} = Client.list_tools(client, cursor: "invalid-cursor")
      assert length(tools) == 3
      assert [%{name: "tool1"}, %{name: "tool2"}, %{name: "tool3"}] = tools
    end
  end

  describe "protocol encoding" do
    test "encode_list_tools includes cursor parameter when provided" do
      request = Protocol.encode_list_tools("cursor123")
      assert request["params"]["cursor"] == "cursor123"
    end

    test "encode_list_tools omits cursor when nil" do
      request = Protocol.encode_list_tools()
      assert request["params"] == %{}
    end

    test "encode_list_resources includes cursor parameter when provided" do
      request = Protocol.encode_list_resources("cursor456")
      assert request["params"]["cursor"] == "cursor456"
    end

    test "encode_list_prompts includes cursor parameter when provided" do
      request = Protocol.encode_list_prompts("cursor789")
      assert request["params"]["cursor"] == "cursor789"
    end
  end
end
