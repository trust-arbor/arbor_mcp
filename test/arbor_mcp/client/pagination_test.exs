defmodule Arbor.MCP.Client.PaginationTest do
  use ExUnit.Case, async: true
  alias Arbor.MCP.Client

  defmodule Pages do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, Map.new(opts)}

    def handle_call({:request, method, params, control}, _from, state) do
      send(state.owner, {:page_request, method, params, control})
      if state[:delay], do: Process.sleep(state.delay)
      [result | rest] = state.pages
      {:reply, result, %{state | pages: rest}}
    end
  end

  test "all four helpers follow opaque cursors and retain native or wire descriptors" do
    for {helper, method, field} <- [
          {:all_tools, "tools/list", :tools},
          {:all_resources, "resources/list", :resources},
          {:all_resource_templates, "resources/templates/list", :resourceTemplates},
          {:all_prompts, "prompts/list", :prompts}
        ] do
      first = %{"name" => "first", "extension" => %{"kept" => true}}
      second = %{name: "second"}

      client =
        client([
          {:ok, %{Atom.to_string(field) => [first], "nextCursor" => "opaque"}},
          {:ok, %{field => [second]}}
        ])

      assert {:ok, [^first, ^second]} = apply(Client, helper, [client])
      assert_receive {:page_request, ^method, %{}, first_control}
      assert_receive {:page_request, ^method, %{"cursor" => "opaque"}, second_control}
      assert first_control.deadline == second_control.deadline
    end
  end

  test "ordinary lists retain their first page and pagination metadata" do
    client = client([{:ok, %{"tools" => [], "nextCursor" => "next", "_meta" => %{"extra" => 1}}}])

    assert {:ok, %Arbor.MCP.Response{tools: [], nextCursor: "next", meta: %{"extra" => 1}}} =
             Client.list_tools(client)
  end

  test "page and item limits reject partial completion without another request" do
    for {opts, expected} <- [{[max_pages: 1], :max_pages}, {[max_items: 1], :max_items}] do
      page = %{"tools" => [%{"name" => "one"}, %{"name" => "two"}], "nextCursor" => "next"}
      client = client([{:ok, page}, {:ok, %{"tools" => []}}])
      assert {:error, {:pagination_limit, ^expected}} = Client.all_tools(client, opts)
      assert_receive {:page_request, "tools/list", %{}, _}
      refute_receive {:page_request, _, _, _}
    end
  end

  test "cumulative bytes include page metadata and stop at the limit" do
    first = %{
      "tools" => [],
      "nextCursor" => "next",
      "_meta" => %{"large" => String.duplicate("x", 100)}
    }

    second = %{"tools" => []}
    client = client([{:ok, first}, {:ok, second}])
    limit = :erlang.external_size(first) + :erlang.external_size(second) - 1
    assert {:error, {:pagination_limit, :max_bytes}} = Client.all_tools(client, max_bytes: limit)
  end

  test "cycles, including a repeated starting cursor, are rejected" do
    client = client([{:ok, %{"tools" => [], "nextCursor" => "start"}}])
    assert {:error, :pagination_cursor_cycle} = Client.all_tools(client, cursor: "start")
    assert_receive {:page_request, _, %{"cursor" => "start"}, _}
    refute_receive {:page_request, _, _, _}
  end

  test "malformed pages and peer errors are preserved without partial success" do
    for bad <- [%{}, %{"tools" => nil}, %{"tools" => [42]}, %{"tools" => [], "nextCursor" => 3}] do
      assert {:error, :invalid_pagination_page} = Client.all_tools(client([{:ok, bad}]))
    end

    assert {:error, :not_connected} = Client.all_tools(client([{:error, :not_connected}]))
  end

  test "one deadline covers every page" do
    client =
      client(
        [
          {:ok, %{"tools" => [], "nextCursor" => "next"}},
          {:ok, %{"tools" => []}}
        ],
        delay: 45
      )

    assert {:error, :timeout} = Client.all_tools(client, timeout: 70)
    assert_receive {:page_request, _, _, first}
    assert_receive {:page_request, _, _, second}
    assert first.deadline == second.deadline
    assert second.timeout < first.timeout
  end

  test "invalid bounds are rejected before IO" do
    client = client([])

    for opts <- [
          [timeout: :infinity],
          [max_pages: 0],
          [max_items: -1],
          [max_bytes: nil],
          [cursor: :atom],
          [format: :map]
        ] do
      assert_raise ArgumentError, fn -> Client.all_tools(client, opts) end
    end

    refute_receive {:page_request, _, _, _}
  end

  defp client(pages, opts \\ []) do
    start_supervised!({Pages, Keyword.merge([pages: pages, owner: self()], opts)}, id: make_ref())
  end
end
