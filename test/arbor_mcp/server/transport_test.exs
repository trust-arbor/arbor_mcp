defmodule Arbor.MCP.Server.TransportTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.{HandlerServer, Runtime, Transport}
  alias Arbor.MCP.Server.Runtime.Ref

  setup do
    # Save original configuration before any tests that might use STDIO transport
    original_level = Logger.level()
    original_stdio_mode = Application.get_env(:arbor_mcp, :stdio_mode, false)

    on_exit(fn ->
      # Restore original logger configuration after STDIO tests
      Logger.configure(level: original_level)
      Application.put_env(:arbor_mcp, :stdio_mode, original_stdio_mode)
    end)

    :ok
  end

  defmodule TestServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "test", version: "1.0.0"

    tool "test_tool", "A test tool" do
      input_schema(%{
        type: "object",
        properties: %{
          message: %{type: "string"}
        },
        required: ["message"]
      })

      run(fn %{"message" => message}, state ->
        {:ok, %{content: [%{"type" => "text", "text" => "Echo: #{message}"}]}, state}
      end)
    end
  end

  defmodule BlockingShutdownHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{test_pid: opts[:test_pid]}}

    @impl true
    def terminate(_reason, state) do
      send(state.test_pid, {:blocked_handler_terminate, self()})

      receive do
        :release_terminate -> :ok
      end
    end
  end

  defmodule BlockingStore do
    use GenServer
    alias Arbor.MCP.Server.Runtime.ServiceAdapter

    def runtime_service_capabilities, do: %{bounded_startup: 1}

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, timeout: Keyword.fetch!(opts, :init_timeout_ms))

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      :ok = ServiceAdapter.watch_owned(opts)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:blocking_store, self()})
      {:ok, test_pid}
    end

    @impl true
    def terminate(_reason, test_pid) do
      send(test_pid, {:blocked_store_terminate, self()})

      receive do
        :release_terminate -> :ok
      end
    end
  end

  test "stop_server applies one runtime deadline across blocked handler and owned store termination" do
    root =
      start_supervised!(
        Supervisor.child_spec(
          {HandlerServer,
           [
             transport: :test,
             handler: BlockingShutdownHandler,
             handler_args: [test_pid: self()],
             shutdown_timeout_ms: 80,
             store_children: [[adapter: BlockingStore, options: [test_pid: self()]]]
           ]},
          id: :bounded_stop,
          restart: :temporary
        )
      )

    sibling =
      start_supervised!(
        Supervisor.child_spec({TestServer, [transport: :test]}, restart: :temporary)
      )

    assert_receive {:blocking_store, store}
    {:ok, runtime} = Runtime.ref(root)
    {:ok, edge} = Runtime.edge(runtime)
    [{:shutdown_guard, guard}] = :ets.lookup(Ref.table(runtime), :shutdown_guard)
    monitors = Enum.map([root, edge, store, guard], &{&1, Process.monitor(&1)})
    started = System.monotonic_time(:millisecond)
    stop = Task.async(fn -> Transport.stop_server(root) end)
    assert_receive {:blocked_handler_terminate, _scheduler}, 1_000
    assert :ok = Task.await(stop, 1_000)
    assert System.monotonic_time(:millisecond) - started < 500

    for {pid, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _reason}, 1_000)

    assert Process.alive?(sibling)

    assert {:ok, %{"id" => 1, "result" => %{}}} =
             Runtime.request(sibling, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    {:ok, sibling_ref} = Runtime.ref(sibling)
    assert :ok = Transport.stop_server(sibling_ref)
    refute Process.alive?(sibling)
  end

  describe "start_server/4" do
    test "starts BEAM transport" do
      {:ok, pid} =
        Transport.start_server(TestServer, %{name: "test", version: "1.0.0"}, [],
          transport: :beam,
          name: :test_beam_server
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "returns error for unsupported transport" do
      assert {:error, {:unsupported_transport, :invalid}} =
               Transport.start_server(TestServer, %{}, [], transport: :invalid)
    end

    @tag :requires_http
    test "starts HTTP transport" do
      # This test requires Cowboy to be available
      if match?({:module, _}, Code.ensure_loaded(Plug.Cowboy)) do
        {:ok, pid} =
          Transport.start_server(TestServer, %{name: "test", version: "1.0.0"}, [],
            # Use port 0 for auto-assignment
            transport: :http,
            port: 0
          )

        assert is_pid(pid)
        Transport.stop_server(pid)
      else
        # Skip if Cowboy not available
        :skip
      end
    end

    @tag :requires_http
    test "starts HTTP transport with SSE enabled" do
      if match?({:module, _}, Code.ensure_loaded(Plug.Cowboy)) do
        {:ok, pid} =
          Transport.start_server(TestServer, %{name: "test", version: "1.0.0"}, [],
            transport: :http,
            legacy_http_sse: true,
            port: 0
          )

        assert is_pid(pid)
        Transport.stop_server(pid)
      else
        :skip
      end
    end

    test "starts an owned stdio runtime" do
      {:ok, pid} =
        Transport.start_server(TestServer, %{name: "test", version: "1.0.0"}, [],
          transport: :stdio,
          name: :test_stdio_server,
          stdio_startup_delay: 60_000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "individual transport functions" do
    test "start_beam_server/4" do
      {:ok, pid} =
        Transport.start_beam_server(TestServer, %{}, [], name: :test_beam_individual)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_stdio_server/4 returns the runtime root" do
      {:ok, pid} =
        Transport.start_stdio_server(TestServer, %{}, [],
          name: :test_stdio_individual,
          stdio_startup_delay: 60_000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    @tag :requires_http
    test "start_http_server/4" do
      if match?({:module, _}, Code.ensure_loaded(Plug.Cowboy)) do
        runtime = start_supervised!({Runtime, handler: TestServer, transport: :mounted_http})

        {:ok, pid} =
          Transport.start_http_server(TestServer, %{name: "test", version: "1.0.0"}, [],
            runtime: runtime,
            port: 0
          )

        assert is_pid(pid)
        Transport.stop_server(pid)
      else
        :skip
      end
    end
  end

  describe "server management" do
    test "stop_server/1 with pid" do
      {:ok, pid} = Transport.start_beam_server(TestServer, %{}, [], name: :test_stop_pid)

      assert Process.alive?(pid)
      assert :ok = Transport.stop_server(pid)
      refute Process.alive?(pid)
    end

    test "stop_server/1 with atom" do
      {:ok, pid} = Transport.start_beam_server(TestServer, %{}, [], name: :test_stop_atom)

      # Wait for process to be registered
      Process.sleep(10)
      assert Process.whereis(:test_stop_atom) == pid
      assert :ok = Transport.stop_server(:test_stop_atom)

      # Wait for process to stop
      Process.sleep(10)
      assert Process.whereis(:test_stop_atom) == nil
    end

    test "stop_server/1 with non-existent process" do
      assert :ok = Transport.stop_server(:non_existent_server)
    end

    test "server_info/1" do
      {:ok, pid} = Transport.start_beam_server(TestServer, %{}, [], name: :test_info)

      # The server info depends on the implementation
      # For now, just test that it doesn't crash
      result = Transport.server_info(pid)
      assert is_tuple(result)

      GenServer.stop(pid)
    end
  end

  describe "list_transports/0" do
    test "returns available transports" do
      transports = Transport.list_transports()

      assert is_map(transports)
      assert Map.has_key?(transports, :stdio)
      assert Map.has_key?(transports, :http)
      assert Map.has_key?(transports, :beam)

      # BEAM should always be available
      assert transports.beam.available == true

      # Others depend on dependencies
      assert is_boolean(transports.stdio.available)
      assert is_boolean(transports.http.available)
    end
  end

  describe "Server integration" do
    test "start_link with transport: :beam" do
      {:ok, pid} = TestServer.start_link(transport: :beam, name: :test_server_beam)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    @tag :requires_http
    test "start_link with transport: :http" do
      if match?({:module, _}, Code.ensure_loaded(Plug.Cowboy)) do
        {:ok, pid} = TestServer.start_link(transport: :http, port: 0)

        assert is_pid(pid)
        Transport.stop_server(pid)
      else
        :skip
      end
    end

    test "start_link defaults to BEAM transport" do
      {:ok, pid} = TestServer.start_link(name: :test_server_default)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "child_spec/1" do
      spec = TestServer.child_spec(transport: :beam)

      assert spec.id == TestServer
      assert spec.modules == [TestServer]
      assert spec.type == :supervisor
      assert spec.restart == :permanent
      assert spec.shutdown == 5_000

      root = start_supervised!(spec)
      assert {:ok, parent} = ExUnit.fetch_test_supervisor()
      assert {TestServer, root, :supervisor, [TestServer]} in Supervisor.which_children(parent)
      {:dictionary, dictionary} = Process.info(root, :dictionary)
      assert hd(Keyword.fetch!(dictionary, :"$ancestors")) == parent
      assert {:ok, _runtime} = Runtime.ref(root)
      assert {:ok, edge} = Runtime.edge(root)
      assert Process.alive?(edge)
    end
  end
end
