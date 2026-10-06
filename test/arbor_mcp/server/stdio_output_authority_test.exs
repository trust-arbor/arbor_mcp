defmodule Arbor.MCP.Server.Stdio.OutputAuthorityTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{Runtime, StdioServer}
  alias Arbor.MCP.Server.Runtime.{Config, Deadline, OutputController, Ref}
  alias Arbor.MCP.Server.Stdio.{OutputAuthority, OutputLease}
  alias Arbor.MCP.Server.Stdio.OutputAuthority.Control
  alias Arbor.MCP.Server.Stdio.OutputAuthority.Ref, as: AuthorityRef

  defmodule Device do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts),
      do: {:ok, %{owner: opts[:owner], hold: opts[:hold], input: "", read: nil, pending: []}}

    def handle_call({:input, bytes}, _from, state),
      do: {:reply, :ok, read(%{state | input: state.input <> bytes})}

    def handle_call(:pending, _from, state), do: {:reply, state.pending, state}

    def handle_call(:complete, _from, %{pending: [{sender, tag, wire} | rest]} = state) do
      send(sender, {:io_reply, tag, :ok})
      send(state.owner, {:completed, sender, wire})
      {:reply, :ok, %{state | pending: rest}}
    end

    def handle_info({:io_request, from, tag, :getopts}, state) do
      send(from, {:io_reply, tag, [encoding: :unicode, binary: true]})
      {:noreply, state}
    end

    def handle_info({:io_request, from, tag, {:get_chars, :unicode, _, 1}}, state),
      do: {:noreply, read(%{state | read: {from, tag}})}

    def handle_info({:io_request, from, tag, {:put_chars, _, bytes}}, state) do
      wire = IO.iodata_to_binary(bytes)
      send(state.owner, {:retained, self(), from, wire})

      if state.hold do
        {:noreply, %{state | pending: state.pending ++ [{from, tag, wire}]}}
      else
        send(from, {:io_reply, tag, :ok})
        {:noreply, state}
      end
    end

    defp read(%{read: nil} = state), do: state

    defp read(%{read: {from, tag}} = state) do
      cond do
        not Process.alive?(from) ->
          %{state | read: nil}

        state.input == "" ->
          state

        true ->
          {unit, rest} = String.next_codepoint(state.input)
          send(from, {:io_reply, tag, unit})
          %{state | read: nil, input: rest}
      end
    end
  end

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def init(opts) do
      send(opts[:owner], {:initialized, self()})
      {:ok, %{owner: opts[:owner], count: 0}}
    end

    def handle_call_tool("inc", _, state) do
      send(state.owner, {:invoked, state.count + 1})

      {:ok,
       %{
         content: [%{type: "text", text: String.duplicate("x", 300)}],
         structuredContent: %{count: state.count + 1}
       }, %{state | count: state.count + 1}}
    end
  end

  defmodule Parent do
    use Supervisor
    def start_link(child), do: Supervisor.start_link(__MODULE__, child)
    def init(child), do: Supervisor.init([child], strategy: :one_for_one, max_restarts: 10)
  end

  defp authority do
    pid = start_supervised!({OutputAuthority, []}, id: make_ref())
    {:ok, ref} = OutputAuthority.reference(pid)
    {pid, ref}
  end

  defp device(hold \\ false),
    do: start_supervised!({Device, [owner: self(), hold: hold]}, id: make_ref())

  defp opts(ref, input, output, extra \\ []) do
    Keyword.merge(
      [
        module: Handler,
        handler_args: [owner: self()],
        stdio_input: input,
        stdio_output: output,
        _stdio_output_authority: ref,
        stdio_startup_delay: 0,
        init_timeout_ms: 1_000,
        request_timeout_ms: 2_000,
        output_timeout_ms: 500,
        shutdown_timeout_ms: 50,
        max_output_frames: 1,
        max_output_bytes: 1_536,
        max_output_frame_bytes: 2_048,
        max_output_term_bytes: 2_048
      ],
      extra
    )
  end

  defp invoke(input, id) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "inc", "arguments" => %{}}
    }

    GenServer.call(input, {:input, Jason.encode!(request) <> "\n"})
  end

  defp eventually(fun, tries \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, tries - 1)
        )
  end

  defp current(parent),
    do:
      (
        [{:endpoint, root, _, _}] = Supervisor.which_children(parent)
        {:ok, ref} = Runtime.ref(root)
        {root, ref}
      )

  defp writer(ref),
    do:
      (
        [{:stdio_writer, pid}] = :ets.lookup(Ref.table(ref), :stdio_writer)
        pid
      )

  defp stats(ref), do: OutputAuthority.stats(ref, Deadline.after_ms(1_000))

  defp assert_completed_runtime_stop(root, runtime, authority, iteration) do
    table = Ref.table(runtime)
    {:ok, control} = Arbor.MCP.Server.Runtime.ShutdownControl.lookup(table)

    owned = [
      root: root,
      output_controller: child(runtime, :output_controller),
      edge: child(runtime, :edge),
      scheduler: child(runtime, :scheduler),
      writer: writer(runtime),
      guard: child(runtime, :shutdown_guard),
      observer: control.pid
    ]

    monitors = Enum.map(owned, fn {role, pid} -> {role, pid, Process.monitor(pid)} end)

    try do
      before_stop = %{
        runtime: Runtime.stats(runtime),
        output: OutputController.stats(table),
        authority: stats(authority)
      }

      started = Deadline.now()
      result = Runtime.stop(root)
      returned_at = Deadline.now()

      observation = %{
        iteration: iteration,
        result: result,
        elapsed_ms: returned_at - started,
        cutoff: :atomics.get(control.cells, 1),
        returned_at: returned_at,
        shutdown_phase: :atomics.get(control.cells, 2),
        before_stop: before_stop,
        owned:
          Map.new(owned, fn {role, pid} ->
            {role,
             %{
               pid: pid,
               alive?: Process.alive?(pid),
               process: Process.info(pid, [:status, :current_function, :message_queue_len])
             }}
          end)
      }

      assert :ok = result,
             "Completed runtime cleanup was not confirmed: #{inspect(observation, limit: :infinity)}"

      for {role, pid, monitor} <- monitors do
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason},
                       1_000,
                       "Missing #{role} DOWN after successful stop: #{inspect(observation, limit: :infinity)}"
      end
    after
      for {_role, _pid, monitor} <- monitors, do: Process.demonitor(monitor, [:flush])
    end
  end

  test "64 completed device deaths before endpoint retirement reclaim capacity without weakening exclusive leases" do
    {_authority, ref} = authority()
    input = device()

    # This tests completed-output capacity reclamation. Shutdown deadline behavior
    # remains covered by the separate short-budget and late-completion tests.
    shutdown_opts = [shutdown_timeout_ms: 5_000]

    for id <- 1..64 do
      output =
        start_supervised!(
          Supervisor.child_spec({Device, [owner: self(), hold: false]}, restart: :temporary),
          id: make_ref()
        )

      {:ok, root} = StdioServer.start_link(opts(ref, input, output, shutdown_opts))
      assert_receive {:initialized, _}, 1_000
      {:ok, runtime} = Runtime.ref(root)
      :ok = invoke(input, id)
      assert_receive {:invoked, 1}, 1_000
      assert_receive {:retained, ^output, _sender, _wire}, 1_000

      # The authority releases physical IO first; controller and request ownership
      # must also settle before this test claims the output was completed.
      eventually(fn ->
        match?(%{frames: 0, bytes: 0}, stats(ref)) and
          OutputController.stats(Ref.table(runtime)).frames == 0 and
          match?(%{active: 0, queued: 0, reserved: 0, confirmed: 0}, Runtime.stats(runtime))
      end)

      monitor = Process.monitor(output)
      Process.exit(output, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^output, :killed}, 1_000
      eventually(fn -> match?(%{devices: 1, poisoned: 0, frames: 0}, stats(ref)) end)
      assert Process.alive?(root)

      assert_completed_runtime_stop(root, runtime, ref, id)
      eventually(fn -> match?(%{devices: 0, monitors: 0, bytes: 0}, stats(ref)) end)
    end

    replacement = device()
    {:ok, root} = StdioServer.start_link(opts(ref, input, replacement, shutdown_opts))
    assert_receive {:initialized, _}, 1_000
    {:ok, runtime} = Runtime.ref(root)
    assert_completed_runtime_stop(root, runtime, ref, :replacement)
    assert Process.alive?(input) and Process.alive?(replacement)
  end

  test "clean device retirement rejects old controls and permits a named replacement only after root retirement" do
    {authority, ref} = authority()
    input = device()

    output =
      start_supervised!(
        Supervisor.child_spec({Device, [owner: self(), hold: false]}, restart: :temporary),
        id: make_ref()
      )

    name = :arbor_mcp_stdio_clean_retirement_fixture
    Process.register(output, name)
    {:ok, root} = StdioServer.start_link(opts(ref, input, name))
    assert_receive {:initialized, _}, 1_000
    {:ok, runtime} = Runtime.ref(root)
    table = Ref.table(runtime)
    [{:stdio_output_lease, lease}] = :ets.lookup(table, :stdio_output_lease)
    {:ok, info} = OutputLease.info(lease)
    {:ok, context} = Arbor.MCP.Server.Runtime.Initialization.current(table)

    output_monitor = Process.monitor(output)
    Process.exit(output, :kill)
    assert_receive {:DOWN, ^output_monitor, :process, ^output, :killed}, 1_000
    eventually(fn -> match?(%{devices: 1, poisoned: 0}, stats(ref)) end)

    assert {:error, :stdio_output_unavailable} =
             OutputAuthority.bind(lease, runtime, Deadline.after_ms(1_000))

    assert {:error, :stdio_output_unsettled} =
             OutputAuthority.execution_boundary(lease, table, context)

    replacement = device()
    Process.register(replacement, name)

    assert {:error, :stdio_output_device_changed} =
             StdioServer.start_link(opts(ref, input, name))

    :ok = :sys.suspend(authority)
    caller = self()

    producer =
      spawn(fn ->
        result =
          Control.call(
            ref,
            {:write, info.token, "old leased frame", context.epoch},
            Deadline.after_ms(2_000)
          )

        send(caller, {:retired_control, result, Process.info(self(), :messages)})
      end)

    eventually(fn ->
      Enum.any?(Control.entries(AuthorityRef.table(ref)), fn {_slot, entry} ->
        entry.caller == producer and Control.active?(entry)
      end)
    end)

    assert :ok = Runtime.stop(root)
    :ok = :sys.resume(authority)
    assert_receive {:retired_control, {:error, :stdio_output_unavailable}, {:messages, []}}, 1_000
    eventually(fn -> match?(%{devices: 0, frames: 0, bytes: 0}, stats(ref)) end)
    refute_receive {:retained, ^replacement, _, _}, 30

    {:ok, new_root} = StdioServer.start_link(opts(ref, input, name))
    assert_receive {:initialized, _}, 1_000
    assert :ok = Runtime.stop(new_root)
    assert Process.alive?(replacement)
  end

  test "held device death preserves error poison while an unknown sender still retains its physical charge" do
    {_authority, ref} = authority()
    input = device()

    output =
      start_supervised!(
        Supervisor.child_spec({Device, [owner: self(), hold: true]}, restart: :temporary),
        id: make_ref()
      )

    {:ok, root} = StdioServer.start_link(opts(ref, input, output))
    assert_receive {:initialized, _}, 1_000
    :ok = invoke(input, 1)
    assert_receive {:invoked, 1}, 1_000
    assert_receive {:retained, ^output, _sender, _wire}, 1_000
    assert :ok = Runtime.stop(root)
    Process.exit(output, :kill)
    eventually(fn -> match?(%{devices: 1, poisoned: 1, frames: 0, bytes: 0}, stats(ref)) end)

    unknown_output =
      start_supervised!(
        Supervisor.child_spec({Device, [owner: self(), hold: true]}, restart: :temporary),
        id: make_ref()
      )

    name = :arbor_mcp_stdio_unknown_retirement_fixture
    Process.register(unknown_output, name)
    {:ok, unknown_root} = StdioServer.start_link(opts(ref, input, name))
    Process.unlink(unknown_root)
    assert_receive {:initialized, _}, 1_000
    :ok = invoke(input, 2)
    assert_receive {:invoked, 1}, 1_000
    assert_receive {:retained, ^unknown_output, sender, wire}, 1_000
    monitor = Process.monitor(unknown_root)
    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^unknown_root, _}, 1_000
    output_monitor = Process.monitor(unknown_output)
    Process.exit(unknown_output, :kill)
    assert_receive {:DOWN, ^output_monitor, :process, ^unknown_output, :killed}, 1_000
    eventually(fn -> match?(%{devices: 2, poisoned: 2, frames: 1}, stats(ref)) end)
    assert %{bytes: charged} = stats(ref)
    assert charged == byte_size(wire)

    replacement = device()
    Process.register(replacement, name)

    assert {:error, :stdio_output_device_changed} =
             StdioServer.start_link(opts(ref, input, name))

    assert %{devices: 2, poisoned: 2, frames: 1, bytes: ^charged} = stats(ref)
    assert Process.alive?(input) and Process.alive?(replacement)
  end

  test "four permanent replacements preserve the same one-frame physical liability until actual IO completion" do
    {_authority, ref} = authority()
    input = device()
    output = device(true)

    child =
      Map.merge(StdioServer.child_spec(opts(ref, input, output)), %{
        id: :endpoint,
        restart: :permanent
      })

    parent =
      start_supervised!({Parent, child},
        id: make_ref()
      )

    assert_receive {:initialized, _}, 1_000

    Enum.each(1..4, fn id ->
      {root, runtime} = current(parent)
      :ok = invoke(input, id)
      assert_receive {:invoked, 1}, 1_000
      assert_receive {:retained, ^output, sender, wire}, 1_000
      assert %{frames: 1, bytes: bytes} = stats(ref)
      assert bytes == byte_size(wire)
      assert %{frames: 1, bytes: charged} = OutputController.stats(Ref.table(runtime))
      assert charged <= 1_536
      proxy = writer(runtime)
      refute proxy == sender
      monitor = Process.monitor(root)
      Process.exit(proxy, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
      assert Process.alive?(sender)
      refute_receive {:initialized, _}, 30
      refute_receive {:retained, ^output, _, _}, 30
      assert [{^sender, _, ^wire}] = GenServer.call(output, :pending)
      assert %{frames: 1, bytes: ^bytes} = stats(ref)
      :ok = GenServer.call(output, :complete)
      assert_receive {:completed, ^sender, ^wire}
      assert_receive {:initialized, _}, 1_000
      {_new_root, new_ref} = current(parent)
      refute runtime == new_ref
      assert {:error, :runtime_unavailable} = Runtime.ref(runtime)
      eventually(fn -> stats(ref).frames == 0 end)
    end)

    :ok = Supervisor.terminate_child(parent, :endpoint)
    eventually(fn -> stats(ref).devices == 0 end)
    assert Process.alive?(output)
  end

  test "retired unresolved IO fences startup effects under the original finite cutoff and other devices remain independent" do
    {_authority, ref} = authority()
    input = device()
    output = device(true)
    {:ok, root} = StdioServer.start_link(opts(ref, input, output))
    Process.unlink(root)
    assert_receive {:initialized, _}
    {:ok, runtime} = Runtime.ref(root)
    invoke(input, 1)
    assert_receive {:invoked, 1}
    assert_receive {:retained, ^output, sender, wire}
    monitor = Process.monitor(root)
    Process.exit(writer(runtime), :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
    started = Deadline.now()

    assert {:error, :stdio_output_timeout} =
             StdioServer.start_link(opts(ref, input, output, init_timeout_ms: 60))

    assert Deadline.now() - started < 500
    refute_receive {:initialized, _}, 30
    assert [{^sender, _, ^wire}] = GenServer.call(output, :pending)

    other_input = device()
    other_output = device()
    {:ok, other} = StdioServer.start_link(opts(ref, other_input, other_output))
    Process.unlink(other)
    assert_receive {:initialized, _}
    invoke(other_input, 2)
    assert_receive {:invoked, 1}
    assert_receive {:retained, ^other_output, _, _}
    assert Process.alive?(other)
    :ok = Runtime.stop(other)
    :ok = GenServer.call(output, :complete)
    assert_receive {:completed, ^sender, ^wire}
    eventually(fn -> stats(ref).devices == 0 end)
  end

  test "a dead physical sender poisons liability and a named alias cannot retarget around it" do
    {_authority, ref} = authority()
    input = device()
    output = device(true)
    name = :arbor_mcp_stdio_poison_fixture
    Process.register(output, name)
    server_opts = opts(ref, input, name)
    {:ok, root} = StdioServer.start_link(server_opts)
    Process.unlink(root)
    assert_receive {:initialized, _}
    entry_deadline = Deadline.after_ms(Keyword.fetch!(server_opts, :request_timeout_ms))
    invoke(input, 1)
    assert_receive {:invoked, 1}, Deadline.remaining(entry_deadline)
    assert Deadline.now() < entry_deadline
    assert_receive {:retained, ^output, sender, _}
    monitor = Process.monitor(root)
    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
    assert %{poisoned: 1, frames: 1} = stats(ref)
    Process.unregister(name)
    replacement = device()
    Process.register(replacement, name)
    assert {:error, :stdio_output_device_changed} = StdioServer.start_link(opts(ref, input, name))
    assert {:error, :stdio_output_unavailable} = StdioServer.start_link(opts(ref, input, output))
    refute_receive {:initialized, _}, 30
    assert Process.alive?(output) and Process.alive?(replacement)
  end

  test "authority death cannot silently replace a stale domain or destroy the borrowed device" do
    {authority, ref} = authority()
    input = device()
    output = device(true)
    {:ok, root} = StdioServer.start_link(opts(ref, input, output))
    Process.unlink(root)
    assert_receive {:initialized, _}
    invoke(input, 1)
    assert_receive {:invoked, 1}
    assert_receive {:retained, ^output, sender, wire}
    monitor = Process.monitor(root)
    Process.exit(authority, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
    assert {:error, :stdio_output_unavailable} = StdioServer.start_link(opts(ref, input, output))
    assert Process.alive?(sender) and Process.alive?(output)
    :ok = GenServer.call(output, :complete)
    assert_receive {:completed, ^sender, ^wire}
    refute_receive {:initialized, _}, 30
  end

  test "64 captured devices is a fixed cap and only proven idle leases can retire" do
    {_authority, ref} = authority()
    {:ok, config} = Config.new(handler: Handler)
    devices = for _ <- 1..65, do: device()

    leases =
      for output <- Enum.take(devices, 64) do
        assert {:ok, lease} =
                 OutputAuthority.acquire(ref, output, config, Deadline.after_ms(2_000))

        lease
      end

    assert {:error, :stdio_output_busy} =
             OutputAuthority.acquire(ref, List.last(devices), config, Deadline.after_ms(500))

    assert stats(ref).devices == 64
    assert :ok = OutputAuthority.release(hd(leases), Deadline.after_ms(500))

    assert {:ok, _} =
             OutputAuthority.acquire(ref, List.last(devices), config, Deadline.after_ms(500))

    assert stats(ref).devices == 64
  end

  test "a second live endpoint cannot share one idle borrowed output device" do
    {_authority, ref} = authority()
    input = device()
    output = device()
    {:ok, root} = StdioServer.start_link(opts(ref, input, output))
    assert_receive {:initialized, _}, 1_000
    assert %{devices: 1, frames: 0} = stats(ref)

    assert {:error, :stdio_output_in_use} =
             StdioServer.start_link(opts(ref, device(), output))

    refute_receive {:initialized, _}, 30
    assert Process.alive?(root) and Process.alive?(output)
    assert :ok = Runtime.stop(root)
    eventually(fn -> stats(ref).devices == 0 end)
  end

  defp child(runtime, :scheduler) do
    [{:route, route}] = :ets.lookup(Ref.table(runtime), :route)
    route.scheduler
  end

  defp child(runtime, key) do
    [{^key, pid}] = :ets.lookup(Ref.table(runtime), key)
    pid
  end

  for kind <- [:output_controller, :scheduler, :admission] do
    test "unsettled physical IO fences fresh execution after #{kind} death" do
      {_authority, ref} = authority()
      input = device()
      output = device(true)
      {:ok, root} = StdioServer.start_link(opts(ref, input, output, output_timeout_ms: 5_000))
      Process.unlink(root)
      {:ok, runtime} = Runtime.ref(root)
      assert_receive {:initialized, _}, 1_000
      :ok = invoke(input, 1)
      assert_receive {:invoked, 1}, 1_000
      assert_receive {:retained, ^output, sender, wire}, 1_000
      monitor = Process.monitor(root)
      Process.exit(child(runtime, unquote(kind)), :kill)
      assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
      refute_receive {:initialized, _}, 30
      refute_receive {:retained, ^output, _, _}, 30
      assert Process.alive?(sender) and Process.alive?(output)
      assert %{frames: 1, bytes: bytes} = stats(ref)
      assert bytes == byte_size(wire)

      assert {:error, :stdio_output_timeout} =
               StdioServer.start_link(opts(ref, input, output, init_timeout_ms: 50))

      refute_receive {:initialized, _}, 30
      :ok = GenServer.call(output, :complete)
      assert_receive {:completed, ^sender, ^wire}, 1_000
      eventually(fn -> stats(ref).devices == 0 end)
    end
  end

  for kind <- [:output_controller, :admission] do
    test "idle completed output permits genuine #{kind} replacement without a fresh runtime" do
      {_authority, ref} = authority()
      input = device()
      output = device()
      {:ok, root} = StdioServer.start_link(opts(ref, input, output))
      Process.unlink(root)
      {:ok, runtime} = Runtime.ref(root)
      assert_receive {:initialized, _}, 1_000
      :ok = invoke(input, 1)
      assert_receive {:invoked, 1}, 1_000
      assert_receive {:retained, ^output, _, _}, 1_000

      # Physical output can settle before Scheduler and edge ownership. The
      # replacement exercised here requires the whole request to be idle.
      eventually(fn ->
        stats(ref).frames == 0 and OutputController.stats(Ref.table(runtime)).frames == 0 and
          match?(%{active: 0, queued: 0, reserved: 0, confirmed: 0}, Runtime.stats(runtime))
      end)

      Enum.each(2..4, fn id ->
        old_generation = Runtime.stats(runtime).generation
        Process.exit(child(runtime, unquote(kind)), :kill)
        assert_receive {:initialized, _}, 1_000

        eventually(fn ->
          match?(
            %{generation: generation} when generation != old_generation,
            Runtime.stats(runtime)
          )
        end)

        assert Process.alive?(root)
        assert {:ok, ^runtime} = Runtime.ref(root)
        :ok = invoke(input, id)
        assert_receive {:invoked, 1}, 1_000
        assert_receive {:retained, ^output, _, _}, 1_000

        eventually(fn ->
          stats(ref).frames == 0 and OutputController.stats(Ref.table(runtime)).frames == 0 and
            match?(%{active: 0, queued: 0, reserved: 0, confirmed: 0}, Runtime.stats(runtime))
        end)

        assert stats(ref).monitors <= 4
      end)

      assert :ok = Runtime.stop(root)
      eventually(fn -> stats(ref).devices == 0 and stats(ref).monitors == 0 end)
      assert Process.alive?(output)
    end
  end

  test "a published write behind a suspended authority cannot escape into a fresh execution epoch" do
    {authority, ref} = authority()
    input = device()
    output = device()
    {:ok, root} = StdioServer.start_link(opts(ref, input, output, init_timeout_ms: 500))
    Process.unlink(root)
    {:ok, runtime} = Runtime.ref(root)
    assert_receive {:initialized, _}, 1_000
    :ok = :sys.suspend(authority)
    :ok = invoke(input, 1)
    assert_receive {:invoked, 1}, 1_000

    eventually(fn ->
      Enum.any?(:ets.tab2list(AuthorityRef.table(ref)), fn {key, value} ->
        match?({:slot, _}, key) and is_map(value) and
          match?({:write, _, _, _}, value.command) and :atomics.get(value.phase, 1) == 1
      end)
    end)

    monitor = Process.monitor(root)
    Process.exit(child(runtime, :output_controller), :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
    refute_receive {:initialized, _}, 30
    refute_receive {:retained, ^output, _, _}, 30
    :ok = :sys.resume(authority)
    eventually(fn -> stats(ref).devices == 0 end)
    assert %{frames: 0} = stats(ref)
    assert Process.alive?(input) and Process.alive?(output)
  end

  test "normal runtime stop retains unresolved physical IO and fences the next endpoint" do
    {_authority, ref} = authority()
    input = device()
    output = device(true)
    {:ok, root} = StdioServer.start_link(opts(ref, input, output))
    assert_receive {:initialized, _}, 1_000
    :ok = invoke(input, 1)
    assert_receive {:invoked, 1}, 1_000
    assert_receive {:retained, ^output, sender, wire}, 1_000
    assert :ok = Runtime.stop(root)
    refute Process.alive?(root)
    assert Process.alive?(sender)
    assert %{frames: 1, bytes: bytes} = stats(ref)
    assert bytes == byte_size(wire)

    assert {:error, :stdio_output_timeout} =
             StdioServer.start_link(opts(ref, input, output, init_timeout_ms: 50))

    refute_receive {:initialized, _}, 30
    refute_receive {:retained, ^output, _, _}, 30
    :ok = GenServer.call(output, :complete)
    assert_receive {:completed, ^sender, ^wire}, 1_000
    eventually(fn -> not Process.alive?(sender) and stats(ref).devices == 0 end)
    assert Process.alive?(input) and Process.alive?(output)

    {:ok, replacement} = StdioServer.start_link(opts(ref, input, output))
    assert_receive {:initialized, _}, 1_000
    assert :ok = Runtime.stop(replacement)
  end

  test "128 pre-mailbox control slots and one coalesced wake remain bounded behind a suspended authority" do
    {authority, ref} = authority()
    {:ok, config} = Config.new(handler: Handler)
    output = device()
    :ok = :sys.suspend(authority)
    owner = self()

    producers =
      for _ <- 1..128 do
        spawn(fn ->
          send(
            owner,
            {:control_result, self(),
             OutputAuthority.acquire(ref, output, config, Deadline.after_ms(2_000))}
          )
        end)
      end

    eventually(fn ->
      Enum.count(:ets.tab2list(AuthorityRef.table(ref)), fn {key, value} ->
        match?({:slot, _}, key) and is_map(value)
      end) == 128
    end)

    assert {:error, :stdio_output_busy} =
             OutputAuthority.acquire(ref, output, config, Deadline.after_ms(500))

    assert {:messages, messages} = Process.info(authority, :messages)
    assert Enum.count(messages, &(&1 == :stdio_output_wake)) == 1
    assert length(messages) <= 2
    Enum.each(producers, &Process.exit(&1, :kill))
    :ok = :sys.resume(authority)
    eventually(fn -> match?(%{devices: 0, slots: 1}, stats(ref)) end)
    refute_receive {:control_result, _, _}
  end

  test "queued success cannot extend a suspended caller's original cutoff or leave a late reply" do
    {authority, ref} = authority()
    {:ok, config} = Config.new(handler: Handler)
    output = device()
    :ok = :sys.suspend(authority)
    owner = self()

    caller =
      spawn(fn ->
        result = OutputAuthority.acquire(ref, output, config, Deadline.after_ms(500))
        send(owner, {:late_result, result, Process.info(self(), :messages)})
      end)

    eventually(fn ->
      Enum.any?(:ets.tab2list(AuthorityRef.table(ref)), fn {key, value} ->
        match?({:slot, _}, key) and is_map(value) and value.caller == caller and
          :atomics.get(value.phase, 1) == 1
      end)
    end)

    true = :erlang.suspend_process(caller)
    :ok = :sys.resume(authority)
    eventually(fn -> stats(ref).devices == 1 end)
    eventually(fn -> stats(ref).devices == 0 end)
    true = :erlang.resume_process(caller)
    assert_receive {:late_result, {:error, :stdio_output_timeout}, {:messages, []}}, 1_000
  end

  test "unsupported or foreign output addresses fail before handler initialization" do
    {_authority, ref} = authority()
    input = device()

    assert {:error, :unsupported_stdio_output_device} =
             StdioServer.start_link(opts(ref, input, {:via, __MODULE__, :device}))

    assert {:error, :stdio_output_unavailable} =
             StdioServer.start_link(opts(make_ref(), input, device()))

    refute_receive {:initialized, _}, 30
    assert {:error, :stdio_output_unavailable} = OutputLease.info(make_ref())
  end
end
