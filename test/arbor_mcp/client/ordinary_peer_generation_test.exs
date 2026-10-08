defmodule Arbor.MCP.Client.OrdinaryPeerGenerationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Lifetime
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.HandlerServer

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{test: opts[:test], count: 0}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{name: "ordinary-generation", version: "2"},
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_call_tool("hold", _args, state) do
      send(state.test, {:old_callback, self()})

      receive do
        :release -> {:ok, %{content: []}, %{state | count: state.count + 1}}
      end
    end

    def handle_call_tool("read", _args, state),
      do: {:ok, %{content: [], structuredContent: %{count: state.count}}, state}
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler
    def init(opts), do: {:ok, %{test: opts[:test], count: 0}}
    def handle_ping(state), do: {:ok, %{}, state}
    def handle_list_roots(state), do: {:ok, [], state}

    def handle_create_message(_params, state) do
      send(state.test, :client_callback_ran)
      {:ok, %{}, %{state | count: state.count + 1}}
    end
  end

  for transport <- [:test, :beam] do
    @transport transport
    test "#{transport} reconnect retires held work and an actual already-enqueued old control" do
      {:ok, server} =
        HandlerServer.start_link(
          transport: @transport,
          handler: Handler,
          handler_args: [test: self()],
          cancel_grace_ms: 20
        )

      on_exit(fn -> stop_server(server) end)

      {:ok, client} =
        Client.start_link(
          transport: @transport,
          server: server,
          handler: {ClientHandler, [test: self()]},
          reconnect_backoff: [initial: 20, max: 20, multiplier: 1],
          capabilities: %{"sampling" => %{}}
        )

      on_exit(fn -> if Process.alive?(client), do: Client.stop(client) end)
      old_context = Lifetime.from_client(client)
      held = Task.async(fn -> Client.call_tool(client, "hold", %{}, 2_000) end)
      assert_receive {:old_callback, worker}, 1_000
      worker_monitor = Process.monitor(worker)

      :ok = :sys.suspend(client)
      send(client, {:transport_closed, :generation_test})
      # Execute the real reconnect before the following old peer frame is read.
      send(client, :attempt_reconnect)

      reverse = Task.async(fn -> Server.create_message(server, %{}) end)
      {_observer, _token, old_epoch} = old_context
      wait_queued(client, old_epoch)
      :ok = :sys.resume(client)

      assert {:error, _reason} = Task.await(held)
      assert {:error, :connection_closed} = Task.await(reverse)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
      wait_ready(client, old_context)
      refute_receive :client_callback_ran, 30
      assert :sys.get_state(client).client_handler == nil
      assert {:ok, %{}} = Server.create_message(server, %{})
      assert_receive :client_callback_ran, 1_000
      assert {ClientHandler, %{count: 1}} = :sys.get_state(client).client_handler
      assert {:ok, result} = Client.call_tool(client, "read", %{}, 1_000)
      assert result.structuredOutput == %{"count" => 0}
      assert :ok = Client.stop(client)
    end
  end

  test "an event context cannot claim a different peer owner" do
    {:ok, server} = HandlerServer.start_link(transport: :test, handler: Handler, handler_args: [])
    on_exit(fn -> stop_server(server) end)

    borrowed =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(borrowed, :stop) end)

    assert {:error, :invalid_peer_event_context} =
             HandlerServer.connect(server, borrowed,
               peer_event_context: %{owner: borrowed, epoch: make_ref()}
             )

    assert Process.alive?(borrowed)
  end

  defp stop_server(server) do
    if Process.alive?(server), do: Supervisor.stop(server)
  catch
    :exit, _already_stopped -> :ok
  end

  defp wait_queued(client, epoch, attempts \\ 100)
  defp wait_queued(_client, _epoch, 0), do: flunk("old peer frame was not queued")

  defp wait_queued(client, epoch, attempts) do
    {:messages, messages} = Process.info(client, :messages)

    if Enum.any?(messages, &match?({:client_lifetime_event, ^epoch, _}, &1)) do
      :ok
    else
      Process.sleep(5)
      wait_queued(client, epoch, attempts - 1)
    end
  end

  defp wait_ready(client, old_context, attempts \\ 100)
  defp wait_ready(_client, _old_context, 0), do: flunk("client did not open a fresh generation")

  defp wait_ready(client, old_context, attempts) do
    if :sys.get_state(client).connection_status == :ready and
         Lifetime.from_client(client) != old_context do
      :ok
    else
      Process.sleep(5)
      wait_ready(client, old_context, attempts - 1)
    end
  end
end
