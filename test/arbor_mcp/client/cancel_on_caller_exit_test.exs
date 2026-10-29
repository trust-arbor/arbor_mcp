defmodule Arbor.MCP.Client.CancelOnCallerExitTest do
  @moduledoc """
  When the process waiting for a request exits, nobody will read the result,
  so the client cancels the request upstream, as it does at a timeout. That
  is the default for modern (2026-07-28) requests: over Streamable HTTP the
  request's POST or request stream is closed, elsewhere
  `notifications/cancelled` is sent. On a legacy connection it happens only
  with `cancel_on_caller_exit: true`, and `false` turns it off for a modern
  request.
  """

  use ExUnit.Case, async: false

  # A client whose test process exits stops through terminate/2, which can
  # log its transport-close worker being refused; that is not under test.
  @moduletag :capture_log

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Context, Runtime}

  defmodule ServerHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(args), do: {:ok, %{test_pid: Keyword.fetch!(args, :test_pid)}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{name: "cancel-on-exit", version: "0"},
         capabilities: %{tools: %{}, prompts: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ["hold", "quick", "onboard"],
            do: %{name: name, inputSchema: %{type: "object"}}

      {:ok, tools, nil, state}
    end

    # Three pages; the second holds. (Prompts, because a modern tools/call
    # walks the tool list on the server.)
    @impl true
    def handle_list_prompts(nil, state), do: {:ok, [%{name: "p1"}], "page-2", state}

    def handle_list_prompts("page-2", state) do
      case hold("page-2", state) do
        {:ok, %{content: [_ | _]}, state} -> {:ok, [%{name: "p2"}], "page-3", state}
        {:ok, _cancelled, state} -> {:ok, [], nil, state}
      end
    end

    def handle_list_prompts("page-3", state) do
      send(state.test_pid, {:page_requested, "page-3"})
      {:ok, [%{name: "p3"}], nil, state}
    end

    @impl true
    def handle_call_tool("hold", %{"label" => label}, state), do: hold(label, state)

    def handle_call_tool("quick", _args, state),
      do: {:ok, %{content: [%{type: "text", text: "quick"}]}, state}

    # Round 1 asks the client for input; round 2 holds like "hold".
    def handle_call_tool("onboard", %{"mode" => mode}, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "profile" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => mode,
                "requestedSchema" => %{
                  "type" => "object",
                  "properties" => %{"name" => %{"type" => "string"}}
                }
              }
            }
          }

          {:input_required, requests, state}

        _responses ->
          hold("onboard-2", state)
      end
    end

    defp hold(label, state) do
      send(state.test_pid, {:holding, label, self(), Context.request_id()})

      receive do
        :release ->
          send(state.test_pid, {:server_completed, label})
          {:ok, %{content: [%{type: "text", text: label}]}, state}

        {:arbor_mcp_cancelled, _token, reason} ->
          send(state.test_pid, {:server_cancelled, label, reason})
          {:ok, %{content: []}, state}
      end
    end
  end

  defmodule ClientHandler do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_ping(test_pid), do: {:ok, %{}, test_pid}

    @impl true
    def handle_list_roots(test_pid), do: {:ok, [], test_pid}

    @impl true
    def handle_create_message(_params, test_pid), do: {:error, "not used", test_pid}

    # "block" waits for the test, as a person answering a form would.
    @impl true
    def handle_elicitation_create("block", _schema, test_pid) do
      send(test_pid, {:elicitation_started, self()})

      receive do
        :answer -> {:ok, %{"action" => "accept", "content" => %{"name" => "Grace"}}, test_pid}
      end
    end

    def handle_elicitation_create(_message, _schema, test_pid),
      do: {:ok, %{"action" => "accept", "content" => %{"name" => "Grace"}}, test_pid}
  end

  describe "a modern HTTP request whose caller exits" do
    test "is cancelled when it POSTs from a task" do
      client = start_http_client()
      {caller, caller_ref} = start_caller(fn -> hold(client, "post") end)
      {"post", _handler} = receive_holding()

      assert watched_by?(caller, client)
      kill(caller, caller_ref)

      assert_receive {:server_cancelled, "post", _reason}, 3_000
      wait_until(fn -> Client.get_pending_requests(client) == [] end, timeout: 2_000)
    end

    test "is cancelled when it has its own request stream" do
      client = start_http_client()
      {caller, caller_ref} = start_caller(fn -> hold(client, "stream", progress_token: "s") end)
      {"stream", _handler} = receive_holding()

      kill(caller, caller_ref)

      assert_receive {:server_cancelled, "stream", _reason}, 3_000
      wait_until(fn -> Client.get_pending_requests(client) == [] end, timeout: 2_000)
    end

    test "is not cancelled with cancel_on_caller_exit: false" do
      client = start_http_client()

      {caller, caller_ref} =
        start_caller(fn -> hold(client, "kept", cancel_on_caller_exit: false) end)

      {"kept", handler} = receive_holding()

      refute watched_by?(caller, client)
      kill(caller, caller_ref)

      send(handler, :release)
      assert_receive {:server_completed, "kept"}, 3_000
      refute_received {:server_cancelled, "kept", _reason}
      wait_until(fn -> Client.get_pending_requests(client) == [] end, timeout: 2_000)
    end

    test "is the only one cancelled when one of many callers exits" do
      client = start_http_client()
      telemetry = attach_caller_exited()

      callers =
        for label <- ["a", "b", "c", "d"], into: %{} do
          opts = if label == "d", do: [progress_token: "d"], else: []
          {label, start_caller(fn -> hold(client, label, opts) end)}
        end

      handlers = for _ <- 1..4, into: %{}, do: receive_holding()

      {caller, caller_ref} = callers["c"]
      kill(caller, caller_ref)
      assert_receive {:server_cancelled, "c", _reason}, 3_000
      assert_receive {:caller_exited, ^telemetry, _request_id}

      for label <- ["a", "b", "d"] do
        send(handlers[label], :release)
        {pid, _ref} = callers[label]
        assert_receive {:caller_result, ^pid, {:ok, %{content: [%{text: ^label}]}}}, 3_000
      end

      refute_received {:server_cancelled, _label, _reason}
      refute_received {:caller_exited, ^telemetry, _request_id}
    end

    test "sends no cancellation once it completed" do
      client = start_http_client()
      telemetry = attach_caller_exited()

      {caller, caller_ref} =
        start_caller(fn -> Client.call_tool(client, "quick", %{}, timeout: 5_000) end)

      assert_receive {:caller_result, ^caller, {:ok, _result}}, 3_000
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}

      # The completion dropped the watch, so the caller's exit means nothing.
      assert %{caller_watches: watches, caller_monitors: monitors} = :sys.get_state(client)
      assert watches == %{} and monitors == %{}
      refute_received {:caller_exited, ^telemetry, _request_id}
    end
  end

  describe "a list walk whose caller exits" do
    test "cancels the page in flight and requests no further page" do
      client = start_http_client()
      {caller, caller_ref} = start_caller(fn -> Client.all_prompts(client, timeout: 5_000) end)
      {"page-2", _handler} = receive_holding()

      assert watched_by?(caller, client)
      kill(caller, caller_ref)

      assert_receive {:server_cancelled, "page-2", _reason}, 3_000
      refute_received {:page_requested, "page-3"}
    end

    test "passes cancel_on_caller_exit to each page request" do
      client = start_http_client()

      {caller, caller_ref} =
        start_caller(fn ->
          Client.all_prompts(client, timeout: 5_000, cancel_on_caller_exit: false)
        end)

      {"page-2", handler} = receive_holding()

      refute watched_by?(caller, client)
      kill(caller, caller_ref)

      send(handler, :release)
      assert_receive {:server_completed, "page-2"}, 3_000
      refute_received {:server_cancelled, "page-2", _reason}
    end
  end

  describe "an MRTR call whose caller exits" do
    test "stops the client handler answering its input" do
      client = start_http_client()

      {caller, caller_ref} =
        start_caller(fn ->
          Client.call_tool(client, "onboard", %{"mode" => "block"}, timeout: 5_000)
        end)

      assert_receive {:elicitation_started, fulfilment}, 3_000
      fulfilment_ref = Process.monitor(fulfilment)

      kill(caller, caller_ref)

      assert_receive {:DOWN, ^fulfilment_ref, :process, ^fulfilment, :killed}, 3_000
      wait_until(fn -> :sys.get_state(client).mrtr_tasks == %{} end, timeout: 2_000)
    end

    test "cancels the round in flight" do
      client = start_http_client()

      {caller, caller_ref} =
        start_caller(fn ->
          Client.call_tool(client, "onboard", %{"mode" => "answer"}, timeout: 5_000)
        end)

      {"onboard-2", _handler} = receive_holding()
      kill(caller, caller_ref)

      assert_receive {:server_cancelled, "onboard-2", _reason}, 3_000
    end
  end

  describe "a request over a BEAM connection whose caller exits" do
    test "is cancelled with notifications/cancelled on a modern connection" do
      client = start_beam_client(:modern_only)
      {caller, caller_ref} = start_caller(fn -> hold(client, "modern-beam") end)
      {"modern-beam", _handler} = receive_holding()

      kill(caller, caller_ref)

      assert_receive {:server_cancelled, "modern-beam", _reason}, 3_000
    end

    test "is not cancelled on a legacy connection by default" do
      client = start_beam_client(:legacy_only)
      {caller, caller_ref} = start_caller(fn -> hold(client, "legacy") end)
      {"legacy", handler} = receive_holding()

      refute watched_by?(caller, client)
      kill(caller, caller_ref)

      send(handler, :release)
      assert_receive {:server_completed, "legacy"}, 3_000
      refute_received {:server_cancelled, "legacy", _reason}
    end

    test "is cancelled on a legacy connection with cancel_on_caller_exit: true" do
      client = start_beam_client(:legacy_only)

      {caller, caller_ref} =
        start_caller(fn -> hold(client, "legacy-on", cancel_on_caller_exit: true) end)

      {"legacy-on", _handler} = receive_holding()

      kill(caller, caller_ref)

      assert_receive {:server_cancelled, "legacy-on", _reason}, 3_000
    end
  end

  describe "a legacy Streamable HTTP request whose caller exits" do
    test "is cancelled with notifications/cancelled only when the call asks" do
      client = start_legacy_http_client()

      {caller, caller_ref} =
        start_caller(fn ->
          Client.call_tool(client, "hang", %{}, timeout: 5_000, cancel_on_caller_exit: true)
        end)

      assert_receive {:hang_started, request_id, handler}, 3_000
      handler_ref = Process.monitor(handler)
      kill(caller, caller_ref)
      assert_receive {:cancelled, %{"requestId" => ^request_id}}, 3_000

      {quiet, quiet_ref} =
        start_caller(fn -> Client.call_tool(client, "hang", %{}, timeout: 5_000) end)

      assert_receive {:hang_started, quiet_id, quiet_handler}, 3_000
      quiet_handler_ref = Process.monitor(quiet_handler)
      refute watched_by?(quiet, client)
      kill(quiet, quiet_ref)
      refute_received {:cancelled, %{"requestId" => ^quiet_id}}

      # A legacy POST runs on after its cancellation; disconnecting closes
      # both, and their handlers end before the test does (see
      # await_handler/1).
      stop(client)
      await_handler(handler_ref)
      await_handler(quiet_handler_ref)
    end
  end

  test "nil leaves the era's default" do
    modern = start_beam_client(:modern_only)

    {caller, caller_ref} =
      start_caller(fn -> hold(modern, "nil-modern", cancel_on_caller_exit: nil) end)

    {"nil-modern", _handler} = receive_holding()
    assert watched_by?(caller, modern)
    kill(caller, caller_ref)
    assert_receive {:server_cancelled, "nil-modern", _reason}, 3_000

    legacy = start_beam_client(:legacy_only)

    {caller, caller_ref} =
      start_caller(fn -> hold(legacy, "nil-legacy", cancel_on_caller_exit: nil) end)

    {"nil-legacy", handler} = receive_holding()
    refute watched_by?(caller, legacy)
    kill(caller, caller_ref)
    send(handler, :release)
    assert_receive {:server_completed, "nil-legacy"}, 3_000
  end

  # Every public function that takes request options accepts the option
  # (none raises), and the content helpers, which check their options
  # themselves, pass it on. The legacy batches take only a timeout, by
  # design, and aren't cancelled with their caller.
  test "every request function but the batches accepts cancel_on_caller_exit" do
    client = start_beam_client(:modern_only)

    for value <- [true, false, nil] do
      opts = [cancel_on_caller_exit: value, timeout: 2_000]

      calls = [
        fn -> Client.list_tools(client, opts) end,
        fn -> Client.call_tool(client, "quick", %{}, opts) end,
        fn -> Client.list_resources(client, opts) end,
        fn -> Client.list_resource_templates(client, opts) end,
        fn -> Client.read_resource(client, "test://none", opts) end,
        fn -> Client.list_prompts(client, opts) end,
        fn -> Client.get_prompt(client, "none", %{}, opts) end,
        fn -> Client.ping(client, opts) end,
        fn -> Client.discover(client, opts) end,
        fn -> Client.tool_definitions(client, opts) end,
        fn -> Client.call_content(client, "quick", %{}, opts) end,
        fn -> Client.resource_definitions(client, opts) end,
        fn -> Client.read_content(client, "test://none", opts) end,
        fn -> Client.all_tools(client, opts) end,
        fn -> Client.all_resources(client, opts) end,
        fn -> Client.all_resource_templates(client, opts) end
      ]

      for call <- calls, do: assert(elem(call.(), 0) in [:ok, :error])
    end

    {caller, caller_ref} =
      start_caller(fn ->
        Client.call_content(client, "hold", %{"label" => "content"},
          timeout: 5_000,
          cancel_on_caller_exit: false
        )
      end)

    {"content", handler} = receive_holding()
    refute watched_by?(caller, client)
    kill(caller, caller_ref)
    send(handler, :release)
    assert_receive {:server_completed, "content"}, 3_000
  end

  # The refresh is made on the caller's behalf: it is watched as the call
  # is, so the call's opt-out covers it too.
  describe "a tools/call that refreshes tools/list after a header mismatch" do
    test "has the refresh cancelled when its caller exits" do
      client = start_header_mismatch_client()

      {caller, caller_ref} =
        start_caller(fn -> Client.call_tool(client, "mismatch", %{}, timeout: 5_000) end)

      assert_receive {:refreshing, handler}, 3_000
      handler_ref = Process.monitor(handler)
      assert watched_by?(caller, client)
      kill(caller, caller_ref)

      assert_receive :refresh_cancelled, 3_000
      await_handler(handler_ref)
    end

    test "keeps the refresh running with cancel_on_caller_exit: false" do
      client = start_header_mismatch_client()

      {caller, caller_ref} =
        start_caller(fn ->
          Client.call_tool(client, "mismatch", %{}, timeout: 5_000, cancel_on_caller_exit: false)
        end)

      assert_receive {:refreshing, handler}, 3_000
      handler_ref = Process.monitor(handler)
      refute watched_by?(caller, client)
      kill(caller, caller_ref)

      send(handler, :release)
      assert_receive :refresh_completed, 3_000
      await_handler(handler_ref)
      refute_received :refresh_cancelled
    end
  end

  describe "a caller that stays alive" do
    test "keeps no watch once its requests timed out, failed or were cancelled" do
      client = start_http_client()

      # A walk whose second page outlives the walk's timeout.
      assert {:error, :timeout} = Client.all_prompts(client, timeout: 300)
      assert_receive {:holding, "page-2", _handler, _id}
      assert_receive {:server_cancelled, "page-2", _reason}, 3_000
      assert_no_watch(client)

      # A call cancelled explicitly.
      task = Task.async(fn -> hold(client, "explicit") end)
      {"explicit", _handler} = receive_holding()
      [request_id] = Client.get_pending_requests(client)
      assert :ok = Client.send_cancelled(client, request_id, "not needed")
      assert {:error, :cancelled} = Task.await(task)
      assert_no_watch(client)

      # An error response.
      assert {:error, _unknown_tool} = Client.call_tool(client, "missing", %{}, timeout: 2_000)
      assert_no_watch(client)

      # An MRTR round whose input fulfilment outlives the call's timeout.
      assert {:error, :timeout} =
               Client.call_tool(client, "onboard", %{"mode" => "block"}, timeout: 300)

      assert_receive {:elicitation_started, _fulfilment}
      wait_until(fn -> :sys.get_state(client).mrtr_tasks == %{} end, timeout: 2_000)
      assert_no_watch(client)
    end

    test "keeps no watch once its connection is lost" do
      client = start_beam_client(:modern_only)
      test_pid = self()

      caller =
        spawn(fn ->
          send(test_pid, {:caller_result, self(), hold(client, "lost")})

          receive do
            :stop -> :ok
          end
        end)

      {"lost", _handler} = receive_holding()
      assert watched_by?(caller, client)

      # As the transport reports a lost connection.
      send(client, {:transport_closed, :connection_lost})

      assert_receive {:caller_result, ^caller, {:error, _closed}}, 3_000
      refute watched_by?(caller, client)
      assert %{caller_watches: watches, caller_monitors: monitors} = :sys.get_state(client)
      assert watches == %{} and monitors == %{}
      send(caller, :stop)
    end
  end

  test "an invalid cancel_on_caller_exit is refused" do
    client = start_beam_client(:modern_only)

    assert_raise ArgumentError, ~r/cancel_on_caller_exit must be a boolean/, fn ->
      Client.call_tool(client, "quick", %{}, cancel_on_caller_exit: :yes)
    end
  end

  # No caller watch or monitor is left, and none on this test process.
  defp assert_no_watch(client) do
    wait_until(fn -> Client.get_pending_requests(client) == [] end, timeout: 3_000)
    assert %{caller_watches: watches, caller_monitors: monitors} = :sys.get_state(client)
    assert watches == %{} and monitors == %{}
    refute watched_by?(self(), client)
  end

  defp hold(client, label, opts \\ []),
    do: Client.call_tool(client, "hold", %{"label" => label}, [timeout: 5_000] ++ opts)

  # A process that makes one call and reports its result.
  defp start_caller(fun) do
    test_pid = self()
    spawn_monitor(fn -> send(test_pid, {:caller_result, self(), fun.()}) end)
  end

  # A Bypass handler still running when its test ends leaves Bypass 2.1.0's
  # instance to answer on_exit late, and it then crashes calling
  # GenServer.stop(:normal); a few such crashes in a row stop the
  # Bypass.Supervisor, and every later Bypass.open in the run fails. So a
  # test waits for the handlers it started.
  defp await_handler(handler_ref) do
    assert_receive {:DOWN, ^handler_ref, :process, _handler, _reason}, 3_000
  end

  defp kill(caller, caller_ref) do
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
  end

  defp watched_by?(caller, client) do
    {:monitored_by, monitors} = Process.info(caller, :monitored_by)
    client in monitors
  end

  defp receive_holding do
    assert_receive {:holding, label, handler, _request_id}, 3_000
    {label, handler}
  end

  defp attach_caller_exited do
    ref = make_ref()
    test_pid = self()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:arbor_mcp, :client, :request, :caller_exited],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:caller_exited, ref, metadata.request_id})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp start_http_client do
    port = free_port()
    ranch_ref = {__MODULE__, System.unique_integer([:positive])}

    runtime =
      start_supervised!(
        {Runtime,
         handler: ServerHandler, handler_args: [test_pid: self()], transport: :mounted_http}
      )

    {:ok, _pid} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [
          runtime: runtime,
          handler_opts: fn _conn -> %{socket: self()} end,
          path: "/mcp",
          protocol_mode: :modern_only,
          mrtr: true,
          request_state: [
            active_key_id: "cancel-on-exit",
            keys: %{"cancel-on-exit" => :binary.copy(<<9>>, 32)}
          ],
          allowed_origins: ["http://127.0.0.1:#{port}"]
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        protocol_version: "2026-07-28",
        capabilities: %{"elicitation" => %{"form" => %{}}},
        handler: {ClientHandler, [test_pid: self()]},
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)
    client
  end

  defp start_beam_client(protocol_mode) do
    {:ok, server} =
      Server.start_link(
        handler: ServerHandler,
        handler_args: [test_pid: self()],
        transport: :test,
        protocol_mode: protocol_mode
      )

    on_exit(fn -> Arbor.MCP.TestHelpers.safe_stop_process(server) end)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: protocol_mode,
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)
    client
  end

  # A scripted modern server whose "mismatch" call fails with -32020 until
  # the client has refreshed tools/list, which holds until released.
  defp start_header_mismatch_client do
    bypass = Bypass.open()
    test_pid = self()
    refreshed = start_supervised!({Agent, fn -> false end}, id: make_ref())

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => "server/discover", "id" => id} ->
          json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => discover_result()})

        %{"method" => "tools/list", "id" => id} ->
          # A client that cancels the refresh closes its connection, and
          # Cowboy then stops this handler. Trapping that, it ends normally,
          # since Bypass re-raises a handler's exit when the test ends. It
          # traps before it says it is ready, as the test may cancel at once.
          Process.flag(:trap_exit, true)
          send(test_pid, {:refreshing, self()})

          receive do
            :release ->
              Agent.update(refreshed, fn _ -> true end)
              send(test_pid, :refresh_completed)
              result = %{"resultType" => "complete", "tools" => []}
              json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

            {:EXIT, _from, _reason} ->
              send(test_pid, :refresh_cancelled)
              conn
          after
            5_000 -> conn
          end

        %{"method" => "tools/call", "id" => id} ->
          if Agent.get(refreshed, & &1) do
            result = %{"resultType" => "complete", "content" => []}
            json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
          else
            error = %{"code" => -32_020, "message" => "Header mismatch"}
            json(conn, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
          end
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        protocol_mode: :modern_only,
        protocol_version: "2026-07-28",
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)
    client
  end

  defp discover_result do
    %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => "mismatch", "version" => "1"}
      }
    }
  end

  # A scripted legacy-era server: "hang" runs until its connection closes.
  defp start_legacy_http_client do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      legacy_respond(conn, Jason.decode!(body), test_pid)
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        use_sse: false,
        protocol_mode: :legacy_only,
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)
    client
  end

  defp legacy_respond(conn, %{"method" => "initialize", "id" => id}, _test_pid) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "legacy-cancel", "version" => "1"}
      }
    })
  end

  defp legacy_respond(conn, %{"method" => "tools/call", "id" => id}, test_pid) do
    # Trapping first: the test may cancel as soon as it hears of this call.
    Process.flag(:trap_exit, true)
    send(test_pid, {:hang_started, id, self()})

    receive do
      {:EXIT, _from, _reason} -> :ok
    after
      5_000 -> :ok
    end

    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => []}})
  end

  defp legacy_respond(
         conn,
         %{"method" => "notifications/cancelled", "params" => params},
         test_pid
       ) do
    send(test_pid, {:cancelled, params})
    Plug.Conn.resp(conn, 202, "")
  end

  defp legacy_respond(conn, _notification, _test_pid), do: Plug.Conn.resp(conn, 202, "")

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp stop(client) do
    if Process.alive?(client) do
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
