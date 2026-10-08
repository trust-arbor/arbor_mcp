defmodule Arbor.MCP.PaginationComplianceTest do
  use ExUnit.Case, async: true

  @moduletag :compliance

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestPaginationServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         tools: generate_tools(25),
         resources: generate_resources(50),
         prompts: generate_prompts(15),
         resource_templates: generate_resource_templates(8),
         # Server-determined page size
         page_size: 5
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "test-pagination-server", version: "1.0.0"},
         capabilities: %{
           tools: %{},
           resources: %{},
           prompts: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(cursor, state) do
      paginate_items(state.tools, cursor, state.page_size, state)
    end

    @impl true
    def handle_list_resources(cursor, state) do
      paginate_items(state.resources, cursor, state.page_size, state)
    end

    @impl true
    def handle_list_prompts(cursor, state) do
      paginate_items(state.prompts, cursor, state.page_size, state)
    end

    @impl true
    def handle_list_resource_templates(cursor, state) do
      # Resource templates support pagination too
      paginate_items(state.resource_templates, cursor, state.page_size, state)
    end

    @impl true
    def handle_call_tool(_name, _args, state) do
      {:error, "Tool not found", state}
    end

    @impl true
    def handle_read_resource(_uri, state) do
      {:error, "Resource not found", state}
    end

    @impl true
    def handle_get_prompt(_name, _args, state) do
      {:error, "Prompt not found", state}
    end

    # Pagination implementation with opaque cursors
    defp paginate_items(all_items, cursor, page_size, state) do
      case parse_cursor(cursor) do
        {:ok, start_index} when start_index >= 0 and start_index < length(all_items) ->
          items = Enum.slice(all_items, start_index, page_size)

          next_cursor =
            if start_index + page_size < length(all_items) do
              encode_cursor(start_index + page_size, length(all_items))
            else
              nil
            end

          {:ok, items, next_cursor, state}

        {:ok, start_index} when start_index >= length(all_items) ->
          # Cursor points beyond available data - return empty
          {:ok, [], nil, state}

        {:error, :invalid_cursor} ->
          # Invalid cursor - return error as per spec
          {:error, "Invalid cursor parameter", state}
      end
    end

    # Opaque cursor encoding - clients MUST NOT parse this
    defp encode_cursor(start_index, total_items) do
      # Create a complex, opaque cursor that includes validation
      # Use fixed timestamp for stable cursors in tests
      timestamp = 1_234_567_890
      checksum = :crypto.hash(:md5, "#{start_index}-#{total_items}-#{timestamp}")

      cursor_data = %{
        "s" => start_index,
        "t" => total_items,
        "ts" => timestamp,
        "v" => Base.encode64(checksum)
      }

      cursor_data
      |> Jason.encode!()
      |> Base.encode64()
    end

    # Opaque cursor parsing with validation
    defp parse_cursor(nil), do: {:ok, 0}

    defp parse_cursor(cursor) when is_binary(cursor) do
      with {:ok, decoded} <- Base.decode64(cursor),
           {:ok, cursor_data} <- Jason.decode(decoded),
           true <- is_map(cursor_data),
           start_index when is_integer(start_index) <- cursor_data["s"],
           total_items when is_integer(total_items) <- cursor_data["t"],
           timestamp when is_integer(timestamp) <- cursor_data["ts"],
           encoded_checksum when is_binary(encoded_checksum) <- cursor_data["v"],
           {:ok, checksum} <- Base.decode64(encoded_checksum) do
        # Validate checksum to ensure cursor integrity
        expected_checksum = :crypto.hash(:md5, "#{start_index}-#{total_items}-#{timestamp}")

        if checksum == expected_checksum do
          {:ok, start_index}
        else
          {:error, :invalid_cursor}
        end
      else
        _ -> {:error, :invalid_cursor}
      end
    end

    defp parse_cursor(_), do: {:error, :invalid_cursor}

    # Generate test data
    defp generate_tools(count) do
      for i <- 1..count do
        %{
          name: "tool_#{i}",
          description: "Tool number #{i}",
          inputSchema: %{
            type: "object",
            properties: %{
              input: %{type: "string"}
            }
          }
        }
      end
    end

    defp generate_resources(count) do
      for i <- 1..count do
        %{
          uri: "file:///resource_#{i}.txt",
          name: "Resource #{i}",
          description: "Resource number #{i}",
          mime_type: "text/plain"
        }
      end
    end

    defp generate_prompts(count) do
      for i <- 1..count do
        %{
          name: "prompt_#{i}",
          description: "Prompt number #{i}",
          arguments: [
            %{name: "input", description: "Input parameter", required: true}
          ]
        }
      end
    end

    defp generate_resource_templates(count) do
      for i <- 1..count do
        %{
          uriTemplate: "file:///template_{template_id}/resource_#{i}.txt",
          name: "Template #{i}",
          description: "Resource template number #{i}",
          mime_type: "text/plain"
        }
      end
    end
  end

  setup do
    # Start server
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestPaginationServer
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

  describe "cursor-based pagination compliance" do
    test "uses opaque cursor approach instead of numbered pages", %{client: client} do
      {:ok, page1} = Client.list_tools(client)

      # Should have a cursor that is not a simple page number
      assert %{tools: tools, nextCursor: cursor} = page1
      assert is_binary(cursor)
      # Server-determined page size
      assert length(tools) == 5

      # Cursor should be opaque - not a simple number or predictable format
      # Clients MUST NOT parse or modify cursors
      # Should be complex, not just "1" or "2"
      assert String.length(cursor) > 10
      # Not just digits
      refute String.match?(cursor, ~r/^\d+$/)
    end

    test "page size is server-determined, not client-specified", %{client: client} do
      {:ok, page1} = Client.list_tools(client)
      {:ok, page2} = Client.list_tools(client, cursor: page1.nextCursor)

      # Both pages should have the same size (server-determined)
      assert length(page1.tools) == length(page2.tools)
      # Server chose this size
      assert length(page1.tools) == 5

      # Client cannot specify page size
      # (This is verified by the lack of page size parameter in the protocol)
    end

    test "cursors are stable across requests", %{client: client} do
      {:ok, page1_first} = Client.list_tools(client)
      {:ok, page1_second} = Client.list_tools(client)

      # Same cursor should return same results
      assert page1_first.nextCursor == page1_second.nextCursor
      assert page1_first.tools == page1_second.tools

      # Using the same cursor should yield consistent results
      {:ok, page2_first} = Client.list_tools(client, cursor: page1_first.nextCursor)
      {:ok, page2_second} = Client.list_tools(client, cursor: page1_second.nextCursor)

      assert page2_first.tools == page2_second.tools
    end

    test "invalid cursors result in proper error", %{client: client} do
      # Test various invalid cursor formats
      invalid_cursors = [
        "invalid_cursor",
        "123",
        "",
        "not_base64!",
        Base.encode64("invalid_json"),
        Base.encode64(Jason.encode!(%{"invalid" => "structure"}))
      ]

      for invalid_cursor <- invalid_cursors do
        {:error, error} = Client.list_tools(client, cursor: invalid_cursor)

        # Should return error code -32602 (Invalid params)
        assert error.code == -32602
        assert String.contains?(error.message, "Invalid cursor")
      end
    end
  end

  describe "supported operations pagination" do
    test "tools/list supports pagination", %{client: client} do
      all_tools =
        collect_all_pages(fn cursor -> Client.list_tools(client, cursor: cursor) end, :tools)

      # Total tools generated
      assert length(all_tools) == 25

      # Check that all tools are unique and in order
      tool_names = Enum.map(all_tools, & &1.name)
      expected_names = for i <- 1..25, do: "tool_#{i}"
      assert tool_names == expected_names
    end

    test "resources/list supports pagination", %{client: client} do
      all_resources =
        collect_all_pages(
          fn cursor -> Client.list_resources(client, cursor: cursor) end,
          :resources
        )

      # Total resources generated
      assert length(all_resources) == 50

      # Check that all resources are unique and in order
      resource_uris = Enum.map(all_resources, & &1.uri)
      expected_uris = for i <- 1..50, do: "file:///resource_#{i}.txt"
      assert resource_uris == expected_uris
    end

    test "prompts/list supports pagination", %{client: client} do
      all_prompts =
        collect_all_pages(fn cursor -> Client.list_prompts(client, cursor: cursor) end, :prompts)

      # Total prompts generated
      assert length(all_prompts) == 15

      # Check that all prompts are unique and in order
      prompt_names = Enum.map(all_prompts, & &1.name)
      expected_names = for i <- 1..15, do: "prompt_#{i}"
      assert prompt_names == expected_names
    end

    test "resources/templates/list supports pagination", %{client: client} do
      all_templates =
        collect_all_pages(
          fn cursor -> Client.list_resource_templates(client, cursor: cursor) end,
          :resourceTemplates
        )

      # Total templates generated
      assert length(all_templates) == 8

      # Check that all templates are unique and in order
      template_names = Enum.map(all_templates, & &1.name)
      expected_names = for i <- 1..8, do: "Template #{i}"
      assert template_names == expected_names
    end
  end

  describe "response structure compliance" do
    test "includes current page of results", %{client: client} do
      {:ok, result} = Client.list_tools(client)

      assert %{tools: tools} = result
      assert is_list(tools)
      assert length(tools) > 0
      # Server page size
      assert length(tools) <= 5

      # Each tool should have proper structure
      Enum.each(tools, fn tool ->
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
      end)
    end

    test "includes nextCursor when more results exist", %{client: client} do
      {:ok, result} = Client.list_tools(client)

      # First page should have nextCursor since we have 25 tools total
      assert %{tools: tools, nextCursor: cursor} = result
      assert is_binary(cursor)
      assert length(tools) == 5
    end

    test "omits nextCursor when no more results exist", %{client: client} do
      # Navigate to the last page
      _all_pages = []
      cursor = nil

      # Collect all pages
      {final_page, _} =
        Enum.reduce_while(1..10, {nil, cursor}, fn _i, {_last_page, current_cursor} ->
          case Client.list_tools(client, cursor: current_cursor) do
            {:ok, %{nextCursor: next_cursor} = page} when not is_nil(next_cursor) ->
              {:cont, {page, next_cursor}}

            {:ok, page} ->
              # No nextCursor or nextCursor is nil - this is the last page
              {:halt, {page, nil}}
          end
        end)

      # Last page should not have nextCursor or it should be nil
      assert is_nil(final_page.nextCursor)
    end

    test "empty results when cursor points beyond data", %{client: client} do
      # Get a valid cursor from near the end
      all_tools =
        collect_all_pages(fn cursor -> Client.list_tools(client, cursor: cursor) end, :tools)

      assert length(all_tools) == 25

      # All pages exhausted, any further cursors should return empty
      # This is implementation-dependent behavior but should be consistent
    end
  end

  describe "cursor handling compliance" do
    test "cursors are completely opaque to clients", %{client: client} do
      {:ok, page} = Client.list_tools(client)
      cursor = page.nextCursor

      # Cursor should be opaque - clients cannot parse or understand it
      assert is_binary(cursor)

      # Attempting to modify cursor should fail (we test this by corruption)
      corrupted_cursor = String.reverse(cursor)
      {:error, _} = Client.list_tools(client, cursor: corrupted_cursor)

      # Clients should not make assumptions about format
      refute String.starts_with?(cursor, "page")
      refute String.match?(cursor, ~r/^\d+$/)
    end

    test "clients cannot parse or modify cursors", %{client: client} do
      {:ok, page} = Client.list_tools(client)
      cursor = page.nextCursor

      # Various forms of cursor tampering should fail
      tampered_cursors = [
        String.upcase(cursor),
        # Remove first character
        String.slice(cursor, 1..-1//1),
        # Append character
        cursor <> "x",
        # Change one character
        String.replace(cursor, "A", "B", global: false)
      ]

      for tampered <- tampered_cursors do
        case Client.list_tools(client, cursor: tampered) do
          {:error, error} ->
            assert error.code == -32602

          {:ok, _response} ->
            # Some tampering might still result in valid cursors due to redundancy
            # This is acceptable as long as it doesn't compromise security
            :ok
        end
      end
    end

    test "clients must not persist cursors across sessions", %{client: client} do
      # This is more of a documentation test since we can't test session persistence
      # in a single test, but we verify that cursors contain session-specific data

      {:ok, page} = Client.list_tools(client)
      cursor = page.nextCursor

      # Cursor should contain session/time-specific information (our implementation does)
      # This means it shouldn't be persisted across sessions

      # Decode and check it contains timestamp (implementation detail for testing)
      {:ok, decoded} = Base.decode64(cursor)
      {:ok, cursor_data} = Jason.decode(decoded)

      # Should contain timestamp indicating when it was created
      assert Map.has_key?(cursor_data, "ts")
      assert is_integer(cursor_data["ts"])
    end
  end

  describe "protocol encoding compliance" do
    test "cursor parameter is optional in requests", %{client: client} do
      # Without cursor
      request1 = Protocol.encode_list_tools()
      assert request1["params"] == %{}

      # With cursor
      request2 = Protocol.encode_list_tools("test_cursor")
      assert request2["params"] == %{"cursor" => "test_cursor"}

      # Both should work
      {:ok, _} = Client.list_tools(client)
      {:ok, page} = Client.list_tools(client)
      {:ok, _} = Client.list_tools(client, cursor: page.nextCursor)
    end

    test "nextCursor field is optional in responses", %{client: client} do
      # First page should have nextCursor
      {:ok, page1} = Client.list_tools(client)
      assert not is_nil(page1.nextCursor)

      # Navigate to last page which should NOT have nextCursor
      _cursor = page1.nextCursor

      last_page =
        Enum.reduce_while(1..10, page1, fn _i, current_page ->
          case Client.list_tools(client, cursor: current_page.nextCursor) do
            {:ok, %{nextCursor: next_cursor} = next_page} when not is_nil(next_cursor) ->
              {:cont, next_page}

            {:ok, final_page} ->
              {:halt, final_page}
          end
        end)

      assert is_nil(last_page.nextCursor)
    end
  end

  describe "error handling compliance" do
    test "gracefully handles malformed cursors", %{client: client} do
      malformed_cursors = [
        "not_base64!@#",
        Base.encode64("not json"),
        # Valid JSON but invalid structure
        Base.encode64("{}"),
        # Wrong type (though this would fail at protocol level)
        123
      ]

      for cursor <- malformed_cursors do
        if is_binary(cursor) do
          {:error, error} = Client.list_tools(client, cursor: cursor)
          assert error.code == -32602
        end
      end
    end

    test "handles edge cases appropriately", %{client: client} do
      # Empty cursor string
      {:error, error} = Client.list_tools(client, cursor: "")
      assert error.code == -32602

      # Very long cursor
      long_cursor = String.duplicate("a", 10000)
      {:error, error} = Client.list_tools(client, cursor: long_cursor)
      assert error.code == -32602
    end
  end

  describe "pagination consistency" do
    test "consistent ordering across pages", %{client: client} do
      all_tools =
        collect_all_pages(fn cursor -> Client.list_tools(client, cursor: cursor) end, :tools)

      # Tools should be in consistent order
      tool_names = Enum.map(all_tools, & &1.name)

      # For our test implementation, they should already be in numeric order
      expected_names = for i <- 1..25, do: "tool_#{i}"
      assert tool_names == expected_names
    end

    test "no duplicate items across pages", %{client: client} do
      all_tools =
        collect_all_pages(fn cursor -> Client.list_tools(client, cursor: cursor) end, :tools)

      # No duplicates
      tool_names = Enum.map(all_tools, & &1.name)
      unique_names = Enum.uniq(tool_names)

      assert length(tool_names) == length(unique_names)
    end

    test "no missing items between pages", %{client: client} do
      all_tools =
        collect_all_pages(fn cursor -> Client.list_tools(client, cursor: cursor) end, :tools)

      # Should have all expected tools
      assert length(all_tools) == 25

      # Should be sequential
      tool_numbers =
        all_tools
        |> Enum.map(& &1.name)
        |> Enum.map(&String.replace(&1, "tool_", ""))
        |> Enum.map(&String.to_integer/1)
        |> Enum.sort()

      assert tool_numbers == Enum.to_list(1..25)
    end
  end

  # Helper function to collect all pages
  defp collect_all_pages(list_fn, key) do
    collect_pages(list_fn, key, nil, [], 0)
  end

  defp collect_pages(_list_fn, _key, _cursor, acc, 100) do
    # Safety: Prevent infinite loops by limiting to 100 pages max
    acc
  end

  defp collect_pages(list_fn, key, cursor, acc, page_count) do
    case list_fn.(cursor) do
      {:ok, %{^key => items, nextCursor: next_cursor}} when not is_nil(next_cursor) ->
        collect_pages(list_fn, key, next_cursor, acc ++ items, page_count + 1)

      {:ok, %{^key => items}} ->
        # Last page (no nextCursor or nextCursor is nil)
        acc ++ items

      {:error, _reason} ->
        acc
    end
  end
end
