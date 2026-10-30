defmodule Arbor.MCP.Client.ResponseCacheTest do
  @moduledoc """
  Like the TypeScript SDK's client, the client keeps a list page or a
  resource read for as long as the server said it stays fresh (`ttlMs`,
  2026-07-28), and a list change or resource update drops it.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.{Client, Server}

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    # Tells the test each time it's asked; "hold" waits to be released.
    @impl true
    def handle_list_tools(cursor, state) do
      send(state.owner, {:listed, cursor, self()})
      if cursor == "hold", do: receive(do: (:release -> :ok))
      {:ok, [%{name: "t", inputSchema: %{type: "object"}}], nil, state}
    end

    @impl true
    def handle_read_resource(uri, state) do
      send(state.owner, {:read, uri})
      {:ok, %{contents: [%{uri: uri, text: "x"}], ttl_ms: 60_000}, state}
    end
  end

  @hints %{"tools/list" => [ttl_ms: 60_000, cache_scope: :public]}

  defp connect(mode, opts \\ []) do
    {:ok, server} =
      Server.start_link(
        transport: :test,
        handler: Handler,
        handler_args: [owner: self()],
        cache_hints: Keyword.get(opts, :hints, @hints)
      )

    {:ok, client} =
      Client.start_link(
        [transport: :test, server: server, protocol_mode: mode, health_check_interval: nil] ++
          Keyword.get(opts, :client, [])
      )

    {client, server}
  end

  defp list(client, opts \\ []), do: Client.list_tools(client, [format: :map] ++ opts)

  test "a fresh list page is answered without asking the server again" do
    {client, _server} = connect(:modern_only)

    assert {:ok, first} = list(client)
    assert_received {:listed, nil, _}

    assert {:ok, ^first} = list(client)
    refute_received {:listed, _, _}
  end

  test "cache_mode: :refresh asks again and keeps the answer; :bypass asks and keeps nothing" do
    {client, _server} = connect(:modern_only)
    assert {:ok, _} = list(client)
    assert_received {:listed, nil, _}

    assert {:ok, _} = list(client, cache_mode: :refresh)
    assert_received {:listed, nil, _}

    assert {:ok, _} = list(client, cache_mode: :bypass)
    assert_received {:listed, nil, _}

    assert {:ok, _} = list(client)
    refute_received {:listed, _, _}
  end

  test "each page is kept under its cursor" do
    {client, _server} = connect(:modern_only)
    assert {:ok, _} = list(client)
    assert {:ok, _} = list(client, cursor: "two")
    assert_received {:listed, nil, _}
    assert_received {:listed, "two", _}

    assert {:ok, _} = list(client, cursor: "two")
    refute_received {:listed, _, _}
  end

  # The test is about expiry, so it waits past the TTL.
  test "an expired page is asked for again" do
    {client, _server} = connect(:modern_only, hints: %{"tools/list" => [ttl_ms: 50]})
    assert {:ok, _} = list(client)
    assert_received {:listed, nil, _}

    Process.sleep(80)
    assert {:ok, _} = list(client)
    assert_received {:listed, nil, _}
  end

  test "a resource read is kept under its URI" do
    {client, _server} = connect(:modern_only)

    assert {:ok, _} = Client.read_resource(client, "file:///a", format: :map)
    assert {:ok, _} = Client.read_resource(client, "file:///a", format: :map)
    assert {:ok, _} = Client.read_resource(client, "file:///b", format: :map)

    assert_received {:read, "file:///a"}
    assert_received {:read, "file:///b"}
    refute_received {:read, _}
  end

  test "without ttlMs nothing is kept, unless the client sets a default" do
    {client, _server} = connect(:legacy_only)
    assert {:ok, _} = list(client)
    assert {:ok, _} = list(client)
    assert_received {:listed, nil, _}
    assert_received {:listed, nil, _}

    {client, _server} = connect(:legacy_only, client: [default_cache_ttl_ms: 60_000])
    assert {:ok, _} = list(client)
    assert {:ok, _} = list(client)
    assert_received {:listed, nil, _}
    refute_received {:listed, _, _}
  end

  test "a disconnected client says so rather than answering from the cache" do
    {client, _server} = connect(:modern_only, client: [reconnect: false])
    assert {:ok, _} = list(client)
    :ok = Client.disconnect(client)

    assert {:error, _not_connected} = list(client)
  end

  test "response_cache: false keeps nothing" do
    {client, _server} = connect(:modern_only, client: [response_cache: false])
    assert {:ok, _} = list(client)
    assert {:ok, _} = list(client)
    assert_received {:listed, nil, _}
    assert_received {:listed, nil, _}
  end

  describe "invalidation" do
    setup do
      {client, server} = connect(:legacy_only, client: [default_cache_ttl_ms: 60_000])
      %{client: client, server: server}
    end

    test "a tools list change drops the kept pages", %{client: client, server: server} do
      assert {:ok, _} = list(client)
      assert_received {:listed, nil, _}

      :ok = Server.notify_tools_changed(server)
      # The notification is delivered before the answer to a later ping.
      assert {:ok, _} = Client.ping(client)

      assert {:ok, _} = list(client)
      assert_received {:listed, nil, _}
    end

    test "a change while a listing is in flight keeps its answer out of the cache",
         %{client: client, server: server} do
      task = Task.async(fn -> list(client, cursor: "hold") end)
      assert_receive {:listed, "hold", lister}

      :ok = Server.notify_tools_changed(server)
      assert {:ok, _} = Client.ping(client)
      send(lister, :release)
      assert {:ok, _} = Task.await(task)

      # Not kept, so the server is asked again.
      task = Task.async(fn -> list(client, cursor: "hold") end)
      assert_receive {:listed, "hold", lister}
      send(lister, :release)
      assert {:ok, _} = Task.await(task)
    end

    test "a resource update drops that resource only", %{client: client, server: server} do
      assert {:ok, _} = Client.read_resource(client, "file:///a", format: :map)
      assert {:ok, _} = Client.read_resource(client, "file:///b", format: :map)
      assert_received {:read, "file:///a"}
      assert_received {:read, "file:///b"}

      :ok = Server.notify_resource_update(server, "file:///a")
      assert {:ok, _} = Client.ping(client)

      assert {:ok, _} = Client.read_resource(client, "file:///a", format: :map)
      assert {:ok, _} = Client.read_resource(client, "file:///b", format: :map)
      assert_received {:read, "file:///a"}
      refute_received {:read, _}
    end
  end

  test "over modern HTTP too" do
    discover_hint = [ttl_ms: 300_000, cache_scope: :private]

    runtime =
      Arbor.MCP.Test.RuntimeHTTPFixture.start(Handler,
        handler_args: [owner: self()],
        protocol_mode: :modern_only,
        cache_hints: Map.put(@hints, "server/discover", discover_hint)
      )

    ref = {__MODULE__, make_ref()}
    port = free_port()

    {:ok, _listener} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [
          runtime: runtime,
          path: "/mcp",
          protocol_mode: :modern_only,
          allowed_origins: ["http://127.0.0.1:#{port}"]
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        health_check_interval: nil,
        reconnect: false
      )

    assert {:ok, %{"ttlMs" => 60_000, "cacheScope" => "public"}} = list(client)
    assert {:ok, _} = list(client)
    assert_received {:listed, nil, _}
    refute_received {:listed, _, _}

    # The result the server builds for discovery takes a hint as well.
    assert {:ok, %{"ttlMs" => 300_000, "cacheScope" => "private"}} = Client.discover(client)
  end

  test "invalid cache options are refused" do
    {client, _server} = connect(:modern_only)

    assert_raise ArgumentError, ~r/cache_mode/, fn -> list(client, cache_mode: :sometimes) end

    assert {:error, {:invalid_cache_hints, {:not_cacheable, "tools/call"}}} =
             Server.start_link(
               transport: :test,
               handler: Handler,
               handler_args: [owner: self()],
               cache_hints: %{"tools/call" => [ttl_ms: 1]}
             )

    assert {:error, {:invalid_cache_hints, {"tools/list", :ttl_ms}}} =
             Server.start_link(
               transport: :test,
               handler: Handler,
               handler_args: [owner: self()],
               cache_hints: %{"tools/list" => [ttl_ms: -1]}
             )
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
