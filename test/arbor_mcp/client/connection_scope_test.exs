defmodule Arbor.MCP.Client.ConnectionScopeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.ConnectionScope
  alias Arbor.MCP.Client.ConnectionScope.Ref
  alias Arbor.MCP.Client.RequestHandler
  alias Arbor.MCP.Server.{HandlerServer, Runtime}
  alias Arbor.MCP.Testing.MockServer
  alias Arbor.RPC.Subprocess

  defmodule Transport do
    @behaviour Arbor.MCP.Transport
    defstruct [:test, :pending, :close, :backend, :reject_initialize, :pull]

    @impl true
    def connect(opts) do
      test = Keyword.fetch!(opts, :test)
      scope = ConnectionScope.current()
      send(test, {:opening, self(), Ref.observer(scope)})

      if opts[:block_connect] do
        receive do
          :continue_connect -> :ok
        end
      end

      {:ok,
       %__MODULE__{
         test: test,
         close: opts[:close],
         backend: opts[:backend],
         reject_initialize: opts[:reject_initialize],
         pull: opts[:pull]
       }}
    end

    @impl true
    def send_message(_message, %{reject_initialize: true}), do: {:error, :handshake_rejected}

    def send_message(message, state) do
      case Jason.decode!(message) do
        %{"id" => id, "method" => "initialize"} ->
          reply =
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => "2025-11-25",
                "serverInfo" => %{"name" => "scope", "version" => "1"},
                "capabilities" => %{}
              }
            })

          {:ok, %{state | pending: reply}}

        _message ->
          {:ok, state}
      end
    end

    @impl true
    def receive_message(%{pending: pending} = state) when is_binary(pending),
      do: {:ok, pending, %{state | pending: nil}}

    def receive_message(%{pull: true, test: test}) do
      Process.flag(:trap_exit, true)
      send(test, {:pull_receiver, self()})

      receive do
        :release_receiver -> {:error, :closed}
      end
    end

    def receive_message(_state), do: {:error, :closed}
    @impl true
    def close(state) do
      send(state.test, {:closing, self()})

      case state.close do
        :block ->
          receive do
            :continue_close -> :ok
          end

        {:error, _reason} = error ->
          error

        {:invalid, result} ->
          result

        _value ->
          :ok
      end
    end

    @impl true
    def connected?(_state), do: true
    @impl true
    def subscribe(_pid, %{pull: true}), do: {:error, :use_pull}
    def subscribe(_pid, state), do: {:ok, state}
    @impl true
    def capabilities(_state), do: [:push]
  end

  defmodule Handler do
    use Arbor.MCP.Server.Handler
  end

  defmodule SlowHandler do
    @behaviour Arbor.MCP.Client.Handler
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test)}
    def handle_ping(state), do: {:ok, %{}, state}
    def handle_list_roots(state), do: {:ok, [], state}

    def handle_create_message(_params, test) do
      send(test, {:reverse_worker, self()})

      receive do
        :release -> {:ok, %{}, test}
      end
    end
  end

  test "callback runs in original caller and native client has its real guardian parent" do
    caller = self()

    assert {:ok, {:result, client, guardian, observer}} =
             with_transport(fn client ->
               assert self() == caller
               {:dictionary, dictionary} = Process.info(client, :dictionary)
               assert {:"$initial_call", {Client, :init, 1}} in dictionary
               {:"$ancestors", [guardian | _]} = List.keyfind(dictionary, :"$ancestors", 0)
               assert guardian != caller
               {:opening, ^client, observer} = receive_message(:opening)
               assert {:links, links} = Process.info(client, :links)
               assert guardian in links
               refute client in elem(Process.info(caller, :links), 1)
               {:result, client, guardian, observer}
             end)

    for pid <- [client, guardian, observer], do: refute(Process.alive?(pid))
    assert {:trap_exit, false} = Process.info(self(), :trap_exit)
    assert_receive {:closing, ^client}
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "mock backend remains alive and usable after owned client cleanup" do
    backend = start_supervised!({MockServer, tools: [MockServer.sample_tool()]})

    assert {:ok, {:ok, result}} =
             Client.with_connection({:mock, server_pid: backend}, fn client ->
               Client.list_tools(client, format: :map)
             end)

    assert [%{"name" => "sample_tool"}] = result["tools"]
    assert Process.alive?(backend)

    assert {:ok, {:ok, _tools}} =
             Client.with_connection({:mock, server_pid: backend}, &Client.list_tools/1)
  end

  test "borrowed BEAM runtime survives caller exceptions and scoped client teardown" do
    runtime = start_supervised!({HandlerServer, handler: Handler, transport: :beam})
    marker = make_ref()

    assert catch_throw(
             Client.with_connection({:beam, server: runtime}, fn client ->
               assert {:ok, _tools} = Client.list_tools(client)
               throw(marker)
             end)
           ) == marker

    assert Process.alive?(runtime)

    assert {:ok, {:ok, _tools}} =
             Client.with_connection({:beam, server: runtime}, &Client.list_tools/1)

    assert is_map(Runtime.stats(runtime))
  end

  test "exceptions and exit reasons survive finite cleanup with original callback frame" do
    assert_raise ArgumentError, "callback marker", fn ->
      with_transport(fn _client -> raise ArgumentError, "callback marker" end)
    end

    assert catch_exit(with_transport(fn _client -> exit(:callback_exit) end)) == :callback_exit
    assert {:trap_exit, false} = Process.info(self(), :trap_exit)
  end

  test "blocked transport init has one native constructor cutoff and never invokes callback" do
    test = self()
    started = System.monotonic_time(:millisecond)

    assert {:error, _reason} =
             Client.with_connection(
               {Transport, test: test, block_connect: true},
               [establish_timeout: 80, cleanup_timeout: 80],
               fn _client ->
                 flunk("callback must not run")
               end
             )

    assert System.monotonic_time(:millisecond) - started < 500
    assert_receive {:opening, client, observer}
    refute Process.alive?(client)
    wait_down(observer)
    assert {:trap_exit, false} = Process.info(self(), :trap_exit)
  end

  test "blocked cleanup reports uncertainty within original bound and removes owned actors" do
    test = self()
    started = System.monotonic_time(:millisecond)

    assert {:error, {:cleanup_failed, _reason, :value}} =
             Client.with_connection(
               {Transport, test: test, close: :block},
               [cleanup_timeout: 80, protocol_mode: :legacy_only],
               fn _client -> :value end
             )

    assert System.monotonic_time(:millisecond) - started < 500
    assert_receive {:opening, client, observer}
    wait_down(client)
    wait_down(observer)
  end

  test "a suspended native client cannot extend cleanup or leak a late reply" do
    assert {:error, {:cleanup_failed, _reason, client}} =
             with_transport(
               fn client ->
                 :ok = :sys.suspend(client)
                 client
               end,
               cleanup_timeout: 80
             )

    wait_down(client)
    assert {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, &match?({reference, _} when is_reference(reference), &1))
  end

  test "abrupt owner death cleans client while borrowed backend survives" do
    backend = start_supervised!({MockServer, []})
    test = self()

    owner =
      spawn(fn ->
        Client.with_connection({:mock, server_pid: backend}, fn client ->
          {:dictionary, dictionary} = Process.info(client, :dictionary)
          {:"$ancestors", [guardian | _]} = List.keyfind(dictionary, :"$ancestors", 0)
          send(test, {:owned, client, guardian})

          receive do
            :hold -> :ok
          end
        end)
      end)

    try do
      assert_receive {:owned, client, guardian}, 1000
      Process.exit(owner, :kill)
      wait_down(client)
      wait_down(guardian)
      assert Process.alive?(backend)
    after
      Process.exit(owner, :kill)
      wait_down(owner)
    end
  end

  test "caller suspended past queued startup success cannot invoke callback or consume late reply" do
    test = self()

    owner =
      spawn(fn ->
        result =
          Client.with_connection(
            {Transport, test: test, block_connect: true},
            [establish_timeout: 120, cleanup_timeout: 300],
            fn _client -> send(test, :callback_ran) end
          )

        send(test, {:late_start, result, Process.info(self(), :messages)})
      end)

    assert_receive {:opening, client, _observer}
    :erlang.suspend_process(owner)
    send(client, :continue_connect)
    Process.sleep(160)
    :erlang.resume_process(owner)
    assert_receive {:late_start, {:error, _reason}, {:messages, []}}, 1000
    refute_receive :callback_ran
    wait_down(client)
  end

  test "scope shuts down a blocked unlinked reverse-request worker before its effects continue" do
    test = self()

    assert {:ok, worker} =
             with_transport(fn client ->
               :sys.replace_state(client, fn state ->
                 state = %{
                   state
                   | transport_opts:
                       Keyword.put(state.transport_opts, :handler, {SlowHandler, [test: test]})
                 }

                 {:noreply, state} =
                   RequestHandler.handle_server_request("sampling/createMessage", %{}, 7, state)

                 state
               end)

               assert_receive {:reverse_worker, worker}
               assert {:links, []} = Process.info(worker, :links)
               worker
             end)

    wait_down(worker)
    send(worker, :release)
    refute_receive {:server_request_result, _, _}
  end

  test "worker capacity refusal prevents second reverse callback effects" do
    test = self()

    assert {:ok, first} =
             with_transport(
               fn client ->
                 assert_receive {:opening, ^client, observer}, 1000
                 wait_scope_workers_idle(observer, System.monotonic_time(:millisecond) + 1000)

                 :sys.replace_state(client, fn state ->
                   state = %{
                     state
                     | transport_opts:
                         Keyword.put(state.transport_opts, :handler, {SlowHandler, [test: test]})
                   }

                   {:noreply, state} =
                     RequestHandler.handle_server_request(
                       "sampling/createMessage",
                       %{},
                       71,
                       state
                     )

                   state
                 end)

                 assert_receive {:reverse_worker, first}

                 :sys.replace_state(client, fn state ->
                   {:noreply, state} =
                     RequestHandler.handle_server_request(
                       "sampling/createMessage",
                       %{},
                       72,
                       state
                     )

                   state
                 end)

                 refute_receive {:reverse_worker, _second}
                 first
               end,
               max_scope_workers: 1
             )

    wait_down(first)
  end

  test "scope observer death cannot orphan a blocked registered worker" do
    test = self()

    assert {:error, {:cleanup_failed, :connection_scope_closed, worker}} =
             with_transport(fn client ->
               assert_receive {:opening, ^client, observer}

               :sys.replace_state(client, fn state ->
                 state = %{
                   state
                   | transport_opts:
                       Keyword.put(state.transport_opts, :handler, {SlowHandler, [test: test]})
                 }

                 {:noreply, state} =
                   RequestHandler.handle_server_request("sampling/createMessage", %{}, 73, state)

                 state
               end)

               assert_receive {:reverse_worker, worker}
               Process.exit(observer, :kill)
               wait_down(observer)
               worker
             end)

    wait_down(worker)
  end

  test "abrupt caller death during native construction cleans proven client before connect returns" do
    test = self()

    owner =
      spawn(fn ->
        Client.with_connection(
          {Transport, test: test, block_connect: true},
          [establish_timeout: 1000, cleanup_timeout: 80],
          fn _client -> send(test, :callback_ran) end
        )
      end)

    assert_receive {:opening, client, observer}
    Process.exit(owner, :kill)
    wait_down(client)
    wait_down(observer)
    refute_receive :callback_ran
  end

  test "observer death during blocked native construction cannot orphan its parent or child" do
    test = self()

    owner =
      spawn(fn ->
        result =
          Client.with_connection(
            {Transport, test: test, block_connect: true},
            [establish_timeout: 10_000, cleanup_timeout: 80],
            fn _client -> send(test, :callback_ran) end
          )

        send(test, {:observer_start_result, result})
      end)

    assert_receive {:opening, client, observer}
    Process.exit(observer, :kill)
    wait_down(client)
    assert_receive {:observer_start_result, {:error, _reason}}, 1000
    wait_down(owner)
    refute_receive :callback_ran
  end

  test "owned client fatal exit does not kill the original callback caller" do
    assert {:error, {:cleanup_failed, :transport_cleanup_unconfirmed, :value}} =
             with_transport(fn client ->
               Process.exit(client, :kill)
               wait_down(client)
               :value
             end)

    assert {:trap_exit, false} = Process.info(self(), :trap_exit)
  end

  test "registered polling task cannot trap its way past owned client cleanup" do
    assert {:ok, receiver} =
             with_transport(
               fn _client ->
                 assert_receive {:pull_receiver, receiver}
                 assert {:trap_exit, true} = Process.info(receiver, :trap_exit)
                 receiver
               end,
               pull: true
             )

    wait_down(receiver)
  end

  test "real stdio child cleanup uses retained typed proof after the client has stopped" do
    python = System.find_executable("python3") || flunk("python3 required for child fixture")

    script = """
    import json, sys
    for line in sys.stdin:
        request = json.loads(line)
        if request.get("method") == "initialize":
            result = {"protocolVersion": "2025-11-25", "serverInfo": {"name": "scope-child", "version": "1"}, "capabilities": {}}
        elif request.get("method") == "tools/list":
            result = {"tools": []}
        else:
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    """

    assert {:ok, {client, child}} =
             Client.with_connection(
               {:stdio, command: [python, "-u", "-c", script]},
               [protocol_mode: :legacy_only, health_check_interval: nil],
               fn client ->
                 assert {:ok, %{"tools" => []}} = Client.list_tools(client, format: :map)
                 child = :sys.get_state(client).transport_state.subprocess
                 {client, child}
               end
             )

    refute Process.alive?(client)
    assert {:ok, receipt} = Subprocess.cleanup_receipt(child)
    assert :ok = Arbor.RPC.Subprocess.Receipt.result(receipt)
  end

  test "unsupported infinite budgets and existing clients fail before effects" do
    assert {:error, {:invalid_connection_scope_option, :establish_timeout}} =
             Client.with_connection(
               {Transport, test: self()},
               [establish_timeout: :infinity],
               fn _ -> :ok end
             )

    assert {:error, :existing_client_not_owned} = Client.with_connection(self(), fn _ -> :ok end)
    refute_receive {:opening, _, _}
  end

  test "explicit transport cleanup failure is preserved with callback value" do
    assert {:error, {:cleanup_failed, :denied, :value}} =
             with_transport(fn _client -> :value end, close: {:error, :denied})
  end

  test "invalid close results during failed establishment remain explicit cleanup errors" do
    assert {:error,
            {:connection_cleanup_failed, {:error, _connection_error},
             {:invalid_close_result, :bad_close}}} =
             with_transport(fn _client -> flunk("callback must not run") end,
               reject_initialize: true,
               close: {:invalid, :bad_close}
             )
  end

  test "a callback exception keeps its original stack after timed-out cleanup" do
    started = System.monotonic_time(:millisecond)

    {error, stack} =
      try do
        with_transport(&raise_marker/1, close: :block, cleanup_timeout: 80)
      rescue
        error -> {error, __STACKTRACE__}
      end

    assert %ArgumentError{message: "original callback frame"} = error

    assert Enum.any?(stack, fn {module, function, _arity, _metadata} ->
             module == __MODULE__ and function == :raise_marker
           end)

    assert System.monotonic_time(:millisecond) - started < 500
  end

  defp raise_marker(_client), do: raise(ArgumentError, "original callback frame")

  defp with_transport(callback, opts \\ []) do
    {transport_opts, scope_opts} =
      Keyword.split(opts, [:close, :backend, :reject_initialize, :pull])

    Client.with_connection(
      {Transport, Keyword.put(transport_opts, :test, self())},
      Keyword.merge([protocol_mode: :legacy_only, health_check_interval: nil], scope_opts),
      callback
    )
  end

  defp receive_message(tag) do
    receive do
      {^tag, _, _} = message -> message
    after
      1000 -> flunk("missing #{tag}")
    end
  end

  # Native initialization returns before the Observer necessarily consumes its
  # receive Task's actual DOWN. Establish the empty-capacity setup separately
  # before testing one accepted worker and a second refusal.
  defp wait_scope_workers_idle(observer, cutoff) do
    remaining = max(cutoff - System.monotonic_time(:millisecond), 0)
    assert remaining > 0, "initialization worker credit did not settle"

    if map_size(:sys.get_state(observer, remaining).workers) != 0 do
      Process.sleep(1)
      wait_scope_workers_idle(observer, cutoff)
    end
  end

  defp wait_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1000
  end
end
