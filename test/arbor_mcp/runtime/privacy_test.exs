defmodule Arbor.MCP.Server.Runtime.PrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Server.{ReplayCache, Runtime, SubscriptionListener}
  alias Arbor.MCP.Server.Runtime.{Admission, Ref, Services}
  alias Arbor.MCP.Tasks

  setup do
    filters = :logger.get_primary_config().filters

    enabled =
      Enum.map(filters, fn
        {:logger_translator, {translator, options}} ->
          {:logger_translator, {translator, Map.put(options, :sasl, true)}}

        filter ->
          filter
      end)

    :ok = :logger.set_primary_config(:filters, enabled)
    on_exit(fn -> :logger.set_primary_config(:filters, filters) end)
    :ok
  end

  defmodule Handler do
    def init(opts) do
      if opts[:raise_init], do: raise(opts[:secret])
      send(opts[:owner], {:initialized, self()})

      {:ok,
       %{owner: opts[:owner], secret: opts[:secret], raise_terminate: opts[:raise_terminate]}}
    end

    def terminate(_reason, state) do
      send(state.owner, {:terminated, self()})
      if state.raise_terminate, do: raise(state.secret)
      :ok
    end

    def dispatch(request, _module, state, _opts) do
      send(state.owner, {:held_callback, self()})

      receive do
        :release ->
          {:response, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => true}, state}
      end
    end
  end

  defmodule DSLHandler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    @impl true
    def init(opts) do
      send(opts[:owner], {:initialized, self()})
      {:ok, %{owner: opts[:owner], secret: opts[:secret]}}
    end
  end

  defmodule InputDevice do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, %{owner: opts[:owner], read: nil}}

    def handle_info({:io_request, from, ref, :getopts}, state) do
      send(from, {:io_reply, ref, [encoding: :unicode, binary: true]})
      {:noreply, state}
    end

    def handle_info({:io_request, from, ref, {:get_chars, :unicode, _prompt, 1}}, state) do
      send(state.owner, {:input_waiting, self()})
      {:noreply, %{state | read: {from, ref}}}
    end

    def handle_call({:fail, reason}, _from, %{read: {reader, ref}} = state) do
      send(reader, {:io_reply, ref, {:error, reason}})
      {:reply, :ok, %{state | read: nil}}
    end
  end

  test "diagnostic status omits handler configuration, initialized state and admitted input" do
    {root, runtime, secret} = start_runtime()

    assert {:ok, _token} =
             Runtime.submit(runtime, %{"jsonrpc" => "2.0", "id" => 1, "method" => secret})

    assert_receive {:held_callback, _worker}, 1_000
    {:ok, route} = Admission.route(Ref.table(runtime))

    for pid <- [root, route.scheduler] do
      status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      refute status =~ secret
    end
  end

  test "native scheduler failure and restart reports omit captured handler payloads" do
    {_root, runtime, secret} = start_runtime()
    assert {:ok, route} = Admission.route(Ref.table(runtime))

    log =
      capture_log(fn ->
        :ok = :sys.terminate(route.scheduler, :privacy_probe, 1_000)
        assert_receive {:initialized, new_scheduler}, 1_000
        refute new_scheduler == route.scheduler
      end)

    refute log =~ secret
  end

  test "mounted Gateway native diagnostics omit retained requests and debug events" do
    alias Arbor.MCP.Server.Runtime.{HTTPGateway, HTTPWriterProxy}

    {root, runtime, secret} = start_runtime()
    assert {:ok, gateway} = HTTPGateway.address(runtime)
    assert native_parent(gateway) == root
    assert :ok = :sys.log(gateway, true)
    assert {:ok, binding} = HTTPWriterProxy.capture(runtime)

    assert {:ok, _token} =
             HTTPGateway.submit(runtime, binding, %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => secret
             })

    assert_receive {:held_callback, _worker}, 1_000
    send(gateway, {:private_gateway_diagnostic, secret})

    {:status, ^gateway, _module, [_dictionary, _state, _parent, debug, formatted]} =
      :sys.get_status(gateway)

    # Raw debug inspection remains a trusted host boundary; native reports use
    # the formatter and must omit both retained payloads and event-log values.
    assert inspect(debug, limit: :infinity, printable_limit: :infinity) =~ secret
    refute inspect(formatted, limit: :infinity, printable_limit: :infinity) =~ secret
    monitor = Process.monitor(gateway)

    log =
      capture_log(fn ->
        assert :ok = :sys.terminate(gateway, :privacy_probe, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^gateway, :privacy_probe}, 1_000
      end)

    refute log =~ secret
  end

  test "native handler initialization failure reports omit exception values and options" do
    secret = "arbor-runtime-init-secret-#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 Runtime.start_link(
                   handler: Handler,
                   dispatcher: Handler,
                   handler_args: [owner: self(), secret: secret, raise_init: true],
                   init_timeout_ms: 1_000
                 )
      end)

    refute log =~ secret
  end

  test "handler termination exceptions do not reach native supervisor reports" do
    {root, _runtime, secret} = start_runtime(raise_terminate: true)

    log = capture_log(fn -> assert :ok = Runtime.stop(root) end)

    assert_receive {:terminated, _scheduler}, 1_000
    refute log =~ secret
  end

  test "native parent retains no printable options and restarts under the same parent" do
    secret = "arbor-runtime-parent-secret-#{System.unique_integer([:positive])}"

    assert {:ok, parent} =
             Supervisor.start_link(
               [{Runtime, runtime_options(secret, [])}],
               strategy: :one_for_one
             )

    Process.unlink(parent)
    on_exit(fn -> if Process.alive?(parent), do: Supervisor.stop(parent) end)
    assert_receive {:initialized, _scheduler}, 1_000
    [{Runtime, root, :supervisor, [Runtime]}] = Supervisor.which_children(parent)
    assert native_parent(root) == parent
    refute printable_status(parent) =~ secret

    log =
      capture_log(fn ->
        Process.exit(root, :kill)
        assert_receive {:initialized, _replacement_scheduler}, 1_000
      end)

    [{Runtime, replacement, :supervisor, [Runtime]}] = Supervisor.which_children(parent)
    refute root == replacement
    assert native_parent(replacement) == parent
    refute log =~ secret
    refute printable_status(parent) =~ secret
    refute printable_status(replacement) =~ secret
  end

  test "task arguments and consumed replay identifiers stay out of store status and crash logs" do
    {_root, runtime, secret} = start_runtime(services: [replay_cache: []])
    owner = %{principal_id: "privacy-test", tenant_id: "test", audience: "mcp://privacy"}

    assert {:ok, _task} =
             Tasks.create("private-task", %{"credential" => secret},
               runtime: runtime,
               owner: owner,
               notify: false
             )

    assert {:ok, replay} = Runtime.service(runtime, :replay_cache)
    assert :ok = ReplayCache.consume(replay, secret, System.system_time(:second) + 60)

    for kind <- [:tasks, :replay_cache] do
      assert {:ok, binding} = Services.resolve(runtime, kind)
      refute printable_status(binding.server) =~ secret
    end

    assert {:ok, binding} = Services.resolve(runtime, :tasks)
    log = capture_log(fn -> :ok = :sys.terminate(binding.server, :privacy_probe, 1_000) end)
    refute log =~ secret
  end

  test "HandlerServer and DSL child specifications hide options from their native parent" do
    secret = "arbor-facade-secret-#{System.unique_integer([:positive])}"

    for facade <- [Arbor.MCP.Server.HandlerServer, DSLHandler] do
      opts =
        runtime_options(secret, []) ++
          [transport: :test, instructions: secret, principal_id: secret]

      assert {:ok, parent} = Supervisor.start_link([{facade, opts}], strategy: :one_for_one)
      Process.unlink(parent)
      on_exit(fn -> if Process.alive?(parent), do: Supervisor.stop(parent) end)
      assert_receive {:initialized, _scheduler}, 1_000
      [{_id, root, :supervisor, [^facade]}] = Supervisor.which_children(parent)
      assert native_parent(root) == parent
      assert {:ok, edge} = Runtime.edge(root)
      refute printable_status(parent) =~ secret
      refute printable_status(root) =~ secret
      refute printable_status(edge) =~ secret
    end
  end

  test "stdio native parent and runtime children hide options without adopting IO devices" do
    alias Arbor.MCP.Server.Stdio.OutputAuthority
    alias Arbor.MCP.Test.StdioRuntimeFixture.Device

    secret = "arbor-stdio-secret-#{System.unique_integer([:positive])}"
    input = start_supervised!({InputDevice, owner: self()}, id: make_ref())
    output = start_supervised!({Device, owner: self()}, id: make_ref())
    authority = start_supervised!({OutputAuthority, []}, id: make_ref())
    assert {:ok, authority_ref} = OutputAuthority.reference(authority)

    opts =
      runtime_options(secret, []) ++
        [
          stdio_input: input,
          stdio_output: output,
          stdio_startup_delay: 0,
          _stdio_output_authority: authority_ref
        ]

    assert {:ok, parent} =
             Supervisor.start_link([{Arbor.MCP.Server.StdioServer, opts}], strategy: :one_for_one)

    Process.unlink(parent)
    on_exit(fn -> if Process.alive?(parent), do: Supervisor.stop(parent) end)
    assert_receive {:initialized, _scheduler}, 1_000

    [{_id, root, :supervisor, [Arbor.MCP.Server.StdioServer]}] =
      Supervisor.which_children(parent)

    assert native_parent(root) == parent
    assert {:ok, runtime} = Runtime.ref(root)
    assert {:ok, edge} = Runtime.edge(runtime)

    stdio_supervisor =
      Enum.find_value(Supervisor.which_children(root), fn
        {Arbor.MCP.Server.Stdio.Supervisor, pid, :supervisor, _modules} -> pid
        _other -> nil
      end)

    reader =
      Enum.find_value(Supervisor.which_children(stdio_supervisor), fn
        {Arbor.MCP.Server.Stdio.Reader, pid, :worker, _modules} -> pid
        _other -> nil
      end)

    # The Reader runs blocking borrowed IO in its native continuation, so it
    # cannot answer :sys while held there. Probe its real error report instead.
    for pid <-
          [parent, root, edge] ++
            child_processes(root) ++ (child_processes(stdio_supervisor) -- [reader]),
        do: refute(printable_status(pid) =~ secret)

    assert_receive {:input_waiting, ^input}, 1_000
    reader_monitor = Process.monitor(reader)

    log =
      capture_log(fn ->
        assert :ok = GenServer.call(input, {:fail, secret})
        assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :normal}, 1_000
      end)

    refute log =~ secret

    assert :ok = Supervisor.stop(parent)
    assert Process.alive?(input)
    assert Process.alive?(output)
  end

  test "subscription identity and a queued publication stay out of listener diagnostics" do
    secret = "arbor-subscription-secret-#{System.unique_integer([:positive])}"

    assert {:ok, listener} =
             SubscriptionListener.start_link(
               registry: self(),
               token: make_ref(),
               subscription_id: secret,
               transport_ref: self(),
               filter: %{},
               principal_id: secret,
               max_lifetime_ms: 5_000,
               max_queue: 4,
               max_message_bytes: 4_096,
               max_queue_bytes: 8_192
             )

    Process.unlink(listener)
    on_exit(fn -> if Process.alive?(listener), do: GenServer.stop(listener) end)
    assert :ok = SubscriptionListener.activate(listener)

    assert :ok =
             SubscriptionListener.enqueue(listener, "notifications/private", %{
               "value" => secret
             })

    refute printable_status(listener) =~ secret
    log = capture_log(fn -> :ok = :sys.terminate(listener, :privacy_probe, 1_000) end)
    refute log =~ secret
  end

  test "stdio authority formatted events stay out of native diagnostics" do
    alias Arbor.MCP.Server.Stdio.OutputAuthority

    secret = "arbor-authority-event-secret-#{System.unique_integer([:positive])}"
    authority = start_supervised!({OutputAuthority, []}, id: make_ref())
    assert :ok = :sys.log(authority, true)
    send(authority, {:stdio_physical_result, self(), make_ref(), {:error, secret}})

    {:status, ^authority, _module, [_dictionary, _state, _parent, debug, formatted]} =
      :sys.get_status(authority)

    # Explicit :sys.log is trusted inspection. OTP retains its raw debug buffer
    # outside the callback's formatted status; native reports use the formatter.
    assert inspect(debug, limit: :infinity, printable_limit: :infinity) =~ secret
    refute inspect(formatted, limit: :infinity, printable_limit: :infinity) =~ secret
    monitor = Process.monitor(authority)

    log =
      capture_log(fn ->
        assert :ok = :sys.terminate(authority, :privacy_probe, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^authority, :privacy_probe}, 1_000
      end)

    refute log =~ secret
  end

  defp start_runtime(opts \\ []) do
    secret = "arbor-runtime-status-secret-#{System.unique_integer([:positive])}"

    assert {:ok, root} = Runtime.start_link(runtime_options(secret, opts))

    Process.unlink(root)
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    assert_receive {:initialized, _scheduler}, 1_000
    assert {:ok, runtime} = Runtime.ref(root)
    {root, runtime, secret}
  end

  defp runtime_options(secret, opts) do
    {raise_terminate, opts} = Keyword.pop(opts, :raise_terminate, false)

    Keyword.merge(
      [
        handler: Handler,
        dispatcher: Handler,
        handler_args: [owner: self(), secret: secret, raise_terminate: raise_terminate],
        init_timeout_ms: 1_000,
        request_timeout_ms: 5_000
      ],
      opts
    )
  end

  defp native_parent(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    dictionary |> Keyword.fetch!(:"$ancestors") |> hd()
  end

  defp printable_status(pid),
    do: inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

  defp child_processes(supervisor),
    do:
      for(
        {_id, pid, _type, _modules} <- Supervisor.which_children(supervisor),
        is_pid(pid),
        do: pid
      )
end
