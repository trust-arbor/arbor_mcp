defmodule Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Journal do
  def record(stage, values) do
    sequence = :ets.update_counter(:http_dead_writer_receipt_events, :counter, 1)
    if sequence > 64, do: raise("bounded control journal exhausted")

    values =
      Map.new(values, fn {key, value} ->
        {key, if(is_pid(value) or is_reference(value), do: inspect(value), else: value)}
      end)

    :ets.insert(:http_dead_writer_receipt_events, {sequence, Map.put(values, :stage, stage)})
  end
end

defmodule Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Handler do
  use Arbor.MCP.Server.Handler

  def init(opts), do: {:ok, %{observer: opts[:observer], calls: 0}}
  def __server_info__, do: %{"name" => "predecessor-control", "version" => "1.0.0"}
  def __server_capabilities__, do: %{"tools" => %{}}

  def handle_list_tools(_cursor, state) do
    send(state.observer, {:list_callback, self(), state.calls})

    {:ok, [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}],
     %{state | calls: state.calls + 1}}
  end
end

defmodule Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Dispatcher do
  def dispatch(request, module, state, opts) do
    context = Arbor.MCP.Server.Runtime.CallbackContext.current()
    send(state.observer, {:actual_method, request["method"], self(), context})
    Arbor.MCP.Server.Dispatch.dispatch(request, module, state, opts)
  end
end

defmodule Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Socket do
  use GenServer
  alias Arbor.MCP.HttpPlug.RuntimeWriter
  alias Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Journal

  alias Arbor.MCP.Server.Runtime.{
    HTTPGateway,
    HTTPWriterBinding,
    HTTPWriterRegistry,
    HTTPWriteTicket
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, Map.new(opts)}

  def handle_call({:post, request}, _from, state) do
    conn = RuntimeWriter.capture(Plug.Test.conn(:post, "/mcp"), state.runtime)
    binding = RuntimeWriter.binding(conn)
    {:ok, proof} = HTTPWriterBinding.validate(binding, state.runtime)
    {:ok, token} = HTTPGateway.submit(state.runtime, binding, request)
    method = request["method"]

    Journal.record(:admitted, %{
      socket: self(),
      method: method,
      token: token,
      generation: proof.generation,
      deadline: proof.deadline
    })

    send(state.observer, {:admitted, self(), method, token, proof.generation, proof.deadline})
    {:ok, effect, wire} = RuntimeWriter.await(conn)

    result =
      RuntimeWriter.perform(conn, effect, wire, fn conn, wire ->
        result = Plug.Conn.send_resp(conn, 200, wire)

        Journal.record(:adapter_returned, %{
          socket: self(),
          method: method,
          token: token,
          receipt: HTTPWriteTicket.receipt(effect)
        })

        send(state.observer, {:adapter_returned, self(), method, token})

        send(state.observer, {:entered_effect, self(), token, effect})
        if state.hold?, do: wait_return(System.monotonic_time(:millisecond) + 5_000)

        result
      end)

    send(state.observer, {:receipt_recorded, self(), method, token})

    Journal.record(:receipt_recorded, %{
      socket: self(),
      method: method,
      token: token,
      receipt: HTTPWriteTicket.receipt(effect)
    })

    {:reply, {:ok, result.resp_body}, Map.merge(state, %{binding: binding, token: token})}
  end

  def handle_call(:retire, _from, state) do
    result = HTTPWriterRegistry.retire(state.binding, :fixture_socket_returned)
    {:reply, result, state}
  end

  def handle_info({:mcp_http_output_wake, domain, nonce}, state) do
    :ok = HTTPWriterRegistry.acknowledge_wake(domain, nonce)
    {:noreply, state}
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}

  def handle_info({reference, {_status, _headers, _body}}, state) when is_reference(reference),
    do: {:noreply, state}

  defp wait_return(cutoff) do
    receive do
      :allow_receipt ->
        :ok

      {:probe_return, observer, nonce, ticket, result} ->
        send(observer, {:probe_reply, nonce, HTTPWriterRegistry.complete(ticket, result)})
        wait_return(cutoff)
    after
      max(cutoff - System.monotonic_time(:millisecond), 0) ->
        raise "receipt fixture release missing"
    end
  end
end

defmodule Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest do
  use ExUnit.Case, async: false
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.{HTTPWriterProxy, HTTPWriterRegistry, HTTPWriteTicket}

  setup do
    :ets.new(:http_dead_writer_receipt_events, [:named_table, :public])
    :ets.insert(:http_dead_writer_receipt_events, {:counter, 0})
    :ok
  end

  test "dead entered writer preserves uncertainty and releases the next callback" do
    {runtime, socket, call, effect, _deadline} = entered()
    assert HTTPWriteTicket.receipt(effect) == 0
    assert {:error, :invalid_http_writer} = HTTPWriterRegistry.complete(effect, :ok)
    assert {:error, :invalid_http_writer} = HTTPWriteTicket.record_return(effect, 1)
    monitor = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^socket, :killed}, 1_000
    assert {:exit, _reason} = Task.await(call, 1_000)
    wait(fn -> HTTPWriteTicket.receipt(effect) == 3 end)
    wait(fn -> stats(runtime).frames == 0 end)
    next = socket(runtime, false)
    result = Task.async(fn -> GenServer.call(next, {:post, request("tools/list", 2)}, 5_000) end)
    assert_receive {:list_callback, _, 0}, 1_000
    assert {:ok, body} = Task.await(result, 5_000)
    assert %{"result" => %{"tools" => [%{"name" => "echo"}]}} = Jason.decode!(body)
    assert HTTPWriteTicket.receipt(effect) == 3
    assert {:error, :invalid_http_writer} = HTTPWriteTicket.record_return(effect, 1)
    refute_receive {:list_callback, _, _}, 30
    assert :ok = GenServer.call(next, :retire)
    wait(fn -> Runtime.stats!(runtime).reserved == 0 and stats(runtime).frames == 0 end)
    assert :ok = Runtime.stop(runtime)
  end

  test "live expired entered IO remains charged until the actual adapter returns" do
    {runtime, socket, call, effect, deadline} = entered(request_timeout_ms: 100)
    assert deadline > System.monotonic_time(:millisecond)
    Process.sleep(max(deadline - System.monotonic_time(:millisecond), 0) + 30)
    assert Process.alive?(socket)
    assert HTTPWriteTicket.receipt(effect) == 0
    assert %{frames: 1, in_flight: 1} = stats(runtime)
    send(socket, :allow_receipt)
    assert {:ok, _body} = Task.await(call, 1_000)
    wait(fn -> HTTPWriteTicket.receipt(effect) == 3 end)
    wait(fn -> stats(runtime).frames == 0 end)
    assert :ok = Runtime.stop(runtime)
  end

  test "missing binding identity keeps entered liability charged without inventing a receipt" do
    {runtime, socket, call, effect, _deadline} = entered()
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    # Deliberate raw same-VM fault injection removes only the authentic binding
    # row. It does not forge an operation phase, child identity or cleanup proof.
    guardian = Map.fetch!(domain, :pid)
    table = Map.fetch!(domain, :table)
    :ok = :sys.suspend(guardian)
    [{:gate, gate}] = :ets.lookup(table, :gate)
    {:ok, {_domain, _token, binding}} = HTTPWriteTicket.address(effect)
    info = Map.fetch!(gate.bindings, binding)
    :ets.insert(table, {:gate, %{gate | bindings: Map.delete(gate.bindings, binding)}})
    :ok = :sys.resume(guardian)
    Process.sleep(50)
    assert HTTPWriteTicket.receipt(effect) == 0
    assert %{frames: 1, in_flight: 1} = stats(runtime)
    assert Process.alive?(socket)
    :ok = :sys.suspend(guardian)
    [{:gate, gate}] = :ets.lookup(table, :gate)
    :ets.insert(table, {:gate, %{gate | bindings: Map.put(gate.bindings, binding, info)}})
    :ok = :sys.resume(guardian)
    monitor = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^socket, :killed}, 1_000
    assert {:exit, _reason} = Task.await(call, 1_000)
    wait(fn -> HTTPWriteTicket.receipt(effect) == 3 end)
    wait(fn -> stats(runtime).frames == 0 end)
    assert :ok = Runtime.stop(runtime)
  end

  test "wrong or stale claim cannot record a return and a duplicate receipt is immutable" do
    {runtime, socket, call, effect, _deadline} = entered()
    # Deliberate negative controls forge private fields; ordinary consumers use
    # the opaque ticket exclusively. The actual writer executes each probe.
    for forged <- [Map.put(effect, :token, make_ref()), Map.put(effect, :binding, make_ref())] do
      assert {:error, :invalid_http_write_ticket} = probe(socket, forged, :ok)
      assert HTTPWriteTicket.receipt(effect) == 0
    end

    assert {:error, :invalid_http_writer} =
             probe(socket, Map.put(effect, :receipt, :atomics.new(2, [])), :ok)

    assert HTTPWriteTicket.receipt(effect) == 0
    assert :ok = probe(socket, effect, :ok)
    assert :ok = probe(socket, effect, {:error, :duplicate_failure})
    assert HTTPWriteTicket.receipt(effect) == 1
    monitor = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^socket, :killed}, 1_000
    assert {:exit, _reason} = Task.await(call, 1_000)
    wait(fn -> stats(runtime).frames == 0 end)
    assert HTTPWriteTicket.receipt(effect) == 1
    wait(fn -> Runtime.stats!(runtime).reserved == 0 end)
    assert :ok = Runtime.stop(runtime)
  end

  defp entered(opts \\ []) do
    root =
      start_supervised!(
        {Runtime,
         Keyword.merge(
           [
             handler: Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Handler,
             dispatcher: Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Dispatcher,
             handler_args: [observer: self()],
             request_timeout_ms: 5_000,
             output_timeout_ms: 5_000
           ],
           opts
         )}
      )

    {:ok, runtime} = Runtime.ref(root)
    writer = socket(runtime, true)

    call =
      Task.async(fn ->
        try do
          GenServer.call(writer, {:post, request("server/discover", 1)}, 5_000)
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    assert_receive {:admitted, ^writer, "server/discover", token, _, deadline}, 1_000
    assert_receive {:actual_method, "server/discover", _, context}, 1_000
    assert context.token == token
    assert_receive {:entered_effect, ^writer, ^token, effect}, 1_000
    assert HTTPWriteTicket.receipt(effect) == 0
    {runtime, writer, call, effect, deadline}
  end

  defp socket(runtime, hold?) do
    options = [runtime: runtime, observer: self(), hold?: hold?]
    child = {Arbor.MCP.Runtime.HTTPDeadWriterReceiptTest.Socket, options}
    spec = Supervisor.child_spec(child, id: make_ref(), restart: :temporary)
    start_supervised!(spec)
  end

  defp request(method, id),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}}

  defp stats(runtime) do
    {:ok, domain} = HTTPWriterProxy.domain(runtime)
    HTTPWriterRegistry.stats(domain)
  end

  defp probe(socket, ticket, result) do
    nonce = make_ref()
    send(socket, {:probe_return, self(), nonce, ticket, result})
    assert_receive {:probe_reply, ^nonce, reply}, 1_000
    reply
  end

  defp wait(predicate, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 1_000

    if predicate.() do
      :ok
    else
      assert cutoff > System.monotonic_time(:millisecond)
      Process.sleep(5)
      wait(predicate, cutoff)
    end
  end
end
