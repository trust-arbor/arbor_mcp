defmodule Arbor.MCP.Client.LinkExitTest do
  @moduledoc """
  `Arbor.MCP.Client` traps exits. An exit signal from a process the transport or
  the client itself linked is a transport failure; an abnormal exit from any
  other link stops the client, as it would stop a process that does not trap
  exits, and a stopping client closes its transport.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Lifetime

  defmodule PullTransport do
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts),
      do:
        {:ok,
         %{
           test_pid: Keyword.fetch!(opts, :test_pid),
           helper: nil,
           native_owner: self(),
           lifetime: Lifetime.current()
         }}

    @impl true
    def send_message(message, state) do
      case Jason.decode!(message) do
        %{"method" => "initialize", "id" => id} ->
          result = %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "link-exit", "version" => "1"}
          }

          response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
          send(self(), {:link_transport_response, response})

        _other ->
          :ok
      end

      {:ok, state}
    end

    @impl true
    def receive_message(state) do
      receive do
        {:link_transport_response, response} -> {:ok, response, state}
      end
    end

    def receive_message(state, timeout) do
      receive do
        {:link_transport_response, response} -> {:ok, response, state}
      after
        timeout -> {:error, :handshake_timeout}
      end
    end

    @impl true
    def close(state) do
      context = Lifetime.current()
      {observer, _token, _epoch} = context
      registered_before_effect? = Map.has_key?(:sys.get_state(observer).workers, self())

      send(
        state.test_pid,
        {:link_transport_closed, state.native_owner, self(), context, registered_before_effect?}
      )

      :ok
    end

    @impl true
    def linked_processes(%{helper: helper}) when is_pid(helper), do: [helper]
    def linked_processes(_state), do: []
  end

  defmodule PushTransport do
    @behaviour Arbor.MCP.Transport

    @impl true
    defdelegate connect(opts), to: PullTransport
    @impl true
    defdelegate send_message(message, state), to: PullTransport
    @impl true
    defdelegate receive_message(state), to: PullTransport
    defdelegate receive_message(state, timeout), to: PullTransport
    @impl true
    defdelegate close(state), to: PullTransport
    @impl true
    defdelegate linked_processes(state), to: PullTransport

    @impl true
    def subscribe(_client, state) do
      helper =
        spawn_link(fn ->
          receive do
            {:exit, reason} -> exit(reason)
          end
        end)

      send(state.test_pid, {:transport_helper, helper})
      {:ok, %{state | helper: helper}}
    end
  end

  for {mode, transport} <- [push: PushTransport, pull: PullTransport] do
    describe "#{mode} mode" do
      test "a foreign link's abnormal exit stops the client and closes the transport" do
        client = start_client(unquote(transport))
        monitor = Process.monitor(client)

        foreign = linked_to(client)
        send(foreign, {:exit, :boom})

        assert_receive {:DOWN, ^monitor, :process, ^client, :boom}, 2_000
        assert_closed_by_owned_worker(client)
      end

      test "a foreign link's normal exit is ignored" do
        client = start_client(unquote(transport))

        foreign = linked_to(client)
        foreign_monitor = Process.monitor(foreign)
        send(foreign, {:exit, :normal})
        assert_receive {:DOWN, ^foreign_monitor, :process, ^foreign, :normal}, 2_000

        assert %{connection_status: :ready} = :sys.get_state(client)
        refute_received {:link_transport_closed, _client, _worker, _context, _registered}
      end

      test "the receiver the client retires on transport loss cannot stop it" do
        client = start_client(unquote(transport))
        attach_disconnected(client)

        send(client, {:transport_closed, :peer_went_away})
        assert_receive {:client_disconnected, :peer_went_away}, 2_000

        assert %{connection_status: :disconnected} = :sys.get_state(client)
        assert Process.alive?(client)
      end
    end
  end

  test "a crashed pull-mode receiver closes the transport before the client moves on" do
    client = start_client(PullTransport)
    attach_disconnected(client)
    %{receiver_task: %Task{pid: receiver}} = :sys.get_state(client)

    Process.exit(receiver, :kill)

    assert_receive {:client_disconnected, {:receiver_task_died, :killed}}, 2_000
    assert_closed_by_owned_worker(client)
    assert %{connection_status: :disconnected} = :sys.get_state(client)
  end

  test "a transport-owned link's crash is a transport failure, not a stop" do
    client = start_client(PushTransport)
    assert_receive {:transport_helper, helper}, 2_000
    attach_disconnected(client)

    send(helper, {:exit, :helper_crashed})

    assert_receive {:client_disconnected, {:transport_forwarder_died, :helper_crashed}}, 2_000
    assert_closed_by_owned_worker(client)
    assert %{connection_status: :disconnected} = :sys.get_state(client)
  end

  test "a transport-owned link's normal exit is left to the transport" do
    client = start_client(PushTransport)
    assert_receive {:transport_helper, helper}, 2_000
    helper_monitor = Process.monitor(helper)

    send(helper, {:exit, :normal})
    assert_receive {:DOWN, ^helper_monitor, :process, ^helper, :normal}, 2_000

    assert %{connection_status: :ready} = :sys.get_state(client)
  end

  test "the starter's death stops the client and closes its transport" do
    test_pid = self()

    starter =
      spawn(fn ->
        {:ok, client} = Client.start_link(client_opts(PushTransport, test_pid))
        send(test_pid, {:started, client})

        receive do
          :exit -> exit(:starter_gone)
        end
      end)

    assert_receive {:started, client}, 2_000
    monitor = Process.monitor(client)

    send(starter, :exit)

    assert_receive {:DOWN, ^monitor, :process, ^client, :starter_gone}, 2_000
    assert_closed_by_owned_worker(client)
  end

  defp assert_closed_by_owned_worker(client) do
    assert_receive {:link_transport_closed, ^client, worker, {observer, token, epoch}, true},
                   2_000

    assert is_pid(worker) and worker != client
    assert is_pid(observer) and is_reference(token) and is_reference(epoch)
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
  end

  defp start_client(transport) do
    {:ok, client} = Client.start_link(client_opts(transport, self()))
    # The test process is the starter; keep its own exit out of the picture.
    Process.unlink(client)
    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    client
  end

  defp client_opts(transport, test_pid) do
    [
      transport: transport,
      test_pid: test_pid,
      protocol_mode: :legacy_only,
      health_check_interval: nil,
      reconnect: false
    ]
  end

  defp linked_to(client) do
    test_pid = self()

    foreign =
      spawn(fn ->
        Process.link(client)
        send(test_pid, {:linked, self()})

        receive do
          {:exit, reason} -> exit(reason)
        end
      end)

    assert_receive {:linked, ^foreign}, 2_000
    foreign
  end

  defp attach_disconnected(client) do
    test_pid = self()
    handler = "link-exit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arbor_mcp, :client, :disconnected],
      fn _event, _measurements, metadata, _config ->
        if Map.get(metadata, :pid) == client do
          send(test_pid, {:client_disconnected, metadata.reason})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
