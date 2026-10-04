defmodule Arbor.MCP.Server.RuntimeCharacterizationTest do
  @moduledoc """
  Runtime migration tests preserve 1.x wire/state behavior while checking the
  v2 contract: handlers execute in supervised callback tasks, and a responsive
  protocol edge remains distinct from its runtime supervisor.
  """
  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Response
  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.Handler
  alias Arbor.MCP.Server.HandlerServer
  alias Arbor.MCP.Server.Runtime

  defmodule RuntimeHandler do
    @moduledoc false
    @behaviour Handler

    def init(args) do
      {:ok,
       %{
         test_pid: Keyword.get(args, :test_pid),
         gate: Keyword.get(args, :gate),
         token: Keyword.get(args, :token, "handler"),
         counter: 0
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         name: "runtime-characterization-handler",
         version: "1.0.0",
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "identity", description: "Records callback pid and links"},
        %{name: "inc", description: "Increments handler state"},
        %{name: "slow", description: "Polls Context.cancelled?"},
        %{name: "block", description: "Waits on a test gate"}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("identity", _args, state) do
      send(state.test_pid, {:callback_identity, identity_snapshot()})
      {:ok, %{content: [%{type: "text", text: "ok"}]}, state}
    end

    def handle_call_tool("inc", _args, state) do
      count = state.counter + 1

      {:ok, %{content: [%{type: "text", text: "#{state.token}:#{count}"}]},
       %{state | counter: count}}
    end

    def handle_call_tool("slow", _args, state) do
      request_id =
        case Context.current() do
          %{request_id: id} -> id
          _other -> nil
        end

      send(state.test_pid, {:handler_started, request_id})

      observed =
        Enum.reduce_while(1..80, false, fn _i, _acc ->
          if Context.cancelled?() do
            {:halt, true}
          else
            Process.sleep(25)
            {:cont, false}
          end
        end)

      send(state.test_pid, {:observed_cancel, observed})

      if observed do
        {:error, "Import cancelled", state}
      else
        {:ok, %{content: [%{type: "text", text: "finished"}]}, state}
      end
    end

    def handle_call_tool("block", _args, state) do
      send(state.test_pid, {:blocked, identity_snapshot()})
      wait_for_gate(state.gate)
      {:ok, %{content: [%{type: "text", text: "released"}]}, state}
    end

    def handle_call_tool(name, _args, state) do
      {:error, "Unknown tool: #{name}", state}
    end

    def terminate(_reason, _state), do: :ok

    defp identity_snapshot do
      {:links, links} = Process.info(self(), :links)
      %{pid: self(), links: links}
    end

    defp wait_for_gate(nil), do: :ok

    defp wait_for_gate(gate) do
      if Agent.get(gate, & &1) == :go do
        :ok
      else
        Process.sleep(10)
        wait_for_gate(gate)
      end
    end
  end

  defmodule RuntimeDSL do
    use Handler
    use Arbor.MCP.Server.DSL, name: "runtime-characterization-dsl", version: "1.0.0"

    def init(args) do
      {:ok,
       %{
         test_pid: Keyword.get(args, :test_pid),
         token: Keyword.get(args, :token, "dsl"),
         counter: 0
       }}
    end

    tool "identity", "Records callback pid and links" do
      run(fn _args, state ->
        {:links, links} = Process.info(self(), :links)
        send(state.test_pid, {:callback_identity, %{pid: self(), links: links}})
        {:ok, ToolResult.text("ok"), state}
      end)
    end

    tool "inc", "Increments handler state" do
      run(fn _args, state ->
        count = state.counter + 1
        {:ok, ToolResult.text("#{state.token}:#{count}"), %{state | counter: count}}
      end)
    end
  end

  describe "callback process identity" do
    test "Handler callback runs outside its unnamed runtime and protocol edge" do
      {server, client} = start_pair(RuntimeHandler, test_pid: self())

      try do
        assert {:ok, _result} = Client.call_tool(client, "identity", %{})
        assert_receive {:callback_identity, snapshot}, 1_000

        {:ok, edge} = Runtime.edge(server)
        refute snapshot.pid in [server, edge]
        refute self() in snapshot.links
        refute client in snapshot.links
        assert snapshot.links != []
        assert {:registered_name, []} = Process.info(server, :registered_name)
        {:links, root_links} = Process.info(server, :links)
        assert self() in root_links
      after
        stop_pair(server, client)
      end
    end

    test "DSL callback uses the same supervised runtime contract" do
      {:ok, server} =
        RuntimeDSL.start_link(
          transport: :test,
          handler_args: [test_pid: self()]
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          reconnect: false
        )

      try do
        assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
        assert {:registered_name, []} = Process.info(server, :registered_name)
        assert {:registered_name, []} = Process.info(client, :registered_name)

        assert {:ok, _result} = Client.call_tool(client, "identity", %{})
        assert_receive {:callback_identity, snapshot}, 1_000

        {:ok, edge} = Runtime.edge(server)
        refute snapshot.pid in [server, edge]
        refute self() in snapshot.links
        refute client in snapshot.links
        assert snapshot.links != []
      after
        stop_pair(server, client)
      end
    end
  end

  describe "timeout and cancellation" do
    test "slow tool observes Context.cancelled? after notifications/cancelled" do
      {server, client} = start_pair(RuntimeHandler, test_pid: self())

      try do
        task =
          Task.async(fn ->
            Client.call_tool(client, "slow", %{})
          end)

        assert_receive {:handler_started, request_id}, 2_000
        assert request_id

        wait_until(fn -> request_id in Client.get_pending_requests(client) end, timeout: 5_000)

        # Cancellation reaches the invocation-scoped runtime control path
        # while the callback is running, without a global request-ID table.
        :ok = Client.send_cancelled(client, request_id, "User cancelled")

        assert_receive {:observed_cancel, true}, 3_000
        assert match?({:error, _}, Task.await(task, 5_000))
      after
        stop_pair(server, client)
      end
    end

    test "HandlerServer/:test client timeout does not abort the in-process callback" do
      {:ok, gate} = Agent.start_link(fn -> :wait end)

      {server, client} =
        start_pair(RuntimeHandler, test_pid: self(), gate: gate)

      try do
        task =
          Task.async(fn ->
            Client.call_tool(client, "block", %{}, timeout: 200)
          end)

        assert_receive {:blocked, snapshot}, 2_000
        refute snapshot.pid == server

        assert {:error, %Arbor.MCP.Error.ProtocolError{} = error} = Task.await(task, 2_000)
        assert error.code == -32603
        assert error.message == "Request timeout"

        # A client wait timeout leaves accepted server work running until
        # its independent runtime deadline or an explicit cancellation.
        assert Process.alive?(server)
        assert Process.alive?(client)

        :ok = Agent.update(gate, fn _ -> :go end)

        assert {:ok, result} = Client.call_tool(client, "inc", %{})
        assert Response.text_content(result) == "handler:1"
      after
        if Process.alive?(gate), do: Agent.update(gate, fn _ -> :go end)
        stop_pair(server, client)
        if Process.alive?(gate), do: Agent.stop(gate)
      end
    end
  end

  describe "state ordering" do
    test "sequential tool calls observe serialized stateful increments 1 then 2" do
      {server, client} = start_pair(RuntimeHandler, token: "seq")

      try do
        # The default scheduler serializes stateful proposals and commits
        # each before the following callback takes its state snapshot.
        assert {:ok, first} = Client.call_tool(client, "inc", %{})
        assert {:ok, second} = Client.call_tool(client, "inc", %{})

        assert Response.text_content(first) == "seq:1"
        assert Response.text_content(second) == "seq:2"
      after
        stop_pair(server, client)
      end
    end
  end

  describe "per-server isolation" do
    test "two unnamed Handler/DSL servers do not share state and survive a sibling stop" do
      {:ok, server_a} =
        RuntimeDSL.start_link(
          transport: :test,
          handler_args: [token: "a"]
        )

      {:ok, server_b} =
        RuntimeDSL.start_link(
          transport: :test,
          handler_args: [token: "b"]
        )

      {:ok, client_a} =
        Client.start_link(transport: :test, server: server_a, reconnect: false)

      {:ok, client_b} =
        Client.start_link(transport: :test, server: server_b, reconnect: false)

      try do
        assert {:ok, %{connection_status: :ready}} = Client.get_status(client_a)
        assert {:ok, %{connection_status: :ready}} = Client.get_status(client_b)

        assert {:registered_name, []} = Process.info(server_a, :registered_name)
        assert {:registered_name, []} = Process.info(server_b, :registered_name)
        refute server_a == server_b

        assert {:ok, a1} = Client.call_tool(client_a, "inc", %{})
        assert {:ok, a2} = Client.call_tool(client_a, "inc", %{})
        assert {:ok, b1} = Client.call_tool(client_b, "inc", %{})

        # Each runtime owns its handler state. Two
        # transport: :test servers in one VM do not leak counters, and
        # stopping one does not take the other down.
        assert Response.text_content(a1) == "a:1"
        assert Response.text_content(a2) == "a:2"
        assert Response.text_content(b1) == "b:1"

        if Process.alive?(client_a), do: GenServer.stop(client_a)
        if Process.alive?(server_a), do: Runtime.stop(server_a)

        refute Process.alive?(server_a)
        assert Process.alive?(server_b)
        assert Process.alive?(client_b)

        assert {:ok, b2} = Client.call_tool(client_b, "inc", %{})
        assert Response.text_content(b2) == "b:2"
      after
        stop_pair(server_a, client_a)
        stop_pair(server_b, client_b)
      end
    end
  end

  defp start_pair(handler, handler_args) do
    {:ok, server} =
      HandlerServer.start_link(
        transport: :test,
        handler: handler,
        handler_args: handler_args
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        reconnect: false
      )

    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
    assert {:registered_name, []} = Process.info(server, :registered_name)
    assert {:registered_name, []} = Process.info(client, :registered_name)
    {server, client}
  end

  defp stop_pair(server, client) do
    if is_pid(client) and Process.alive?(client), do: GenServer.stop(client)
    if is_pid(server) and Process.alive?(server), do: Runtime.stop(server)
  end
end
