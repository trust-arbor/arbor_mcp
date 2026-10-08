defmodule Arbor.MCP.UtilitiesTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule TestUtilitiesHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args) do
      {:ok,
       %{
         log_level: "info",
         tools: generate_many_tools(20),
         prompts: generate_many_prompts(15),
         resources: generate_many_resources(25)
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "test-utilities-server",
           version: "1.0.0"
         },
         capabilities: %{
           tools: %{},
           prompts: %{},
           resources: %{},
           completion: %{},
           logging: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(cursor, state) do
      case paginate_items(state.tools, cursor, 5) do
        {:ok, items, next_cursor, _} ->
          {:ok, items, next_cursor, state}

        {:error, reason, _} ->
          {:error, reason, state}
      end
    end

    @impl true
    def handle_call_tool(_name, _arguments, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_list_prompts(cursor, state) do
      case paginate_items(state.prompts, cursor, 3) do
        {:ok, items, next_cursor, _} ->
          {:ok, items, next_cursor, state}

        {:error, reason, _} ->
          {:error, reason, state}
      end
    end

    @impl true
    def handle_get_prompt(name, _arguments, state) do
      prompt = Enum.find(state.prompts, &(&1.name == name))

      if prompt do
        {:ok, [%{role: "user", content: %{type: "text", text: "Prompt: #{name}"}}], state}
      else
        {:error, "Prompt not found", state}
      end
    end

    @impl true
    def handle_list_resources(cursor, state) do
      case paginate_items(state.resources, cursor, 7) do
        {:ok, items, next_cursor, _} ->
          {:ok, items, next_cursor, state}

        {:error, reason, _} ->
          {:error, reason, state}
      end
    end

    @impl true
    def handle_read_resource(_uri, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_complete(ref, argument, state) do
      # Simulate completion based on ref type
      completions =
        case ref do
          %{"type" => "ref/prompt", "name" => prompt_name} ->
            generate_prompt_completions(prompt_name, argument, state)

          %{"type" => "ref/resource", "uri" => uri} ->
            generate_resource_completions(uri, argument, state)

          _ ->
            []
        end

      # Limit to max 100 as per spec
      limited = Enum.take(completions, 100)
      total = length(completions)

      result = %{
        completion: %{
          values: limited,
          total: total,
          hasMore: total > 100
        }
      }

      {:ok, result, state}
    end

    # Helper for pagination
    defp paginate_items(items, cursor, page_size) do
      case cursor do
        nil ->
          page = Enum.take(items, page_size)
          next_cursor = if length(items) > page_size, do: encode_cursor(page_size), else: nil
          {:ok, page, next_cursor, %{}}

        _ ->
          case decode_cursor(cursor) do
            {:ok, offset} ->
              remaining = Enum.drop(items, offset)
              page = Enum.take(remaining, page_size)

              next_cursor =
                if length(remaining) > page_size,
                  do: encode_cursor(offset + page_size),
                  else: nil

              {:ok, page, next_cursor, %{}}

            :error ->
              {:error, "Invalid cursor", %{}}
          end
      end
    end

    defp encode_cursor(offset) do
      Base.encode64("offset:#{offset}")
    end

    defp decode_cursor(cursor) do
      with {:ok, decoded} <- Base.decode64(cursor),
           "offset:" <> offset_str <- decoded,
           {offset, ""} <- Integer.parse(offset_str) do
        {:ok, offset}
      else
        _ -> :error
      end
    end

    defp generate_many_tools(count) do
      for i <- 1..count do
        %{
          name: "tool_#{i}",
          description: "Tool number #{i}",
          inputSchema: %{
            type: "object",
            properties: %{
              param: %{type: "string"}
            }
          }
        }
      end
    end

    defp generate_many_prompts(count) do
      for i <- 1..count do
        %{
          name: "prompt_#{i}",
          description: "Prompt number #{i}",
          arguments: [
            %{name: "arg1", required: true},
            %{name: "arg2", required: false}
          ]
        }
      end
    end

    defp generate_many_resources(count) do
      for i <- 1..count do
        %{
          uri: "file:///resource_#{i}.txt",
          name: "Resource #{i}",
          description: "Resource number #{i}"
        }
      end
    end

    defp generate_prompt_completions("prompt_1", %{"name" => "arg1", "value" => value}, _state) do
      # Simulate completions for arg1 of prompt_1
      base = ["option1", "option2", "option3", "option4", "option5"]
      filter_completions(base, value)
    end

    defp generate_prompt_completions(_, _, _), do: []

    defp generate_resource_completions("file:///", %{"name" => "path", "value" => value}, state) do
      # Get all resource URIs and extract paths
      paths =
        state.resources
        |> Enum.map(& &1.uri)
        |> Enum.map(&String.replace(&1, "file:///", ""))

      filter_completions(paths, value)
    end

    defp generate_resource_completions(_, _, _), do: []

    defp filter_completions(items, prefix) when is_binary(prefix) and prefix != "" do
      items
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()
    end

    defp filter_completions(items, _), do: Enum.sort(items)
  end

  setup do
    # Start server with utilities handler using BEAM transport
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: TestUtilitiesHandler
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

  describe "pagination" do
    test "tools pagination works correctly", %{client: client} do
      # First page
      {:ok, %{tools: page1, nextCursor: cursor1}} = Client.list_tools(client)
      assert length(page1) == 5
      assert cursor1 != nil
      assert Enum.at(page1, 0).name == "tool_1"

      # Second page
      {:ok, %{tools: page2, nextCursor: cursor2}} = Client.list_tools(client, cursor: cursor1)
      assert length(page2) == 5
      assert cursor2 != nil
      assert Enum.at(page2, 0).name == "tool_6"

      # Third page
      {:ok, %{tools: page3, nextCursor: cursor3}} = Client.list_tools(client, cursor: cursor2)
      assert length(page3) == 5
      assert Enum.at(page3, 0).name == "tool_11"

      # Fourth page (last page - 20 tools total)
      {:ok, result4} = Client.list_tools(client, cursor: cursor3)
      page4 = result4.tools
      cursor4 = result4[:nextCursor]
      assert length(page4) == 5
      assert Enum.at(page4, 0).name == "tool_16"

      # Last page should have no cursor
      assert cursor4 == nil
    end

    test "prompts pagination with different page size", %{client: client} do
      # Page size is 3 for prompts
      {:ok, %{prompts: page1, nextCursor: cursor1}} = Client.list_prompts(client)
      assert length(page1) == 3

      # Collect all prompts through pagination
      all_prompts = collect_all_pages(&Client.list_prompts/2, client, page1, cursor1, :prompts)
      assert length(all_prompts) == 15
      assert Enum.at(all_prompts, 0).name == "prompt_1"
      assert Enum.at(all_prompts, 14).name == "prompt_15"
    end

    test "resources pagination with larger page size", %{client: client} do
      # Page size is 7 for resources
      {:ok, %{resources: page1, nextCursor: cursor1}} = Client.list_resources(client)
      assert length(page1) == 7

      # Verify we can paginate through all resources
      all_resources =
        collect_all_pages(&Client.list_resources/2, client, page1, cursor1, :resources)

      assert length(all_resources) == 25
    end

    test "invalid cursor returns error", %{client: client} do
      invalid_cursor = Base.encode64("invalid")
      {:error, error} = Client.list_tools(client, cursor: invalid_cursor)
      assert error.message =~ "Invalid cursor"
    end
  end

  describe "completion" do
    test "prompt argument completion", %{client: client} do
      # Complete arg1 for prompt_1
      {:ok, result} =
        Client.complete(
          client,
          %{"type" => "ref/prompt", "name" => "prompt_1"},
          %{"name" => "arg1", "value" => "opt"}
        )

      completion = result.completion
      assert "option1" in completion.values
      assert "option2" in completion.values
      assert length(completion.values) >= 2
      assert completion.total >= 2
    end

    test "resource URI completion", %{client: client} do
      # Complete resource paths starting with "resource_1"
      {:ok, result} =
        Client.complete(
          client,
          %{"type" => "ref/resource", "uri" => "file:///"},
          %{"name" => "path", "value" => "resource_1"}
        )

      completion = result.completion
      # Should match resource_1.txt, resource_10.txt through resource_19.txt
      assert length(completion.values) == 11
      assert "resource_1.txt" in completion.values
      assert "resource_10.txt" in completion.values
    end

    test "completion with no matches", %{client: client} do
      {:ok, result} =
        Client.complete(
          client,
          %{"type" => "ref/prompt", "name" => "prompt_1"},
          %{"name" => "arg1", "value" => "xyz"}
        )

      assert result.completion.values == []
      assert result.completion.total == 0
      assert result.completion.hasMore == false
    end

    test "completion respects 100 item limit", %{client: client} do
      # Create a scenario that would return more than 100 items
      # (In this test it won't, but the handler implements the limit)
      {:ok, result} =
        Client.complete(
          client,
          %{"type" => "ref/resource", "uri" => "file:///"},
          %{"name" => "path", "value" => ""}
        )

      completion = result.completion
      assert length(completion.values) <= 100

      # If there were more than 100, hasMore would be true
      if completion.total > 100 do
        assert completion.hasMore == true
      end
    end
  end

  describe "logging" do
    test "client can send log messages", %{client: client} do
      # Send various log levels
      Client.log_message(client, "debug", "Debug message", %{extra: "data"})
      Client.log_message(client, "info", "Info message")
      Client.log_message(client, "warning", "Warning message", %{code: 123})
      Client.log_message(client, "error", "Error message", %{details: "Something went wrong"})

      # No errors should occur
      Process.sleep(50)
    end

    test "log message with different severity levels", %{client: client} do
      levels = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]

      for level <- levels do
        Client.log_message(client, level, "Test message at #{level} level")
      end

      Process.sleep(50)
    end
  end

  # Helper function to collect all pages
  defp collect_all_pages(list_fn, client, first_page, first_cursor, key) do
    collect_pages(list_fn, client, first_page, first_cursor, key, [])
  end

  defp collect_pages(list_fn, client, current_page, cursor, key, acc) do
    new_acc = acc ++ current_page

    case cursor do
      nil ->
        new_acc

      _ ->
        case list_fn.(client, cursor: cursor) do
          {:ok, result} ->
            next_page = Map.get(result, key, [])
            next_cursor = Map.get(result, :nextCursor)
            collect_pages(list_fn, client, next_page, next_cursor, key, new_acc)

          _ ->
            new_acc
        end
    end
  end
end
