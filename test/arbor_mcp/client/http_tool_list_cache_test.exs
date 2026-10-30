defmodule Arbor.MCP.Client.HTTPToolListCacheTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  @moduletag :capture_log

  setup do
    bypass = Bypass.open()
    owner = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond(conn, Jason.decode!(body), owner)
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        use_sse: false,
        protocol_mode: :modern_only,
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    %{client: client}
  end

  test "a cursor returned by a late older first page retains its original listing", %{
    client: client
  } do
    old = start_page(client)
    fresh = start_page(client)
    finish_page(fresh, ["fresh"], %{"nextCursor" => "fresh-next"})
    finish_page(old, ["old"], %{"nextCursor" => "old-next"})

    old_cursor = start_page(client, cursor: "old-next")
    finish_page(old_cursor, ["old-cursor"])
    assert_cache(client, ["fresh"])

    fresh_cursor = start_page(client, cursor: "fresh-next")
    finish_page(fresh_cursor, ["fresh-cursor"])
    assert_cache(client, ["fresh", "fresh-cursor"])
    assert_mirrored_header(client, "fresh-cursor")
  end

  test "a reused cursor belongs to the newest listing that issued it", %{
    client: client
  } do
    old = start_page(client)
    fresh = start_page(client)
    finish_page(fresh, ["fresh"], %{"nextCursor" => "shared"})
    finish_page(old, ["old"], %{"nextCursor" => "shared"})

    cursor = start_page(client, cursor: "shared")
    finish_page(cursor, ["fresh-cursor"], %{"nextCursor" => "descendant"})
    descendant = start_page(client, cursor: "descendant")
    finish_page(descendant, ["fresh-descendant"])
    assert_cache(client, ["fresh", "fresh-cursor", "fresh-descendant"])
    assert_mirrored_header(client, "fresh")
  end

  for missing <- ["resultType", "ttlMs"] do
    test "a rejected page missing #{missing} cannot change the cache", %{client: client} do
      fresh = start_page(client)
      finish_page(fresh, ["fresh"])

      {task, handler} = start_page(client)
      send(handler, {:respond_invalid, unquote(missing)})
      assert {:error, _} = Task.await(task, 5_000)
      assert_cache(client, ["fresh"])
      assert_mirrored_header(client, "fresh")
    end
  end

  test "an invalid JSON-RPC envelope cannot change the cache", %{client: client} do
    fresh = start_page(client)
    finish_page(fresh, ["fresh"])

    {task, handler} = start_page(client)
    send(handler, :respond_invalid_rpc)

    Arbor.MCP.TestHelpers.wait_until(fn ->
      map_size(:sys.get_state(client).async_post_tasks) == 0
    end)

    assert_cache(client, ["fresh"])
    [id] = Client.get_pending_requests(client)
    assert :ok = Client.send_cancelled(client, id, "invalid response")
    assert {:error, :cancelled} = Task.await(task, 5_000)
    assert_mirrored_header(client, "fresh")
  end

  for order <- [[:first, :cursor], [:cursor, :first]] do
    test "pages completing in #{inspect(order)} order keep both tools and mirror their headers",
         %{
           client: client
         } do
      old = start_page(client)
      finish_page(old, ["old"])
      assert_cache(client, ["old"])

      first = start_page(client)
      cursor = start_page(client, cursor: "next")
      pages = %{first: first, cursor: cursor}

      for page <- unquote(order), do: finish_page(pages[page], [Atom.to_string(page)])

      assert_cache(client, ["cursor", "first"])
      assert_mirrored_header(client, "first")
      assert_mirrored_header(client, "cursor")
    end
  end

  for stale_page <- [:first, :cursor] do
    test "an older listing's #{stale_page} completion cannot replace a newer cache", %{
      client: client
    } do
      old_first = start_page(client)
      old_cursor = start_page(client, cursor: "old-next")
      pages = %{first: old_first, cursor: old_cursor}
      early_page = if unquote(stale_page) == :first, do: :cursor, else: :first
      finish_page(pages[early_page], ["old-early"])

      fresh = start_page(client)
      finish_page(fresh, ["fresh"])
      assert_cache(client, ["fresh"])

      finish_page(pages[unquote(stale_page)], ["stale"])
      assert_cache(client, ["fresh"])
      assert_mirrored_header(client, "fresh")
    end
  end

  defp start_page(client, opts \\ []) do
    task = Task.async(fn -> Client.list_tools(client, opts ++ [timeout: 5_000]) end)
    assert_receive {:page_started, handler}, 2_000
    {task, handler}
  end

  defp finish_page({task, handler}, names, fields \\ %{}) do
    send(handler, {:respond, names, fields})
    assert {:ok, _} = Task.await(task, 5_000)
  end

  defp assert_cache(client, names) do
    assert client
           |> :sys.get_state()
           |> Map.fetch!(:transport_state)
           |> Map.fetch!(:tool_headers)
           |> Map.keys()
           |> Enum.sort() == Enum.sort(names)
  end

  defp assert_mirrored_header(client, name) do
    assert {:ok, _} = Client.call_tool(client, name, %{"route" => name}, timeout: 5_000)
    assert_receive {:tool_headers, ^name, [^name]}
  end

  defp respond(conn, %{"method" => "server/discover", "id" => id}, _owner) do
    result =
      Arbor.MCP.Server.Discover.build(
        %{"name" => "cache-ordering", "version" => "1"},
        %{"tools" => %{}},
        protocol_mode: :modern_only
      )

    json(conn, id, result)
  end

  defp respond(conn, %{"method" => "tools/list", "id" => id}, owner) do
    send(owner, {:page_started, self()})

    receive do
      {:respond, names, fields} ->
        result = %{
          "tools" => Enum.map(names, &tool/1),
          "ttlMs" => 0,
          "cacheScope" => "private"
        }

        json(conn, id, Map.merge(result, fields))

      {:respond_invalid, missing} ->
        result = %{
          "tools" => [tool("invalid")],
          "resultType" => "complete",
          "ttlMs" => 0,
          "cacheScope" => "private"
        }

        json_response(conn, id, Map.delete(result, missing))

      :respond_invalid_rpc ->
        body = %{
          "jsonrpc" => "1.0",
          "id" => id,
          "result" => %{
            "resultType" => "complete",
            "tools" => [tool("invalid")],
            "ttlMs" => 0,
            "cacheScope" => "private"
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
    after
      10_000 -> Plug.Conn.resp(conn, 500, "test page not released")
    end
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, owner) do
    send(
      owner,
      {:tool_headers, params["name"], Plug.Conn.get_req_header(conn, "mcp-param-route")}
    )

    json(conn, id, %{"content" => []})
  end

  defp respond(conn, _notification, _owner), do: Plug.Conn.resp(conn, 202, "")

  defp tool(name) do
    %{
      "name" => name,
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"route" => %{"type" => "string", "x-mcp-header" => "Route"}}
      }
    }
  end

  defp json(conn, id, result) do
    json_response(conn, id, Map.put(result, "resultType", "complete"))
  end

  defp json_response(conn, id, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => result
      })
    )
  end
end
