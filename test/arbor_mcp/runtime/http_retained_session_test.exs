defmodule Arbor.MCP.Server.Runtime.HTTPRetainedSessionTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.{HttpPlug, SessionManager}
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    HTTPWriterBinding,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    Services
  }

  alias Arbor.MCP.SessionManager.SessionLease

  defmodule Handler do
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Protocol.Initialize

    def init(_opts), do: {:ok, 0}

    def handle_initialize(params, state) do
      {:ok,
       Initialize.build_initialize_result(params, %{
         "serverInfo" => %{"name" => "retained", "version" => "2"},
         "capabilities" => %{}
       }), state}
    end
  end

  defmodule RecordingAdapter do
    alias Plug.Adapters.Test.Conn

    def send_resp(state, status, headers, body),
      do: Conn.send_resp(state, status, headers, body)

    def send_chunked(state, status, headers),
      do: Conn.send_chunked(state, status, headers)

    def chunk(state, body) do
      send(state.observer, {:session_frame, self(), IO.iodata_to_binary(body)})

      if state.block_write do
        receive do
          :write_return -> :ok
        end
      end

      Conn.chunk(state, body)
    end
  end

  defmodule DelayedDeleteStore do
    alias Arbor.MCP.Server.Runtime.ServiceStore
    alias Arbor.MCP.SessionManager.RuntimeStore

    def start_link(opts), do: ServiceStore.start_link(__MODULE__, opts)
    defdelegate runtime_service_capabilities(), to: RuntimeStore
    defdelegate runtime_service_binding(server, timeout), to: RuntimeStore
    defdelegate operate(operation, args, context, opts), to: RuntimeStore
    defdelegate lease_active?(id, epoch, opts), to: RuntimeStore
    defdelegate read_address(model), to: RuntimeStore
    defdelegate close(model), to: RuntimeStore
    defdelegate expire(model, deadline), to: RuntimeStore
    defdelegate info(message, model), to: RuntimeStore

    def open(opts) do
      with {:ok, model} <- RuntimeStore.open(opts),
           do: {:ok, Map.put(model, :test_parent, opts[:test_parent])}
    end

    def apply(:terminate, args, context, model) do
      send(model.test_parent, {:delete_final_guard, self()})

      receive do
        :resume_delete -> RuntimeStore.apply(:terminate, args, context, model)
      end
    end

    def apply(operation, args, context, model),
      do: RuntimeStore.apply(operation, args, context, model)
  end

  defmodule PrivateEvent do
    defstruct [:owner]
  end

  defimpl Jason.Encoder, for: PrivateEvent do
    def encode(value, opts) do
      send(value.owner, :private_event_encoder_called)
      Jason.Encode.map(%{}, opts)
    end
  end

  test "GET without a cursor sends a connected handshake and skips historical replay" do
    {runtime, opts, id, service, lease} = session()

    assert {:ok, _event} =
             SessionManager.append_event(service, lease, "message", %{"old" => 1}, [])

    conn = get(id, opts)
    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "event: connected\ndata: {\"session_id\":\"#{id}\"}\n\n"
    refute conn.resp_body =~ "id: "
    assert {:ok, _} = SessionManager.get_session(service, lease, [])
    settled(runtime)
  end

  test "replay follows store cursors and bounded pages with one physical frame credit" do
    {runtime, opts, id, service, lease} =
      session(max_http_io_frames: 1, services: [sessions: [options: [max_replay_page_events: 1]]])

    {:ok, first} = SessionManager.append_event(service, lease, "message", %{"seq" => 1}, [])
    {:ok, second} = SessionManager.append_event(service, lease, "message", %{"seq" => 2}, [])
    {:ok, third} = SessionManager.append_event(service, lease, "message", %{"seq" => 3}, [])
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    guardian = HTTPWriterRegistry.guardian(domain)
    :sys.suspend(guardian)

    try do
      conn = get(id, opts, first.id)
      assert conn.status == 200
      assert conn.resp_body =~ "id: #{second.id}\nevent: message\ndata: {\"seq\":2}"
      assert conn.resp_body =~ "id: #{third.id}\nevent: message\ndata: {\"seq\":3}"
      refute conn.resp_body =~ "id: #{first.id}"
      assert length(String.split(conn.resp_body, "\n\n", trim: true)) == 3
    after
      :sys.resume(guardian)
    end

    settled(runtime)
  end

  test "foreign unknown evicted and duplicate cursors fail before the SSE handshake" do
    {_runtime, opts, id, service, lease} =
      session(services: [sessions: [options: [max_events_per_session: 1]]])

    {:ok, first} = SessionManager.append_event(service, lease, "message", %{}, [])
    {:ok, _second} = SessionManager.append_event(service, lease, "message", %{}, [])
    assert get(id, opts, first.id).status == 410
    assert get(id, opts, "not-a-store-cursor").status == 400

    {:ok, other} = SessionManager.create_session(service, %{}, [])
    {:ok, event} = SessionManager.append_event(service, other, "message", %{}, [])
    assert get(id, opts, event.id).status == 400

    conn =
      session_conn(:get, id)
      |> Map.put(:req_headers, [
        {"last-event-id", "one"},
        {"last-event-id", "two"} | session_conn(:get, id).req_headers
      ])
      |> HttpPlug.call(opts)

    assert conn.status == 400
    refute conn.state == :chunked
    assert get(id, opts, String.duplicate("a", 257)).status == 400
  end

  test "DELETE closes only the addressed epoch and clears its replay and request credits" do
    {runtime, opts, id, service, lease} = session()
    assert {:ok, _} = SessionManager.append_event(service, lease, "message", %{}, [])
    assert :ok = SessionManager.claim_request_id(service, lease, "claimed", [])
    conn = session_conn(:delete, id) |> HttpPlug.call(opts)
    assert conn.status == 204
    assert conn.resp_body == ""
    assert {:error, :stale_session_lease} = SessionManager.get_session(service, lease, [])

    assert {:ok, %{sessions: 0, events: 0, request_ids: 0}} =
             SessionManager.get_stats(service, [])

    settled(runtime)
  end

  test "wrong identity missing header and incomplete initialization cannot delete a session" do
    {_runtime, opts, id, service, lease} = session()
    wrong = Map.put(opts, :principal_id, "another-principal")
    assert (session_conn(:delete, id) |> HttpPlug.call(wrong)).status == 404
    assert (Plug.Test.conn(:delete, "/mcp") |> HttpPlug.call(opts)).status == 400
    assert {:ok, _} = SessionManager.get_session(service, lease, [])

    {:ok, pending} =
      SessionManager.create_session(service, %{transport_endpoint: "/mcp"}, [])

    assert (session_conn(:delete, SessionLease.id(pending)) |> HttpPlug.call(opts)).status == 400
    assert {:ok, _} = SessionManager.get_session(service, pending, [])
  end

  test "physical IO saturation rejects DELETE before the session mutation" do
    {runtime, opts, id, service, lease} = session(max_http_io_frames: 1)
    socket = socket()
    {:ok, binding} = call(socket, fn -> HTTPWriterProxy.capture(runtime) end)
    {:ok, effect} = call(socket, fn -> HTTPWriterRegistry.prepare(binding, "held") end)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.publish(effect) end)
    {:ok, checked, _wire} = call(socket, fn -> HTTPWriterRegistry.checkout(binding) end)

    assert_raise Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError, fn ->
      session_conn(:delete, id) |> HttpPlug.call(opts)
    end

    assert {:ok, _} = SessionManager.get_session(service, lease, [])
    assert Process.alive?(socket)
    assert :ok = call(socket, fn -> HTTPWriterRegistry.complete(checked, :ok) end)
    assert (session_conn(:delete, id) |> HttpPlug.call(opts)).status == 204
    settled(runtime)
  end

  test "delayed DELETE cannot mutate after the original socket cutoff" do
    {_runtime, opts, id, service, lease} = initialized_session(request_timeout_ms: 60)
    assert {:ok, before_session} = SessionManager.get_session(service, lease, [])
    assert {:ok, before_stats} = SessionManager.get_stats(service, [])
    {:ok, backend} = Services.resolve(service, :sessions)
    :sys.suspend(backend.server)

    try do
      assert_raise Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError, fn ->
        session_conn(:delete, id) |> HttpPlug.call(opts)
      end
    after
      :sys.resume(backend.server)
    end

    assert {:ok, ^before_session} = SessionManager.get_session(service, lease, [])
    assert {:ok, ^before_stats} = SessionManager.get_stats(service, [])
  end

  test "DELETE delayed after response reservation is rejected at the final mutation guard" do
    {runtime, opts, id, service, lease} =
      initialized_session(
        request_timeout_ms: 60,
        services: [sessions: [adapter: DelayedDeleteStore, options: [test_parent: self()]]]
      )

    socket = socket()
    token = make_ref()

    send(
      socket,
      {:call, self(), token,
       fn ->
         try do
           session_conn(:delete, id) |> HttpPlug.call(opts)
         rescue
           Arbor.MCP.HttpPlug.RuntimeWriter.AdmissionError -> :response_unavailable
         end
       end}
    )

    assert_receive {:delete_final_guard, store}, 1_000
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    assert HTTPWriterRegistry.stats(domain).frames == 1
    assert_receive {^token, :response_unavailable}, 1_000
    send(store, :resume_delete)
    assert {:ok, _} = SessionManager.get_session(service, lease, [])
    assert Process.alive?(socket)
    settled(runtime)
  end

  test "completed initialization rejects a second initialize with a scoped lifecycle error" do
    {_runtime, opts, id, service, lease} = session()

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(%{initialize() | "id" => 2}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", id)
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-11-25")
      |> HttpPlug.call(opts)

    assert conn.status == 400
    assert {:ok, %{initialized: true}} = SessionManager.get_session(service, lease, [])
    assert {:ok, %{sessions: 1}} = SessionManager.get_stats(service, [])
  end

  test "GET requires event-stream negotiation before opening a stream" do
    {_runtime, opts, id, _service, _lease} = session()

    conn =
      session_conn(:get, id)
      |> Plug.Conn.delete_req_header("accept")
      |> HttpPlug.call(opts)

    assert conn.status == 400
    refute conn.state == :chunked
  end

  test "live GET writes from its socket process and expires without closing the session" do
    {runtime, opts, id, service, lease} = initialized_session(request_timeout_ms: 150)
    parent = self()
    socket = socket()
    stream_opts = %{opts | sse_mode: :stream}
    token = make_ref()

    send(
      socket,
      {:call, self(), token,
       fn ->
         conn = session_conn(:get, id) |> recording(parent)
         HttpPlug.call(conn, stream_opts)
       end}
    )

    assert_receive {:session_frame, ^socket, initial}, 1000
    assert initial =~ "event: connected"
    {:ok, event} = SessionManager.append_event(service, lease, "message", %{"live" => true}, [])
    assert_receive {:session_frame, ^socket, live}, 1000
    assert live =~ "id: #{event.id}\nevent: message"
    assert_receive {^token, %{status: 200}}, 1000
    assert Process.alive?(socket)
    assert {:ok, _} = SessionManager.get_session(service, lease, [])
    settled(runtime)
  end

  test "DELETE retires an open GET without killing its borrowed socket" do
    {runtime, opts, id, _service, _lease} = session()
    parent = self()
    socket = socket()
    token = make_ref()

    send(
      socket,
      {:call, self(), token,
       fn ->
         session_conn(:get, id) |> recording(parent) |> HttpPlug.call(%{opts | sse_mode: :stream})
       end}
    )

    assert_receive {:session_frame, ^socket, _initial}, 1000
    assert (session_conn(:delete, id) |> HttpPlug.call(opts)).status == 204
    assert_receive {^token, %{status: 200}}, 1000
    assert Process.alive?(socket)
    settled(runtime)
  end

  test "replacing a session stream retains old actual IO until return and keeps both hosts alive" do
    {runtime, _opts, _id, _service, lease} = session(max_http_io_frames: 1)
    first = socket()
    second = socket()
    {:ok, a} = call(first, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = call(first, fn -> HTTPWriterRegistry.bind_lease(a, lease) end)
    assert :ok = call(first, fn -> HTTPWriterRegistry.register_session_stream(a) end)
    {:ok, effect} = call(first, fn -> HTTPWriterRegistry.prepare(a, "started") end)
    assert :ok = call(first, fn -> HTTPWriterRegistry.publish(effect) end)
    {:ok, checked, _} = call(first, fn -> HTTPWriterRegistry.checkout(a) end)
    {:ok, b} = call(second, fn -> HTTPWriterProxy.capture(runtime) end)
    assert :ok = call(second, fn -> HTTPWriterRegistry.bind_lease(b, lease) end)
    assert :ok = call(second, fn -> HTTPWriterRegistry.register_session_stream(b) end)
    assert {:error, :http_invocation_closed} = HTTPWriterBinding.validate(a, runtime)
    assert {:ok, _} = HTTPWriterBinding.validate(b, runtime)

    assert {:error, :http_output_busy} =
             call(second, fn -> HTTPWriterRegistry.prepare(b, "new") end)

    assert {:error, :http_write_uncertain} =
             call(first, fn -> HTTPWriterRegistry.complete(checked, :ok) end)

    assert {:ok, fresh} = call(second, fn -> HTTPWriterRegistry.prepare(b, "new") end)
    assert :ok = call(second, fn -> HTTPWriterRegistry.release(fresh) end)
    assert Process.alive?(first) and Process.alive?(second)
    settled(runtime)
  end

  test "replay append rejects custom encoders without invoking application code or consuming events" do
    {_runtime, _opts, _id, service, lease} = session()
    {:ok, before} = SessionManager.get_stats(service, [])

    assert {:error, :event_not_json_encodable} =
             SessionManager.append_event(
               service,
               lease,
               "message",
               %PrivateEvent{owner: self()},
               []
             )

    refute_receive :private_event_encoder_called, 10
    assert {:ok, ^before} = SessionManager.get_stats(service, [])
  end

  test "modern auto-mode GET and DELETE reject sessionful methods without a global fallback" do
    runtime = runtime()
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :auto)

    for method <- [:get, :delete] do
      conn =
        Plug.Test.conn(method, "/mcp")
        |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
        |> HttpPlug.call(opts)

      assert conn.status == 405
      assert Plug.Conn.get_resp_header(conn, "allow") == ["POST"]
      assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []
    end
  end

  defp session(extra \\ []) do
    runtime = runtime(extra)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only, sse_mode: :oneshot)

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(initialize()))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> HttpPlug.call(opts)

    assert conn.status == 200, conn.resp_body
    [id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
    {:ok, service} = Runtime.service(runtime, :sessions)
    {:ok, lease} = SessionManager.ensure_initialized_session(service, id, %{}, [])
    {runtime, opts, id, service, lease}
  end

  defp runtime(extra \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             handler: Handler,
             handler_args: [],
             request_timeout_ms: 2_000,
             services: [sessions: []]
           ],
           extra
         )}
      )

    {:ok, runtime} = Runtime.ref(root)
    runtime
  end

  # These GET/DELETE fixtures test a short socket deadline, rather than HTTP initialize.
  # Set up their sessions through the supported addressed service API with one
  # separate finite cutoff and the installed Plug's private mount domain.
  # Other fixtures retain actual wire initialization.
  defp initialized_session(extra) do
    runtime = runtime(extra)
    opts = HttpPlug.init(runtime: runtime, protocol_mode: :legacy_only, sse_mode: :oneshot)
    {:ok, service} = Runtime.service(runtime, :sessions)
    setup = [deadline: System.monotonic_time(:millisecond) + 1_000]
    metadata = %{transport_endpoint: "/mcp"}
    {:ok, lease} = SessionManager.create_session(service, metadata, setup)
    {:ok, claim} = SessionManager.claim_initialization(service, lease, setup)
    assert :ok == SessionManager.complete_initialization(service, claim, "2025-11-25", setup)
    id = SessionLease.id(lease)
    {:ok, lease} = SessionManager.ensure_initialized_session(service, id, metadata, setup)
    {runtime, opts, id, service, lease}
  end

  defp initialize,
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "retained", "version" => "2"}
      }
    }

  defp get(id, opts, cursor \\ nil) do
    conn = session_conn(:get, id)
    conn = if cursor, do: Plug.Conn.put_req_header(conn, "last-event-id", cursor), else: conn
    HttpPlug.call(conn, opts)
  end

  defp session_conn(method, id),
    do:
      Plug.Test.conn(method, "/mcp")
      |> Plug.Conn.put_req_header("mcp-session-id", id)
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-11-25")
      |> Plug.Conn.put_req_header("accept", "text/event-stream")

  defp recording(conn, parent) do
    {_adapter, state} = conn.adapter

    %{
      conn
      | adapter: {RecordingAdapter, Map.merge(state, %{observer: parent, block_write: false})}
    }
  end

  defp socket do
    pid = spawn(fn -> socket_loop() end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp socket_loop do
    receive do
      {:call, from, token, fun} ->
        send(from, {token, fun.()})
        socket_loop()
    end
  end

  defp call(pid, fun) do
    token = make_ref()
    send(pid, {:call, self(), token, fun})
    assert_receive {^token, result}, 1_000
    result
  end

  defp settled(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    wait(fn -> HTTPWriterRegistry.stats(domain).frames == 0 end)
  end

  defp wait(fun, remaining \\ 200)
  defp wait(_fun, 0), do: flunk("retained HTTP credit did not settle")

  defp wait(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait(fun, remaining - 1)
        )
  end
end
