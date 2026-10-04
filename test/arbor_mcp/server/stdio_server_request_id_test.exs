defmodule Arbor.MCP.Server.StdioServerRequestIdTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{HandlerServer, Runtime, StdioServer}
  alias Arbor.MCP.Server.Runtime.Ref

  defmodule CountingHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{list_calls: 0}}

    defoverridable handle_call: 3
    def handle_call(:list_calls, _from, state), do: {:reply, state.list_calls, state}

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok, [], nil, Map.update!(state, :list_calls, &(&1 + 1))}
    end
  end

  setup do
    logger_level = Logger.level()
    otp_logger_level = :logger.get_primary_config()[:level]
    logger_app_level = Application.get_env(:logger, :level)
    stdio_mode = Application.get_env(:arbor_mcp, :stdio_mode)
    startup_delay = Application.get_env(:arbor_mcp, :stdio_startup_delay)

    Application.put_env(:arbor_mcp, :stdio_startup_delay, 60_000)

    on_exit(fn ->
      Logger.configure(level: logger_level)
      :logger.set_primary_config(:level, otp_logger_level)
      restore_env(:logger, :level, logger_app_level)
      restore_env(:arbor_mcp, :stdio_mode, stdio_mode)
      restore_env(:arbor_mcp, :stdio_startup_delay, startup_delay)
    end)

    :ok
  end

  test "stdio rejects a duplicate process-lifetime request ID before dispatch" do
    output =
      capture_io("", fn ->
        {:ok, server} = StdioServer.start_link(module: CountingHandler)
        Process.unlink(server)

        request = %{"jsonrpc" => "2.0", "id" => "stdio-duplicate", "method" => "tools/list"}
        {:ok, runtime} = Runtime.ref(server)
        {:ok, edge} = Runtime.edge(runtime)

        [{:edge_connection, ^edge, connection}] =
          :ets.lookup(Ref.table(runtime), :edge_connection)

        :ok = HandlerServer.ingress(runtime, edge, connection, request)
        :ok = HandlerServer.ingress(runtime, edge, connection, request)
        assert Server.call(runtime, :list_calls) == 1
        state = :sys.get_state(edge)
        assert MapSet.size(state.validation_state.seen_request_ids) == 1

        monitor = Process.monitor(server)
        :ok = Runtime.stop(server)
        assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
      end)

    [first, duplicate] =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert %{"id" => "stdio-duplicate", "result" => %{"tools" => []}} = first

    assert %{
             "id" => "stdio-duplicate",
             "error" => %{
               "code" => -32600,
               "data" => %{"type" => "duplicate_request_id"}
             }
           } = duplicate
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
