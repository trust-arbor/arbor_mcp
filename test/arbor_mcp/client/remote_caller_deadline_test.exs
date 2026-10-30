defmodule Arbor.MCP.Client.RemoteCallerDeadlineTest do
  # Every deadline the client compares must be on its own monotonic clock. A
  # caller on another node computes its deadline on that node's clock, which
  # may trail or lead this one by any amount, so the client counts the
  # caller's relative timeout (or its own cleanup budget) from now instead.
  #
  # The suite has no peer-node setup, so these tests stand a remote caller in
  # with a pid on a node this VM isn't connected to, and call the client's
  # request path directly with that caller's `from`.
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.RequestHandler
  alias Arbor.MCP.Testing.MockServer

  # A send that fails at once, so the reply says how the client classified
  # the failure.
  defmodule FailingTransport do
    def send_message(_encoded, _state), do: {:error, :refused}
  end

  # A caller node whose monotonic clock trails this one by a minute: its
  # 30-second deadline is already half a minute in this node's past.
  defp trailing_meta do
    %{
      timeout: 30_000,
      deadline: System.monotonic_time(:millisecond) - 60_000,
      cache_mode: :bypass,
      cancel_on_caller_exit: false
    }
  end

  test "a remote caller's fresh request is sent within its own timeout" do
    {:ok, server} = MockServer.start_link(tools: [MockServer.sample_tool()])
    on_exit(fn -> Arbor.MCP.TestHelpers.safe_stop_process(server) end)

    {:ok, client} =
      Client.start_link(
        transport: [type: :mock, server_pid: server],
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> Arbor.MCP.TestHelpers.safe_stop_process(client) end)
    state = :sys.get_state(client)

    # The mock transport caps each exchange at its transport deadline.
    assert {:reply, {:ok, %{"tools" => [_tool]}}, _state} =
             RequestHandler.handle_request(
               "tools/list",
               %{},
               {remote_pid(), make_ref()},
               state,
               trailing_meta()
             )
  end

  test "a remote caller's failed send is a send failure, not its timeout" do
    {:ok, client} =
      start_supervised({Client, _skip_connect: true, health_check_interval: nil})

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: FailingTransport,
          transport_state: %{},
          protocol_version: "2025-06-18",
          connection_status: :ready,
          initialized: true
      }
    end)

    state = :sys.get_state(client)

    assert {:reply, {:error, error}, _state} =
             RequestHandler.handle_request(
               "tools/list",
               %{},
               {remote_pid(), make_ref()},
               state,
               trailing_meta()
             )

    refute error == :timeout
  end

  test "a remote caller's disconnect gets the client's whole cleanup budget" do
    {:ok, server} = MockServer.start_link([])
    on_exit(fn -> Arbor.MCP.TestHelpers.safe_stop_process(server) end)

    {:ok, client} =
      Client.start_link(
        transport: [type: :mock, server_pid: server],
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> Arbor.MCP.TestHelpers.safe_stop_process(client) end)

    # A disconnect from a remote caller, as GenServer.call sends it, with a
    # deadline on a clock that trails this one by a minute. The reply tag is
    # an alias of this process, which OTP replies to, so the test sees the
    # remote caller's own answer.
    foreign = System.monotonic_time(:millisecond) - 60_000
    tag = [:alias | :erlang.alias()]
    send(client, {:"$gen_call", {remote_pid(), tag}, {:ordinary_disconnect, foreign}})

    assert_receive {^tag, reply}, 10_000
    assert reply == :ok
  end

  # A pid on a node this VM isn't connected to.
  defp remote_pid do
    node = "remote@nowhere"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>)
  end
end
