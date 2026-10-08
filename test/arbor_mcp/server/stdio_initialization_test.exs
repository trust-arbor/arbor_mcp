defmodule Arbor.MCP.Server.StdioInitializationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime.Initialization, as: RuntimeInitialization

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{Initialization, Ref}
  alias Arbor.MCP.Server.Stdio.{Dispatch, OutputAuthority, OutputLease, Supervisor}
  alias Arbor.MCP.Test.StdioRuntimeFixture.{Device, Handler}

  defmodule HeldEdge do
    def start_link(opts) do
      result = Arbor.MCP.Server.Stdio.Supervisor.start_link(opts)
      send(opts[:test_pid], {:stdio_constructed, self(), result})
      receive do: (:release_root -> result)
    end

    def child_spec(opts),
      do: %{Supervisor.child_spec(opts) | start: {__MODULE__, :start_link, [opts]}}
  end

  test "buffered stdin waits for the final root readiness barrier" do
    {caller, input, output, bytes} = start_held(1_000)
    assert_receive {:stdio_constructed, root, {:ok, edge_supervisor}}, 1_000
    [{:runtime, runtime}] = Process.info(root, :dictionary) |> dictionary_runtime()
    assert {:ok, %{status: :starting}} = Initialization.current(Ref.table(runtime))
    assert Process.alive?(edge_supervisor)
    Process.sleep(30)
    assert %{input: ^bytes, read: nil} = GenServer.call(input, :state)
    refute_receive {:invoked, _}, 20

    send(root, :release_root)
    assert_receive {:stdio_started, ^caller, {:ok, ^root}}, 1_000
    on_exit(fn -> if Process.alive?(root), do: Runtime.stop(root) end)
    assert_receive {:invoked, 1}, 1_000
    assert_receive {:written, response}, 1_000

    assert %{"id" => 1, "result" => %{"structuredContent" => %{"count" => 1}}} =
             Jason.decode!(String.trim(response))

    assert Process.alive?(input) and Process.alive?(output)
  end

  test "expired startup does not consume buffered stdin or stop borrowed devices" do
    started = System.monotonic_time(:millisecond)
    {caller, input, output, bytes} = start_held(1_000)
    assert_receive {:stdio_constructed, root, {:ok, edge_supervisor}}, 1_500
    root_monitor = Process.monitor(root)
    edge_monitor = Process.monitor(edge_supervisor)
    assert_receive {:stdio_started, ^caller, {:error, :runtime_init_timeout}}, 1_500
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _reason}, 1_500
    assert_receive {:DOWN, ^edge_monitor, :process, ^edge_supervisor, _reason}, 1_500
    assert System.monotonic_time(:millisecond) - started < 2_000
    assert %{input: ^bytes, read: nil} = GenServer.call(input, :state)
    assert Process.alive?(input) and Process.alive?(output)
    refute_receive {:invoked, _}, 20
    refute_receive {:write_attempt, _, _}, 20
  end

  test "a nontrapping caller suspended before the root barrier receives the original timeout" do
    started = System.monotonic_time(:millisecond)
    {caller, input, output, bytes} = start_held(1_000, hold_caller: true)
    assert_receive {:stdio_constructed, root, {:ok, edge_supervisor}}, 1_500
    root_monitor = Process.monitor(root)
    edge_monitor = Process.monitor(edge_supervisor)
    :erlang.suspend_process(caller)
    on_exit(fn -> resume(caller) end)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _reason}, 1_500
    assert_receive {:DOWN, ^edge_monitor, :process, ^edge_supervisor, _reason}, 1_500
    assert Process.alive?(caller)
    :erlang.resume_process(caller)
    assert_receive {:stdio_started, ^caller, {:error, :runtime_init_timeout}}, 1_500
    assert System.monotonic_time(:millisecond) - started < 2_000
    assert {:trap_exit, false} = Process.info(caller, :trap_exit)
    assert {:messages, []} = Process.info(caller, :messages)
    assert %{input: ^bytes, read: nil} = GenServer.call(input, :state)
    assert Process.alive?(input) and Process.alive?(output)
    refute_receive {:invoked, _}, 20
    refute_receive {:write_attempt, _, _}, 20
  end

  defp start_held(init_timeout, caller_opts \\ []) do
    input = start_supervised!({Device, [owner: self()]}, id: make_ref())
    output = start_supervised!({Device, [owner: self()]}, id: make_ref())

    bytes =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "inc", "arguments" => %{}}
      }) <> "\n"

    :ok = GenServer.call(input, {:input, bytes, false})
    owner = self()

    opts = [
      handler: Handler,
      dispatcher: Dispatch,
      handler_args: [test_pid: owner],
      test_pid: owner,
      stdio_input: input,
      stdio_output: output,
      stdio_startup_delay: 0,
      stdio_eof_timeout_ms: 1_000,
      init_timeout_ms: init_timeout,
      shutdown_timeout_ms: 50,
      transport: :stdio,
      endpoint: "stdio"
    ]

    caller =
      spawn(fn ->
        {:ok, config, deadline} = Initialization.configure(opts)
        {:ok, authority} = OutputAuthority.default(deadline)
        {:ok, lease} = OutputAuthority.acquire(authority, output, config, deadline)

        edge_opts =
          opts
          |> Keyword.put(:stdio_config, config)
          |> Keyword.put(:stdio_output, OutputLease.device(lease))
          |> Keyword.put(:stdio_output_lease, lease)

        result =
          RuntimeInitialization.start_configured(
            Keyword.put(opts, :edge, {HeldEdge, edge_opts}),
            config,
            deadline
          )

        if not match?({:ok, _}, result), do: OutputAuthority.release(lease, deadline)
        if match?({:ok, _pid}, result), do: Process.unlink(elem(result, 1))
        send(owner, {:stdio_started, self(), result})
        if caller_opts[:hold_caller], do: receive(do: (:finish -> :ok))
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)

    {caller, input, output, bytes}
  end

  defp resume(pid) do
    if Process.alive?(pid), do: :erlang.resume_process(pid)
  catch
    :error, _reason -> :ok
  end

  defp dictionary_runtime({:dictionary, dictionary}) do
    case List.keyfind(dictionary, {Runtime, :reference}, 0) do
      {_key, runtime} -> [{:runtime, runtime}]
      _missing -> []
    end
  end
end
