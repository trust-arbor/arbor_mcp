defmodule Arbor.MCP.Server.HTTPRuntimeStartupTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Runtime.Initialization, as: RuntimeInitialization

  alias Arbor.MCP.Server.HTTP.Bandit.{Connection, ConnectionSlots, Options}
  alias Arbor.MCP.Server.HTTP.CowboyClaims
  alias Arbor.MCP.Server.Runtime.{Admission, Config, Deadline, Initialization, Ref, Services}
  alias Arbor.MCP.Server.{Runtime, Transport}

  import ExUnit.CaptureLog

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      if opts[:test], do: send(opts[:test], {:http_init, self()})
      {:ok, %{test: opts[:test], count: 0}}
    end
  end

  defmodule DSLHandler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "owned-http", version: "2.0.0"
  end

  defmodule ParityPlug do
    def init(options), do: options
    def call(conn, _options), do: Plug.Conn.send_resp(conn, 200, "parity")
  end

  defmodule HeldPlug do
    def init(parent) do
      send(parent, {:held_stock_plug, self()})
      receive do: (:release -> parent)
    end

    def call(conn, _parent), do: Plug.Conn.send_resp(conn, 200, "borrowed")
  end

  defmodule HeldConnectionName do
    def whereis_name(_name), do: :undefined

    def register_name(parent, pid) do
      send(parent, {:connection_registration, pid})
      receive do: (:release -> :yes)
    end

    def unregister_name(_name), do: :ok
  end

  test "HTTP configuration rejects removed or invalid constructors before handler effects" do
    for {opts, reason} <- [
          {[http: [adapter: :unknown]], {:unsupported_http_adapter, :unknown}},
          {[http: %{}], :invalid_http_options},
          {[http: [port: -1]], :invalid_http_port},
          {[http: [host: :invalid]], :invalid_http_host},
          {[http: [listener_options: %{}]], :invalid_http_listener_options},
          {[sse_enabled: true], {:retired_http_option, :sse_enabled}},
          {[use_sse: true], {:retired_http_option, :use_sse}},
          {[handler_call_timeout: 1], {:retired_http_option, :handler_call_timeout}},
          {[session_manager: self()], {:retired_http_option, :session_manager}},
          {[http: [listener_options: [transport_options: [socket: :borrowed_socket]]]],
           :http_listener_ownership_override},
          {[http: [handler: DSLHandler]], :invalid_http_options},
          {[http: [adapter: :bandit, ranch_ref: make_ref()]],
           {:unsupported_http_option, :bandit, :ranch_ref}},
          {[
             http: [
               adapter: :bandit,
               listener_options: [thousand_island_options: [transport_module: Handler]]
             ]
           ], :http_listener_ownership_override},
          {[http: [adapter: :bandit, listener_options: [http_options: [unknown: true]]]],
           :invalid_http_listener_options},
          {[
             http: [
               adapter: :bandit,
               listener_options: [
                 thousand_island_options: [num_listen_sockets: 2, num_acceptors: 1]
               ]
             ]
           ], :invalid_http_listener_options},
          {[
             http: [
               adapter: :bandit,
               listener_options: [
                 thousand_island_options: [genserver_options: [timeout: :infinity]]
               ]
             ]
           ], :invalid_http_listener_options}
        ] do
      assert {:error, ^reason} =
               Runtime.start_link(
                 [handler: Handler, handler_args: [test: self()], transport: :http] ++ opts
               )
    end

    refute_receive {:http_init, _}, 10
  end

  test "transport-specific owned ETS defaults respect explicit descriptors and disabled services" do
    assert {:ok, generic} = Config.new(handler: Handler)
    assert generic.services.sessions == nil
    assert {:ok, owned} = Config.new(handler: Handler, transport: :http)
    assert owned.services.sessions.ownership == :owned
    assert owned.services.resource_subscriptions.ownership == :owned
    assert owned.services.replay_cache == nil
    assert {:ok, mounted} = Config.new(handler: Handler, transport: :mounted_http)
    assert mounted.services.sessions.ownership == :owned

    assert {:ok, disabled} =
             Config.new(
               handler: Handler,
               transport: :http,
               services: [sessions: false, resource_subscriptions: nil]
             )

    assert disabled.services.sessions == nil
    assert disabled.services.resource_subscriptions == nil

    assert {:ok, modern} =
             Config.new(handler: Handler, transport: :http, http: [protocol_mode: :modern_only])

    assert modern.services.sessions == nil
    assert modern.services.resource_subscriptions == nil
  end

  test "borrowed helper requires the matching explicit healthy runtime" do
    assert {:error, :http_runtime_required} =
             Transport.start_http_server(Handler, %{}, [], port: 0)

    runtime = start_supervised!({Runtime, handler: Handler})

    assert {:error, :http_runtime_handler_mismatch} =
             Transport.start_http_server(DSLHandler, %{}, [], runtime: runtime, port: 0)

    assert {:error, :http_listener_unavailable} = Transport.http_listener(runtime)
  end

  test "an expired borrowed claim cannot free a live constructor's reference" do
    {:ok, pid} = CowboyClaims.start_link(global: false)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {:ok, authority} = CowboyClaims.reference(pid)
    reference = make_ref()
    parent = self()

    caller =
      spawn(fn ->
        deadline = Deadline.now() + 30
        {:ok, lease} = CowboyClaims.borrowed(reference, deadline, authority)
        send(parent, {:borrowed_claimed, deadline, lease})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:borrowed_claimed, cutoff, _lease}, 1_000
    await(fn -> Deadline.now() >= cutoff + 30 end)

    assert {:error, :http_listener_reference_in_use} =
             CowboyClaims.acquire(reference, Deadline.now() + 1_000, authority)

    assert %{domains: 1, barriers: 0} = CowboyClaims.stats(authority)
    monitor = Process.monitor(caller)
    send(caller, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    await(fn -> match?(%{domains: 0}, CowboyClaims.stats(authority)) end)
    assert {:ok, _lease} = CowboyClaims.acquire(reference, Deadline.now() + 1_000, authority)
  end

  test "invalid oversized shutdown timeout rejects before starting a worker" do
    assert {:error, :invalid_http_shutdown_timeout} =
             Arbor.MCP.Server.HTTP.ListenerAdapter.bounded(
               :cowboy,
               :shutdown,
               4_294_967_296,
               fn -> flunk("invalid timeout must not execute shutdown") end
             )
  end

  @tag :physical_http
  test "a live borrowed stock plug cannot mutate an owned ref after its claim cutoff" do
    parent = self()
    reference = make_ref()
    started = Deadline.now()

    caller =
      spawn(fn ->
        result =
          Arbor.MCP.Server.HTTP.Cowboy.start(HeldPlug, parent,
            ref: reference,
            port: 0,
            ip: {127, 0, 0, 1}
          )

        send(parent, {:held_stock_result, result})
        receive do: (:finish -> :ok)
      end)

    on_exit(fn ->
      send(caller, :release)
      Arbor.MCP.Server.HTTP.Cowboy.stop(reference)
      send(caller, :finish)
    end)

    assert_receive {:held_stock_plug, ^caller}, 1_000
    await(fn -> Deadline.now() >= started + 10_100 end, started + 11_000)

    assert {:error, :http_listener_reference_in_use} =
             Runtime.start_link(
               handler: Handler,
               handler_args: [test: parent],
               transport: :http,
               http: [ranch_ref: reference, port: 0]
             )

    refute_receive {:http_init, _}, 10
    send(caller, :release)
    assert_receive {:held_stock_result, {:ok, borrowed}}, 1_000
    assert :ranch_server.get_listener_sup(reference) == borrowed
    assert Process.alive?(borrowed)

    assert {:error, :http_listener_reference_in_use} =
             Runtime.start_link(
               handler: Handler,
               transport: :http,
               http: [ranch_ref: reference, port: 0]
             )
  end

  @tag :physical_http
  test "Cowboy owned root preserves native supervision, one initialization, and exact Ranch identity" do
    root_name = {:global, {__MODULE__, make_ref()}}

    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test: self()],
         name: root_name,
         transport: :http,
         http: [port: 0, host: {127, 0, 0, 1}]}
      )

    assert_receive {:http_init, scheduler}, 1_000
    assert {:ok, runtime} = Runtime.ref(root_name)
    assert Ref.supervisor(runtime) == root
    assert :proc_lib.translate_initial_call(root) == {:supervisor, Runtime, 1}

    assert {:ok, %{listener: listener, adapter: :cowboy, ranch_ref: ranch_ref}} =
             Transport.http_listener(runtime)

    assert :ranch_server.get_listener_sup(ranch_ref) == listener

    assert :proc_lib.translate_initial_call(listener) ==
             {:supervisor, Arbor.MCP.Server.HTTP.Cowboy.Owned, 1}

    http_supervisor = child(root, Arbor.MCP.Server.HTTP.Supervisor)
    assert {:dictionary, dictionary} = Process.info(listener, :dictionary)
    assert hd(dictionary[:"$ancestors"]) == http_supervisor
    acceptors = child(listener, :ranch_acceptors_sup)
    acceptor_children = Supervisor.which_children(acceptors)
    expected_acceptors = Map.get(:ranch.get_transport_options(ranch_ref), :num_acceptors, 10)
    assert length(acceptor_children) == expected_acceptors

    acceptor_monitors =
      for {_id, pid, :worker, _modules} <- acceptor_children do
        assert :proc_lib.translate_initial_call(pid) ==
                 {Arbor.MCP.Server.HTTP.Cowboy.Owned, :init_acceptor, 1}

        assert {:dictionary, native} = Process.info(pid, :dictionary)
        assert hd(native[:"$ancestors"]) == acceptors
        assert :ets.member(Ref.table(runtime), {:runtime_owned, pid})
        {pid, Process.monitor(pid)}
      end

    assert Process.alive?(scheduler)
    port = :ranch.get_port(ranch_ref)
    initialize(port, 1)
    initialize(port, 2)
    refute_receive {:http_init, _}, 10
    assert :ok = Supervisor.terminate_child(test_supervisor(), Runtime)
    await_closed(port)
    refute Process.alive?(listener)

    for {pid, monitor} <- acceptor_monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _reason}, 1_000)

    assert {:error, :runtime_unavailable} = Runtime.ref(runtime)
  end

  @tag :physical_http
  test "owned sibling Cowboy endpoints use independent default references and lifecycle" do
    first =
      start_supervised!(
        {Runtime,
         id: :first_http,
         handler: Handler,
         transport: :http,
         http: [port: 0, host: {127, 0, 0, 1}]}
      )

    second =
      start_supervised!(
        {Runtime,
         id: :second_http,
         handler: Handler,
         transport: :http,
         http: [port: 0, host: {127, 0, 0, 1}]}
      )

    {:ok, a} = Transport.http_listener(first)
    {:ok, b} = Transport.http_listener(second)
    assert a.ranch_ref != b.ranch_ref
    port = :ranch.get_port(a.ranch_ref)
    assert :ok = Supervisor.terminate_child(test_supervisor(), :first_http)
    await_closed(port)
    assert Process.alive?(second)
    initialize(:ranch.get_port(b.ranch_ref), 3)
  end

  @tag :physical_http
  test "DSL HTTP startup returns a runtime and Bandit is its actual owned child" do
    {:ok, root} =
      DSLHandler.start_link(
        transport: :http,
        http_adapter: :bandit,
        port: 0,
        host: {127, 0, 0, 1},
        http_listener_options: [startup_log: false]
      )

    on_exit(fn -> Runtime.stop(root) end)
    assert {:ok, runtime} = Runtime.ref(root)

    assert {:ok, %{listener: listener, adapter: :bandit, ranch_ref: nil}} =
             Transport.http_listener(root)

    assert {:dictionary, dictionary} = Process.info(listener, :dictionary)
    assert hd(dictionary[:"$ancestors"]) == child(root, Arbor.MCP.Server.HTTP.Supervisor)

    assert :proc_lib.translate_initial_call(listener) ==
             {:supervisor, Arbor.MCP.Server.HTTP.Bandit.Owned, 1}

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    result = initialize(port, 4)
    assert result["serverInfo"] == %{"name" => "owned-http", "version" => "2.0.0"}
    assert :ok = Runtime.stop(runtime)
    await_closed(port)
    refute Process.alive?(listener)
  end

  @tag :physical_http
  test "owned Bandit registers its actual listener before a held native startup acknowledgement" do
    parent = self()
    attach_held_bandit(parent)
    started = Deadline.now()

    caller =
      spawn(fn ->
        result =
          Runtime.start_link(
            handler: Handler,
            handler_args: [test: parent],
            transport: :http,
            init_timeout_ms: 1_000,
            shutdown_timeout_ms: 100,
            http: [
              adapter: :bandit,
              port: 0,
              host: {127, 0, 0, 1},
              listener_options: [startup_log: false, thousand_island_options: [num_acceptors: 1]]
            ]
          )

        send(parent, {:held_bandit_result, result})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:http_init, _scheduler}, 1_000
    assert_receive {:held_bandit_listener, listener, port, ancestors}, 1_000

    assert :proc_lib.translate_initial_call(listener) ==
             {Arbor.MCP.Server.HTTP.Bandit.Worker, :init, 1}

    [backend, http, root | _] = ancestors

    assert :proc_lib.translate_initial_call(backend) ==
             {:supervisor, Arbor.MCP.Server.HTTP.Bandit.Owned, 1}

    assert :proc_lib.translate_initial_call(http) ==
             {:supervisor, Arbor.MCP.Server.HTTP.Supervisor, 1}

    assert :proc_lib.translate_initial_call(root) == {:supervisor, Runtime, 1}
    listener_monitor = Process.monitor(listener)
    root_monitor = Process.monitor(root)
    assert_receive {:held_bandit_result, {:error, :runtime_init_timeout}}, 1_500
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert_receive {:DOWN, ^listener_monitor, :process, ^listener, _}, 1_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _}, 1_000
    assert Deadline.now() - started < 2_000
    await_closed(port)
  end

  @tag :physical_http
  test "owned Bandit pre-ack descendants retire when their real native parent dies" do
    attach_held_bandit(self())
    parent = self()
    started = Deadline.now()

    caller =
      spawn(fn ->
        Runtime.start_link(
          handler: Handler,
          transport: :http,
          init_timeout_ms: 1_000,
          shutdown_timeout_ms: 100,
          http: [
            adapter: :bandit,
            port: 0,
            host: {127, 0, 0, 1},
            listener_options: [startup_log: false, thousand_island_options: [num_acceptors: 1]]
          ]
        )

        send(parent, :unexpected_bandit_success)
      end)

    assert_receive {:held_bandit_listener, listener, port, ancestors}, 1_000
    [backend, http, root | _] = ancestors
    monitors = Enum.map([listener, backend, http, root], &{&1, Process.monitor(&1)})
    Process.exit(caller, :kill)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_500
    end

    assert Deadline.now() - started < 2_000
    refute_receive :unexpected_bandit_success, 10
    await_closed(port)
  end

  @tag :physical_http
  test "native owned Bandit failed init omits raw auth options and leaves a borrowed socket alive" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)

    log =
      capture_log(fn ->
        assert {:error, _} =
                 Runtime.start_link(
                   handler: Handler,
                   transport: :http,
                   http: [
                     adapter: :bandit,
                     port: port,
                     host: {127, 0, 0, 1},
                     auth_config: %{sentinel: "bandit-auth-secret-94"},
                     listener_options: [
                       startup_log: false,
                       thousand_island_options: [num_acceptors: 1]
                     ]
                   ]
                 )
      end)

    refute log =~ "bandit-auth-secret-94"
    assert {:ok, probe} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
    :gen_tcp.close(probe)
  end

  @tag :physical_http
  test "owned Bandit HTTP option transformation equals the pinned stock constructor" do
    Code.ensure_loaded!(ThousandIsland.ServerConfig)
    collector = spawn(fn -> collect_config(nil) end)
    # The actual stock start passes this pure config through ServerConfig.new/1.
    assert 1 ==
             :erlang.trace_pattern(
               {ThousandIsland.ServerConfig, :new, 1},
               [{:_, [], [{:return_trace}]}],
               []
             )

    on_exit(fn -> :erlang.trace_pattern({ThousandIsland.ServerConfig, :new, 1}, false, []) end)

    variants = [
      [],
      [
        http_options: [compress: false, log_protocol_errors: false],
        http_1_options: [enabled: true, max_header_count: 20, clear_process_dict: false],
        http_2_options: [enabled: false, max_requests: 25],
        websocket_options: [enabled: false, max_frame_size: 2_048]
      ],
      [
        thousand_island_options: [
          port: 0,
          num_acceptors: 1,
          num_connections: 5,
          read_timeout: 2_000,
          shutdown_timeout: 500,
          transport_options: [ip: {127, 0, 0, 1}, nodelay: true]
        ]
      ]
    ]

    for variant <- variants do
      options =
        Keyword.merge(
          [
            plug: {ParityPlug, [application: :unchanged]},
            port: 0,
            ip: {127, 0, 0, 1},
            startup_log: false,
            thousand_island_options: [num_acceptors: 1]
          ],
          variant
        )

      :erlang.trace(self(), true, [:call, {:tracer, collector}])
      {:ok, stock} = Bandit.start_link(options)
      :erlang.trace(self(), false, [:call])
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^delivered}, 1_000
      send(collector, {:take, self()})
      assert_receive {:stock_config, expected}, 1_000
      assert Options.compile(options) == expected
      Supervisor.stop(stock)
    end

    Process.exit(collector, :kill)
  end

  @tag :physical_http
  test "owned Bandit registers future physical request workers before borrowed socket work" do
    {:ok, root} =
      Runtime.start_link(
        handler: Handler,
        transport: :http,
        shutdown_timeout_ms: 100,
        http: [
          adapter: :bandit,
          port: 0,
          host: {127, 0, 0, 1},
          listener_options: [startup_log: false, thousand_island_options: [num_acceptors: 1]]
        ]
      )

    on_exit(fn -> Runtime.stop(root) end)
    {:ok, runtime} = Runtime.ref(root)
    {:ok, %{listener: listener}} = Transport.http_listener(root)
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:bandit, :request, :start],
        fn _event, _measurements, _metadata, target ->
          send(target, {:held_bandit_request, self()})
          receive do: (:release -> :ok)
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
    on_exit(fn -> :gen_tcp.close(socket) end)

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 97,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "held-connection", version: "1"}
        }
      })

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nHost: localhost\r\n",
        "Content-Type: application/json\r\nAccept: application/json\r\n",
        "Mcp-Protocol-Version: 2025-11-25\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    assert_receive {:held_bandit_request, connection}, 1_000

    assert :proc_lib.translate_initial_call(connection) ==
             {Arbor.MCP.Server.HTTP.Bandit.Connection, :init, 1}

    assert %{retained: 1, limit: 1_024} =
             ConnectionSlots.stats(runtime)

    monitor = Process.monitor(connection)
    started = Deadline.now()
    assert :ok = Runtime.stop(root)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _}, 1_000
    assert Deadline.now() - started < 1_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 500)
    await_closed(port)
  end

  test "stalled owned connection registration retains at most 1024 physical startup obligations" do
    {:ok, root} = Runtime.start_link(handler: Handler)
    on_exit(fn -> Runtime.stop(root) end)
    {:ok, runtime} = Runtime.ref(root)
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    :sys.suspend(guard)
    on_exit(fn -> if Process.alive?(guard), do: :sys.resume(guard) end)
    parent = self()

    callers =
      for _ <- 1..1_100 do
        owned_producer(runtime, fn ->
          result =
            Connection.start_link({{runtime, %{}}, [timeout: 2_000]})

          send(parent, {:bounded_connection_result, self(), result})
          receive do: (:finish -> :ok)
        end)
      end

    on_exit(fn -> Enum.each(callers, &Process.exit(&1, :kill)) end)

    await(fn ->
      case Process.info(guard, :message_queue_len) do
        {:message_queue_len, count} -> count >= 900
        _ -> false
      end
    end)

    assert %{limit: 1_024, retained: retained} =
             ConnectionSlots.stats(runtime)

    assert retained <= 1_024
    assert {:message_queue_len, controls} = Process.info(guard, :message_queue_len)
    assert controls <= 1_024
    assert_receive {:bounded_connection_result, _producer, {:error, :max_children}}, 1_000
    # Original cutoffs retire actual native children while the guard remains stalled.
    await(
      fn -> ConnectionSlots.stats(runtime).retained == 0 end,
      Deadline.now() + 3_000
    )

    :sys.resume(guard)
    assert :ok = Runtime.stop(root)
    Enum.each(callers, &send(&1, :finish))
  end

  test "Admission replacement preserves old native liabilities and exact-token capacity" do
    root = start_supervised!({Runtime, handler: Handler})
    {:ok, runtime} = Runtime.ref(root)
    table = Ref.table(runtime)
    {:ok, %{epoch: old_epoch}} = Initialization.current(table)
    connection_result = make_ref()
    parent = self()

    owned_producer(runtime, fn ->
      result = Connection.start_link({{runtime, %{}}, []})
      if match?({:ok, _}, result), do: Process.unlink(elem(result, 1))
      send(parent, {connection_result, result})
    end)

    assert_receive {^connection_result, {:ok, connection}}, 1_000
    on_exit(fn -> if Process.alive?(connection), do: Process.exit(connection, :kill) end)
    deadline = Deadline.now() + 10_000
    pending = fill_connection_slots(runtime, deadline, [], 10_000)
    assert length(pending) == 1_023
    assert %{retained: 1_024} = ConnectionSlots.stats(runtime)
    old_pending = hd(pending)
    old_admission = child(root, Admission)
    Process.exit(old_admission, :kill)

    await(fn ->
      case Initialization.current(table) do
        {:ok, %{status: :ready, epoch: epoch}} -> epoch != old_epoch
        _ -> false
      end
    end)

    assert child(root, Admission) != old_admission
    assert Process.alive?(connection)
    assert %{retained: 1_024} = ConnectionSlots.stats(runtime)
    assert {:error, :max_children} = ConnectionSlots.reserve(runtime, deadline)
    assert {:error, :max_children} = ConnectionSlots.bind(old_pending)
    # A stale constructor may retire its exact pending token, but cannot remove
    # a newly admitted obligation that reuses that same physical slot.
    assert :ok = ConnectionSlots.release(old_pending)
    {:ok, fresh} = reserve_connection_slot(runtime, deadline, 10_000)
    assert :ok = ConnectionSlots.release(old_pending)
    assert %{retained: 1_024} = ConnectionSlots.stats(runtime)
    assert {:ok, ^fresh} = ConnectionSlots.bind(fresh)
    monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}, 1_000
    assert %{retained: 1_023} = ConnectionSlots.stats(runtime)
  end

  test "a suspended native connection constructor cannot accept success after its original cutoff" do
    root = start_supervised!({Runtime, handler: Handler})
    {:ok, runtime} = Runtime.ref(root)
    parent = self()

    caller =
      owned_producer(runtime, fn ->
        result =
          Connection.start_link(
            {{runtime, %{}}, [timeout: 1_000, name: {:via, HeldConnectionName, parent}]}
          )

        send(parent, {:late_connection_result, result})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:connection_registration, connection}, 1_000
    true = :erlang.suspend_process(caller)
    monitor = Process.monitor(connection)
    send(connection, :release)
    assert %{state: {nil, %{}}, deadline: cutoff} = :sys.get_state(connection, 1_000)
    await(fn -> Deadline.now() >= cutoff end)
    true = :erlang.resume_process(caller)
    assert_receive {:late_connection_result, {:error, reason}}, 1_000
    assert reason in [:max_children, :timeout]
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^connection, _}, 1_000
    assert %{retained: 0} = ConnectionSlots.stats(runtime)
  end

  test "owned metadata cleanup atomically preserves changed exact objects" do
    table = :ets.new(__MODULE__, [:set])
    old = [{{:trans_opts, :reference}, %{marker: :old}}, {{:proto_opts, :reference}, :old}]
    :ets.insert(table, old)
    :ets.insert(table, {{:proto_opts, :reference}, :host_replacement})
    assert {:error, :changed_http_metadata} = CowboyClaims.cleanup_objects(table, old)

    assert [{{:proto_opts, :reference}, :host_replacement}] ==
             :ets.lookup(table, {:proto_opts, :reference})

    :ets.delete(table)
  end

  @tag :physical_http
  test "raw host replacement metadata quarantines old owned claims without deleting the host" do
    {:ok, authority_pid} = CowboyClaims.start_link(global: false)
    Process.unlink(authority_pid)
    on_exit(fn -> if Process.alive?(authority_pid), do: Process.exit(authority_pid, :kill) end)
    {:ok, authority} = CowboyClaims.reference(authority_pid)
    reference = make_ref()
    deadline = Deadline.now() + 5_000

    {:ok, config} =
      Config.new(handler: Handler, transport: :http, http: [ranch_ref: reference, port: 0])

    {:ok, lease} = CowboyClaims.acquire(reference, deadline, authority)

    {:ok, root} =
      RuntimeInitialization.start_configured(
        [],
        %{config | http: Map.put(config.http, :lease, lease)},
        deadline
      )

    Process.unlink(root)
    {:ok, %{listener: old_listener}} = Transport.http_listener(root)
    monitor = Process.monitor(old_listener)
    :sys.suspend(authority_pid)
    on_exit(fn -> if Process.alive?(authority_pid), do: :sys.resume(authority_pid) end)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_listener, _}, 1_000
    {:ok, host} = Plug.Cowboy.http(ParityPlug, [], ref: reference, port: 0, ip: {127, 0, 0, 1})
    on_exit(fn -> Plug.Cowboy.shutdown(reference) end)
    expected = :ets.lookup(:ranch_server, {:listener_start_args, reference})
    :sys.resume(authority_pid)
    await(fn -> CowboyClaims.validate(lease) == {:error, :http_listener_claims_unavailable} end)
    assert Process.alive?(host)
    assert :ranch_server.get_listener_sup(reference) == host
    assert expected == :ets.lookup(:ranch_server, {:listener_start_args, reference})
    assert %{domains: 1} = CowboyClaims.stats(authority)

    assert {:error, :http_listener_reference_in_use} =
             CowboyClaims.acquire(reference, Deadline.now() + 1_000, authority)

    {:ok, probe} =
      :gen_tcp.connect({127, 0, 0, 1}, :ranch.get_port(reference), [:binary, active: false], 500)

    :gen_tcp.close(probe)
  end

  @tag :physical_http
  test "an explicit standalone listener borrows runtime lifetime in both directions" do
    root = start_supervised!({Runtime, handler: Handler, transport: :mounted_http})
    {:ok, runtime} = Runtime.ref(root)
    ref = make_ref()

    {:ok, listener} =
      Transport.start_http_server(Handler, %{}, [],
        runtime: runtime,
        ranch_ref: ref,
        port: 0,
        host: {127, 0, 0, 1}
      )

    on_exit(fn -> Transport.stop_http_server(ref) end)
    port = :ranch.get_port(ref)
    initialize(port, 5)
    assert :ok = Supervisor.terminate_child(test_supervisor(), Runtime)
    assert Process.alive?(listener)
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
    :gen_tcp.close(socket)
    assert :ok = Transport.stop_http_server(ref)
    await_closed(port)
  end

  @tag :physical_http
  test "owned listener death replaces the supervised root and invalidates the prior reference" do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test: self()],
         transport: :http,
         http: [port: 0, host: {127, 0, 0, 1}]}
      )

    assert_receive {:http_init, _}, 1_000
    {:ok, previous} = Runtime.ref(root)
    {:ok, %{listener: listener}} = Transport.http_listener(root)
    monitor = Process.monitor(root)
    Process.exit(listener, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 2_000
    assert_receive {:http_init, _}, 2_000

    replacement =
      await(fn ->
        case child(test_supervisor(), Runtime) do
          pid when is_pid(pid) and pid != root -> pid
          _ -> false
        end
      end)

    assert {:ok, _} = Transport.http_listener(replacement)
    assert {:error, :runtime_unavailable} = Runtime.ref(previous)
  end

  @tag :physical_http
  test "simultaneous roots cannot own the same explicit Ranch reference" do
    parent = self()
    ref = make_ref()

    starters =
      for _ <- 1..2 do
        spawn(fn ->
          receive do: (:start -> :ok)

          result =
            Runtime.start_link(
              handler: Handler,
              handler_args: [test: parent],
              transport: :http,
              http: [port: 0, ranch_ref: ref]
            )

          send(parent, {:contended_http, self(), result})
          receive do: (:finish -> :ok)
        end)
      end

    Enum.each(starters, &send(&1, :start))
    assert_receive {:contended_http, first, first_result}, 2_000
    assert_receive {:contended_http, second, second_result}, 2_000
    results = [first_result, second_result]
    assert [{:ok, root}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, :http_listener_reference_in_use} in results
    assert_receive {:http_init, _}, 1_000
    refute_receive {:http_init, _}, 10
    {:ok, %{listener: listener}} = Transport.http_listener(root)
    assert :ranch_server.get_listener_sup(ref) == listener
    assert :ok = Runtime.stop(root)
    Enum.each([first, second], &send(&1, :finish))
  end

  @tag :physical_http
  test "owned claims fence stock helper startup and cannot delete borrowed metadata" do
    root = start_supervised!({Runtime, handler: Handler, transport: :mounted_http})
    ref = make_ref()

    {:ok, listener} =
      Transport.start_http_server(Handler, %{}, [], runtime: root, ranch_ref: ref, port: 0)

    on_exit(fn -> Transport.stop_http_server(ref) end)

    assert {:error, :http_listener_reference_in_use} =
             Runtime.start_link(
               handler: Handler,
               handler_args: [test: self()],
               transport: :http,
               http: [port: 0, ranch_ref: ref]
             )

    refute_receive {:http_init, _}, 10
    assert :ranch_server.get_listener_sup(ref) == listener
    initialize(:ranch.get_port(ref), 10)

    owned =
      start_supervised!(
        {Runtime, id: :owned, handler: Handler, transport: :http, http: [port: 0]}
      )

    {:ok, %{ranch_ref: owned_ref}} = Transport.http_listener(owned)

    assert {:error, :http_listener_reference_in_use} =
             Transport.start_http_server(Handler, %{}, [],
               runtime: root,
               ranch_ref: owned_ref,
               port: 0
             )

    assert Process.alive?(owned)
  end

  @tag :physical_http
  test "a held stock constructor excludes owned construction through unknown settlement" do
    root = start_supervised!({Runtime, handler: Handler, transport: :mounted_http})
    parent = self()
    ref = make_ref()
    :sys.suspend(:ranch_server)
    on_exit(fn -> if Process.whereis(:ranch_server), do: :sys.resume(:ranch_server) end)

    caller =
      spawn(fn ->
        result =
          Transport.start_http_server(Handler, %{}, [], runtime: root, ranch_ref: ref, port: 0)

        send(parent, {:stock_started, result})
      end)

    await(fn -> CowboyClaims.borrowed_available?(ref) != :ok end)

    assert {:error, :http_listener_reference_in_use} =
             Runtime.start_link(
               handler: Handler,
               handler_args: [test: parent],
               transport: :http,
               http: [port: 0, ranch_ref: ref]
             )

    refute_receive {:http_init, _}, 10
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000
    assert {:error, :http_listener_reference_in_use} = CowboyClaims.borrowed_available?(ref)
    :sys.resume(:ranch_server)

    listener =
      await(fn ->
        case ranch_listener(ref) do
          {:ok, pid} -> pid
          _ -> false
        end
      end)

    await(fn -> CowboyClaims.borrowed_available?(ref) == :ok end)
    assert Process.alive?(listener)
    initialize(:ranch.get_port(ref), 11)
    assert :ok = Transport.stop_http_server(ref)
  end

  @tag :physical_http
  test "completed owned cohort replacement preserves the root and creates one new listener" do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test: self()],
         transport: :http,
         http: [port: 0, host: {127, 0, 0, 1}]}
      )

    assert_receive {:http_init, _}, 1_000
    {:ok, runtime} = Runtime.ref(root)
    {:ok, previous} = Transport.http_listener(root)
    {:ok, binding} = Services.resolve(runtime, :tasks)
    previous_port = :ranch.get_port(previous.ranch_ref)
    Process.exit(binding.server, :kill)
    assert_receive {:http_init, _}, 2_000

    next =
      await(fn ->
        case Transport.http_listener(runtime) do
          {:ok, %{listener: listener} = info} when listener != previous.listener -> info
          _ -> false
        end
      end)

    assert Process.alive?(root)
    assert {:ok, ^runtime} = Runtime.ref(runtime)
    assert previous.ranch_ref == next.ranch_ref
    refute Process.alive?(previous.listener)
    await_closed(previous_port)
    initialize(:ranch.get_port(next.ranch_ref), 12)
  end

  @tag :physical_http
  test "private claim domains have a finite count and retire expired pre-root claims" do
    {:ok, pid} = CowboyClaims.start_link(global: false)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {:ok, authority} = CowboyClaims.reference(pid)
    deadline = Deadline.now() + 2_000

    leases =
      for _ <- 1..128 do
        assert {:ok, lease} = CowboyClaims.acquire(make_ref(), deadline, authority)
        lease
      end

    assert {:error, :http_listener_claim_capacity} =
             CowboyClaims.acquire(make_ref(), deadline, authority)

    assert %{domains: 128, monitors: 1, controls: 1} = CowboyClaims.stats(authority)

    assert {:error, :invalid_http_listener_reference} =
             CowboyClaims.acquire(:binary.copy("x", 4_097), deadline, authority)

    await(fn -> match?(%{domains: 0, monitors: 0}, CowboyClaims.stats(authority)) end)

    assert Enum.all?(
             leases,
             &(CowboyClaims.validate(&1) == {:error, :http_listener_claims_unavailable})
           )
  end

  @tag :physical_http
  test "a native owned listener failure omits application options and arbitrary Ranch identity" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    ref = {:secret_ranch_identity, "listener-secret-97"}
    parent = self()

    log =
      capture_log(fn ->
        assert {:error, _typed_error} =
                 Runtime.start_link(
                   handler: Handler,
                   handler_args: [test: parent, secret: "handler-secret-98"],
                   transport: :http,
                   http: [port: port, ranch_ref: ref]
                 )
      end)

    assert_receive {:http_init, _}, 1_000
    refute log =~ "listener-secret-97"
    refute log =~ "handler-secret-98"
    assert {:ok, probe} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
    :gen_tcp.close(probe)
  end

  @tag :physical_http
  test "claim authority death fails its owned endpoint closed while a borrowed listener survives" do
    {:ok, authority_pid} = CowboyClaims.start_link(global: false)
    Process.unlink(authority_pid)
    {:ok, authority} = CowboyClaims.reference(authority_pid)
    deadline = Deadline.now() + 5_000
    {:ok, config} = Config.new(handler: Handler, transport: :http, http: [port: 0])
    {:ok, lease} = CowboyClaims.acquire(config.http.ranch_ref, deadline, authority)
    config = %{config | http: Map.put(config.http, :lease, lease)}
    {:ok, root} = RuntimeInitialization.start_configured([], config, deadline)
    {:ok, %{listener: listener}} = Transport.http_listener(root)
    Process.unlink(root)
    monitor = Process.monitor(root)
    borrowed_root = start_supervised!({Runtime, handler: Handler, transport: :mounted_http})
    borrowed_ref = make_ref()

    {:ok, borrowed} =
      Transport.start_http_server(Handler, %{}, [],
        runtime: borrowed_root,
        ranch_ref: borrowed_ref,
        port: 0
      )

    on_exit(fn -> Transport.stop_http_server(borrowed_ref) end)
    Process.exit(authority_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 2_000
    refute Process.alive?(listener)
    assert Process.alive?(borrowed)
    assert {:error, :http_listener_claims_unavailable} = CowboyClaims.validate(lease)

    assert {:error, :http_listener_claims_unavailable} =
             CowboyClaims.acquire(make_ref(), Deadline.now() + 1_000, authority)

    initialize(:ranch.get_port(borrowed_ref), 13)
  end

  @tag :physical_http
  test "blocked native backend registration expires the original root cutoff without late listener" do
    Application.ensure_all_started(:plug_cowboy)
    :sys.suspend(:ranch_server)
    parent = self()
    ref = make_ref()

    caller =
      spawn(fn ->
        result =
          Runtime.start_link(
            handler: Handler,
            handler_args: [test: parent],
            transport: :http,
            init_timeout_ms: 1_000,
            shutdown_timeout_ms: 100,
            http: [port: 0, host: {127, 0, 0, 1}, ranch_ref: ref]
          )

        send(parent, {:blocked_http_start, result})
      end)

    on_exit(fn -> if Process.whereis(:ranch_server), do: :sys.resume(:ranch_server) end)
    monitor = Process.monitor(caller)
    assert_receive {:http_init, _}, 1_000
    assert_receive {:blocked_http_start, {:error, :runtime_init_timeout}}, 1_500
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    assert {:error, :http_listener_reference_in_use} = CowboyClaims.borrowed_available?(ref)
    :sys.resume(:ranch_server)
    await(fn -> CowboyClaims.borrowed_available?(ref) == :ok end)
    assert {:error, :badarg} = ranch_listener(ref)

    for key <- [:max_conns, :trans_opts, :proto_opts, :listener_start_args, :listener_sup] do
      assert [] == :ets.lookup(:ranch_server, {key, ref})
    end
  end

  # One actual native child of the Runtime task supervisor creates native
  # producers; neither test processes nor borrowed hosts are adopted as owned.
  defp owned_producer(runtime, fun) do
    table = Ref.table(runtime)
    key = {__MODULE__, :producer_parent, table}

    factory =
      case Process.get(key) do
        nil ->
          [{:callback_tasks, supervisor}] = :ets.lookup(table, :callback_tasks)
          caller = self()
          ready = make_ref()

          {:ok, factory} =
            Task.Supervisor.start_child(supervisor, fn ->
              :ok = Initialization.track(table, self())
              send(caller, {ready, self()})
              producer_loop(table)
            end)

          assert_receive {^ready, ^factory}, 1_000
          on_exit(fn -> if Process.alive?(factory), do: Process.exit(factory, :kill) end)
          Process.put(key, factory)
          factory

        factory ->
          factory
      end

    tag = make_ref()
    send(factory, {:producer, self(), tag, fun})
    assert_receive {^tag, producer}, 1_000
    producer
  end

  defp producer_loop(table) do
    receive do
      {:producer, caller, tag, fun} ->
        producer =
          :proc_lib.spawn_link(fn ->
            :ok = Initialization.track(table, self())
            fun.()
          end)

        send(caller, {tag, producer})
        producer_loop(table)
    end
  end

  defp ranch_listener(ref) do
    {:ok, :ranch_server.get_listener_sup(ref)}
  rescue
    ArgumentError -> {:error, :badarg}
  end

  defp attach_held_bandit(parent) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:thousand_island, :listener, :start],
        fn _event, _measurements, metadata, target ->
          {:dictionary, dictionary} = Process.info(self(), :dictionary)

          send(
            target,
            {:held_bandit_listener, self(), metadata.local_port, dictionary[:"$ancestors"]}
          )

          receive do: (:release -> :ok)
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp collect_config(config) do
    receive do
      {:trace, _pid, :return_from, {ThousandIsland.ServerConfig, :new, 1}, next} ->
        collect_config(next)

      {:take, parent} ->
        send(parent, {:stock_config, config})
        collect_config(nil)

      _message ->
        collect_config(config)
    end
  end

  defp initialize(port, id) do
    Application.ensure_all_started(:inets)

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: id,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "listener-proof", version: "1.0.0"}
        }
      })

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"},
      {~c"mcp-protocol-version", ~c"2025-11-25"}
    ]

    {:ok, {{_, 200, _}, _headers, wire}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{port}/mcp", headers, ~c"application/json", body},
        [timeout: 2_000],
        []
      )

    Jason.decode!(wire)["result"]
  end

  defp fill_connection_slots(_runtime, _deadline, pending, 0), do: pending

  defp fill_connection_slots(runtime, deadline, pending, attempts) do
    if ConnectionSlots.stats(runtime).retained == 1_024 do
      pending
    else
      case ConnectionSlots.reserve(runtime, deadline) do
        {:ok, reservation} ->
          fill_connection_slots(runtime, deadline, [reservation | pending], attempts - 1)

        {:error, :max_children} ->
          fill_connection_slots(runtime, deadline, pending, attempts - 1)
      end
    end
  end

  defp reserve_connection_slot(_runtime, _deadline, 0), do: {:error, :max_children}

  defp reserve_connection_slot(runtime, deadline, attempts) do
    case ConnectionSlots.reserve(runtime, deadline) do
      {:ok, _reservation} = result -> result
      {:error, :max_children} -> reserve_connection_slot(runtime, deadline, attempts - 1)
    end
  end

  defp test_supervisor do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    supervisor
  end

  defp child(parent, id) do
    case List.keyfind(Supervisor.which_children(parent), id, 0) do
      {^id, pid, _, _} -> pid
      _ -> nil
    end
  end

  defp await_closed(port) do
    await(fn ->
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          false

        {:error, :econnrefused} ->
          true

        _ ->
          false
      end
    end)
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 2_000)

  defp await(fun, deadline) do
    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        await(fun, deadline)
    end
  end
end
