defmodule Arbor.MCP.Server.Runtime.HTTPCutoverTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError
  alias Arbor.MCP.Server.{Context, Subscriptions}
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry}

  @server_owners [
    Arbor.MCP.Server.ReplayCache.ETS,
    Arbor.MCP.Tasks.Store.ETS,
    Subscriptions,
    Arbor.MCP.HttpPlug.SessionRegistry,
    Arbor.MCP.Server.Cancellation,
    Arbor.MCP.SubscriptionRegistry,
    Arbor.MCP.SessionManager,
    Arbor.MCP.ProgressTracker
  ]

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def init(opts) do
      send(opts[:observer], {:handler_initialized, self()})
      {:ok, %{observer: opts[:observer], count: 0, listings: 0}}
    end

    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ["count", "publish"],
            do: %{"name" => name, "inputSchema" => %{"type" => "object"}}

      tool = %{
        "name" => "header",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"token" => %{"type" => "string", "x-mcp-header" => "Token"}}
        }
      }

      {:ok, [tool | tools], nil, %{state | listings: state.listings + 1}}
    end

    def handle_call_tool("count", _args, state) do
      {:ok,
       %{
         "content" => [],
         "structuredContent" => %{
           "count" => state.count + 1,
           "context" => Context.current().application_context
         }
       }, %{state | count: state.count + 1}}
    end

    def handle_call_tool("header", _args, state) do
      send(state.observer, {:header_callback, state.listings})

      {:ok,
       %{
         "content" => [],
         "structuredContent" => %{"count" => state.count + 1, "listings" => state.listings}
       }, %{state | count: state.count + 1}}
    end

    def handle_call_tool("publish", args, state) do
      result = Subscriptions.publish("notifications/resources/updated", args)
      send(state.observer, {:publication, args["uri"], result})
      {:ok, %{"content" => []}, state}
    end
  end

  defmodule RecordingAdapter do
    alias Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Conn
    defdelegate send_resp(state, status, headers, body), to: Conn
    defdelegate send_chunked(state, status, headers), to: Conn

    def chunk(state, wire) do
      wire = IO.iodata_to_binary(wire)
      send(state.observer, {:wire, self(), wire})

      state =
        if wire == ":\r\n\r\n" and state.hold do
          send(state.observer, {:held_keepalive, self()})
          receive do: (:return_io -> :ok)
          %{state | hold: false}
        else
          state
        end

      Conn.chunk(state, wire)
    end
  end

  test "application boot has no implicit server owners and rejected mounts have no effects" do
    for owner <- @server_owners, do: assert(is_nil(Process.whereis(owner)))
    assert_raise ArgumentError, ~r/requires.*runtime/, fn -> HttpPlug.init([]) end

    for key <- [
          :handler,
          :handler_args,
          :handler_call_timeout,
          :server,
          :session_manager,
          :session_store,
          :subscription_registry,
          :replay_cache,
          :sse_enabled,
          :use_sse
        ] do
      assert_raise ArgumentError, ~r/retired/, fn ->
        HttpPlug.init([{key, Handler}, runtime: :not_started])
      end
    end

    refute_receive {:handler_initialized, _}, 5
    for owner <- @server_owners, do: assert(is_nil(Process.whereis(owner)))
  end

  test "call also rejects a caller-crafted missing runtime before body or fallback execution" do
    conn = Plug.Test.conn(:post, "/mcp", "not JSON")

    assert_raise ArgumentError, ~r/requires.*runtime/, fn ->
      HttpPlug.call(conn, %{runtime: nil})
    end

    assert_raise ArgumentError, ~r/requires.*runtime/, fn ->
      HttpPlug.RuntimeWriter.capture(conn, nil)
    end

    refute_receive {:handler_initialized, _}, 5
  end

  test "named mounts compile before their runtime exists and unavailable roots fail closed" do
    opts = HttpPlug.init(runtime: HTTPCutoverTest.Unstarted)

    assert_raise AdmissionError, fn ->
      HttpPlug.call(Plug.Test.conn(:post, "/mcp", "{}"), opts)
    end

    for owner <- @server_owners, do: assert(is_nil(Process.whereis(owner)))
  end

  test "retired named and captured Ref mounts share the same unavailable error without fallback IO" do
    name = HTTPCutoverTest.Retiring

    root =
      start_supervised!(
        Supervisor.child_spec(
          {Runtime,
           name: name,
           handler: Handler,
           handler_args: [observer: self()],
           transport: :mounted_http},
          restart: :temporary
        ),
        id: make_ref()
      )

    {:ok, runtime} = Runtime.ref(root)

    named = HttpPlug.init(runtime: name)
    captured = HttpPlug.init(runtime: runtime)
    assert_receive {:handler_initialized, _}
    assert :ok = Runtime.stop(runtime)

    for options <- [named, captured] do
      error =
        assert_raise AdmissionError, fn ->
          HttpPlug.call(Plug.Test.conn(:post, "/mcp", "not JSON"), options)
        end

      assert error == %AdmissionError{}
    end

    assert_raise ArgumentError, ~r/reference is unavailable/, fn ->
      HttpPlug.init(runtime: runtime)
    end

    refute_receive {:handler_initialized, _}, 5
    for owner <- @server_owners, do: assert(is_nil(Process.whereis(owner)))
  end

  test "POSTs share one handler initialization and state while sibling equal ids stay isolated" do
    runtime = runtime()
    sibling = runtime()
    assert_receive {:handler_initialized, _}
    assert_receive {:handler_initialized, _}
    opts = [handler_opts: fn _conn, _request -> %{"source" => "mount"} end]
    first = request(runtime, tool("count", %{}, 1), opts)
    second = request(runtime, tool("count", %{}, 1), opts)
    other = request(sibling, tool("count", %{}, 1), opts)

    assert get_in(Jason.decode!(first.resp_body), ["result", "structuredContent"]) == %{
             "count" => 1,
             "context" => %{"source" => "mount"}
           }

    assert get_in(Jason.decode!(second.resp_body), ["result", "structuredContent", "count"]) == 2
    assert get_in(Jason.decode!(other.resp_body), ["result", "structuredContent", "count"]) == 1
    refute_receive {:handler_initialized, _}, 5
  end

  test "HTTP tool headers reject before the callback and commit only the valid serialized list state" do
    runtime = runtime()
    assert_receive {:handler_initialized, _}
    message = tool("header", %{"token" => "route"}, 7)
    rejected = request(runtime, message)
    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32020
    refute_receive {:header_callback, _}, 5

    opts = HttpPlug.init(runtime: runtime, protocol_mode: :modern_only)

    accepted =
      connection(message)
      |> Plug.Conn.put_req_header("mcp-param-token", "route")
      |> HttpPlug.call(opts)

    assert accepted.status == 200

    assert get_in(Jason.decode!(accepted.resp_body), ["result", "structuredContent"]) == %{
             "count" => 1,
             "listings" => 1
           }

    assert_receive {:header_callback, 1}

    assert {:ok, response} =
             Runtime.request(runtime, tool("header", %{"token" => "no-http-header"}, 7))

    assert response["result"]["structuredContent"] == %{"count" => 2, "listings" => 1}
    assert_receive {:header_callback, 1}
    refute_receive {:handler_initialized, _}, 5
  end

  test "host guards and unknown SSE paths cannot allocate standalone sessions" do
    runtime = runtime()
    opts = HttpPlug.init(runtime: runtime, allowed_hosts: ["good.test"], legacy_http_sse: true)
    conn = %{Plug.Test.conn(:post, "/mcp", "not JSON") | host: "evil.test"}
    assert HttpPlug.call(conn, opts).status == 421
    conn = %{Plug.Test.conn(:get, "/unmounted") | host: "good.test"}
    conn = Plug.Conn.put_req_header(conn, "accept", "text/event-stream")
    assert HttpPlug.call(conn, opts).status == 404
    for owner <- @server_owners, do: assert(is_nil(Process.whereis(owner)))
    assert_receive {:handler_initialized, _}
    refute_receive {:handler_initialized, _}, 5
  end

  test "mount filter denial is invoked and root denial cannot be replaced by the mount" do
    parent = self()

    root = fn filter, _context ->
      send(parent, :root_filter)
      {:ok, filter}
    end

    mount = fn _filter, _context ->
      send(parent, :mount_filter)
      false
    end

    runtime = runtime(authorize_filter: root)
    rejected = request(runtime, listen(), authorize_subscription_filter: mount)

    assert Jason.decode!(rejected.resp_body)["error"] == %{
             "code" => -32602,
             "message" => "Invalid subscription request"
           }

    assert_receive :root_filter
    assert_receive :mount_filter

    runtime =
      runtime(
        authorize_filter: fn _filter, _context ->
          send(parent, :denied_root)
          false
        end
      )

    rejected =
      request(runtime, listen(),
        authorize_subscription_filter: fn filter, _ ->
          send(parent, :relaxed_mount)
          {:ok, filter}
        end
      )

    assert Jason.decode!(rejected.resp_body)["error"] == %{
             "code" => -32602,
             "message" => "Invalid subscription request"
           }

    assert_receive :denied_root
    refute_receive :relaxed_mount, 5
  end

  test "a mount cannot reintroduce filter entries removed by root policy" do
    runtime =
      runtime(
        authorize_filter: fn _filter, _context ->
          {:ok, %{"resourceSubscriptions" => ["test://one"]}}
        end
      )

    rejected =
      request(runtime, listen(),
        authorize_subscription_filter: fn _filter, _context ->
          {:ok, %{"resourceSubscriptions" => ["test://one", "test://two"]}}
        end
      )

    assert Jason.decode!(rejected.resp_body)["error"] == %{
             "code" => -32602,
             "message" => "Invalid subscription request"
           }
  end

  test "root and mount publication policy must both accept a real callback publication" do
    parent = self()

    for {root_result, mount_result} <- [{false, true}, {true, false}] do
      runtime =
        runtime(
          authorize_publication: fn _method, _params, _context ->
            send(parent, {:root_publication, root_result})
            root_result
          end
        )

      socket =
        stream(runtime,
          authorize_subscription_publication: fn _method, _params, _context ->
            send(parent, {:mount_publication, mount_result})
            mount_result
          end
        )

      assert_receive {:wire, ^socket, acknowledgment}, 1_000
      assert acknowledgment =~ "acknowledged"
      assert request(runtime, tool("publish", %{"uri" => "test://one"}, 2)).status == 200
      assert_receive {:publication, "test://one", %{enqueued: 0}}, 1_000
      assert_receive {:root_publication, ^root_result}, 1_000
      if root_result, do: assert_receive({:mount_publication, ^mount_result}, 1_000)
      assert_receive {:returned, ^socket, 200}, 1_000
      refute publication_delivered?(socket)
    end
  end

  test "mount queue count stays charged behind entered borrowed IO and can only tighten root caps" do
    runtime = runtime(max_queue: 8)
    socket = stream(runtime, [subscription_max_queue: 1], true)
    assert_receive {:wire, ^socket, acknowledgment}, 1_000
    assert acknowledgment =~ "acknowledged"
    assert_receive {:held_keepalive, ^socket}, 1_000
    request(runtime, tool("publish", %{"uri" => "test://one"}, 2))
    assert_receive {:publication, "test://one", %{enqueued: 1}}, 1_000
    request(runtime, tool("publish", %{"uri" => "test://two"}, 3))
    assert_receive {:publication, "test://two", %{enqueued: 1}}, 1_000
    request(runtime, tool("publish", %{"uri" => "test://one", "revision" => 2}, 4))
    assert_receive {:publication, "test://one", %{closed: 1}}, 1_000
    send(socket, :return_io)
    assert_receive {:returned, ^socket, 200}, 1_000
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    eventually(fn -> HTTPWriterRegistry.stats(domain).in_flight == 0 end)
  end

  test "mount message bytes reject a large notification before physical delivery" do
    runtime = runtime(max_message_bytes: 2_000)
    socket = stream(runtime, subscription_max_message_bytes: 500)
    assert_receive {:wire, ^socket, acknowledgment}, 1_000
    assert acknowledgment =~ "acknowledged"

    request(
      runtime,
      tool("publish", %{"uri" => "test://one", "value" => String.duplicate("x", 600)}, 2)
    )

    assert_receive {:publication, "test://one", %{closed: 1}}, 1_000
    assert_receive {:returned, ^socket, 200}, 1_000

    refute Enum.any?(elem(Process.info(self(), :messages), 1), fn
             {:wire, ^socket, wire} when is_binary(wire) -> byte_size(wire) > 600
             _other -> false
           end)
  end

  test "mount aggregate queue bytes remain retained behind IO until rejection and actual settlement" do
    runtime = runtime(max_queue: 8, max_queue_bytes: 8_192, max_message_bytes: 2_000)
    socket = stream(runtime, [subscription_max_queue_bytes: 700], true)
    assert_receive {:wire, ^socket, acknowledgment}, 1_000
    assert acknowledgment =~ "acknowledged"
    assert_receive {:held_keepalive, ^socket}, 1_000

    request(
      runtime,
      tool("publish", %{"uri" => "test://one", "value" => String.duplicate("x", 350)}, 2)
    )

    assert_receive {:publication, "test://one", %{enqueued: 1}}, 1_000

    request(
      runtime,
      tool("publish", %{"uri" => "test://two", "value" => String.duplicate("x", 350)}, 3)
    )

    assert_receive {:publication, "test://two", %{enqueued: 1}}, 1_000

    request(
      runtime,
      tool("publish", %{"uri" => "test://one", "value" => String.duplicate("y", 350)}, 4)
    )

    assert_receive {:publication, "test://one", %{closed: 1}}, 1_000
    send(socket, :return_io)
    assert_receive {:returned, ^socket, 200}, 1_000
  end

  test "mount lifetime tightens the original listener cutoff and cannot extend the root lifetime" do
    for {root_limit, mount_limit} <- [{700, 100}, {100, 700}] do
      runtime = runtime(max_lifetime_ms: root_limit)
      socket = stream(runtime, subscription_max_lifetime_ms: mount_limit)
      assert_receive {:wire, ^socket, acknowledgment}, 1_000
      assert acknowledgment =~ "acknowledged"
      assert_receive {:returned, ^socket, 200}, 500
      assert_receive {:wire, ^socket, completion} when completion != ":\r\n\r\n", 100
      assert completion =~ "complete"
    end
  end

  test "invalid mount policies fail before handler construction" do
    for {key, value} <- [
          authorize_subscription_filter: fn _ -> true end,
          authorize_subscription_publication: :invalid,
          subscription_max_queue: 0,
          subscription_max_message_bytes: :infinity,
          subscription_max_queue_bytes: -1,
          subscription_max_lifetime_ms: 4_294_967_296
        ] do
      assert_raise ArgumentError, ~r/valid authorizer or finite/, fn ->
        HttpPlug.init([{key, value}, runtime: :not_started])
      end
    end

    refute_receive {:handler_initialized, _}, 5
  end

  defp publication_delivered?(socket) do
    Enum.any?(elem(Process.info(self(), :messages), 1), fn
      {:wire, ^socket, "data: " <> wire} ->
        case Jason.decode(String.trim(wire)) do
          {:ok, %{"method" => "notifications/resources/updated"}} -> true
          _other -> false
        end

      _other ->
        false
    end)
  end

  defp runtime(options \\ []) do
    services = [subscriptions: [options: Keyword.merge([max_lifetime_ms: 250], options)]]

    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [observer: self()],
         transport: :mounted_http,
         request_timeout_ms: 2_000,
         services: services},
        id: make_ref()
      )

    {:ok, ref} = Runtime.ref(root)
    ref
  end

  defp request(runtime, request, extra \\ []) do
    opts = HttpPlug.init(Keyword.merge([runtime: runtime, protocol_mode: :modern_only], extra))
    HttpPlug.call(connection(request), opts)
  end

  defp stream(runtime, options, hold \\ false) do
    parent = self()

    socket =
      spawn(fn ->
        conn = connection(listen()) |> Plug.Conn.put_req_header("accept", "text/event-stream")
        {_adapter, state} = conn.adapter

        conn = %{
          conn
          | adapter: {RecordingAdapter, Map.merge(state, %{observer: parent, hold: hold})}
        }

        opts =
          HttpPlug.init(
            Keyword.merge(
              [
                runtime: runtime,
                protocol_mode: :modern_only,
                subscription_keepalive_interval_ms: 10
              ],
              options
            )
          )

        conn = HttpPlug.call(conn, opts)
        send(parent, {:returned, self(), conn.status})
      end)

    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    socket
  end

  defp connection(request) do
    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
      |> Plug.Conn.put_req_header("mcp-method", request["method"])

    if name = get_in(request, ["params", "name"]),
      do: Plug.Conn.put_req_header(conn, "mcp-name", name),
      else: conn
  end

  defp tool(name, arguments, id),
    do:
      modern(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

  defp listen,
    do:
      modern(%{
        "jsonrpc" => "2.0",
        "id" => 91,
        "method" => "subscriptions/listen",
        "params" => %{
          "notifications" => %{"resourceSubscriptions" => ["test://one", "test://two"]}
        }
      })

  defp modern(request),
    do:
      put_in(request, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
