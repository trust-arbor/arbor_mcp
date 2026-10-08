defmodule Arbor.MCP.Server.SubscriptionOriginTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.{HandlerServer, Runtime}
  alias Arbor.MCP.Server.Runtime.{Admission, CallbackContext, Deadline}
  alias Arbor.MCP.Server.Subscriptions.Origin
  alias Arbor.MCP.Transport.Test

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, opts[:test_pid]}

    @impl true
    def handle_call_tool("capture", _arguments, test_pid) do
      context = CallbackContext.current()
      {:ok, origin} = Origin.capture([])
      send(test_pid, {:source_captured, self(), context, origin})
      receive do: (:complete -> :ok)
      {:ok, %{"content" => []}, test_pid}
    end
  end

  defp source do
    root =
      start_supervised!(
        Supervisor.child_spec(
          {HandlerServer,
           transport: :test,
           handler: Handler,
           handler_args: [test_pid: self()],
           request_timeout_ms: 1_000},
          id: make_ref(),
          restart: :temporary
        )
      )

    {:ok, transport} = Test.connect(server: root)
    capture(root, transport)
  end

  defp capture(root, transport, id \\ 1) do
    assert {:ok, _transport} = Test.send_message(tool(id), transport)
    assert_receive {:source_captured, worker, context, origin}, 1_000
    assert {:ok, %{output_phase: phase}} = Admission.current(context.table, context.token)
    assert :atomics.get(phase, 1) == 1

    {Map.merge(context, %{root: root, transport: transport, worker: worker, wire_id: id}), origin,
     phase}
  end

  defp tool(id),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "capture", "arguments" => %{}}
    }

  defp complete(context, phase) do
    send(context.worker, :complete)
    assert_receive {:transport_message, encoded}, 1_000
    assert %{"id" => id, "result" => %{"content" => []}} = Jason.decode!(encoded)
    assert id == context.wire_id
    assert :atomics.get(phase, 1) == 2

    eventually(fn ->
      Admission.current(context.table, context.token) == {:error, :admission_lost}
    end)
  end

  test "active cancellation revokes the captured original cell" do
    {context, origin, _phase} = source()
    assert Origin.valid?(origin)
    assert :ok = Runtime.cancel(context.runtime, context.scope, 1)
    eventually(fn -> not Origin.valid?(origin) end)
  end

  test "completed success survives retired rows, rejected duplicate IDs and unrelated cancellation" do
    {context, origin, phase} = source()
    complete(context, phase)
    assert Origin.valid?(origin)
    assert {:ok, _transport} = Test.send_message(tool(1), context.transport)
    assert_receive {:transport_message, duplicate}, 1_000

    assert %{"id" => 1, "error" => %{"data" => %{"type" => "duplicate_request_id"}}} =
             Jason.decode!(duplicate)

    {replacement, replacement_origin, _phase} = capture(context.root, context.transport, 2)
    refute replacement.token == context.token
    assert :ok = Runtime.cancel(replacement.runtime, replacement.scope, 2)
    eventually(fn -> not Origin.valid?(replacement_origin) end)
    assert Origin.valid?(origin)
    assert :ok = Runtime.cancel(context.runtime, context.scope, 1)
    refute :ets.member(context.table, {:cancelled, context.token})
    assert Origin.valid?(origin)
  end

  test "peer replacement independently retires a completed origin" do
    {context, origin, phase} = source()
    complete(context, phase)
    assert {:ok, _replacement} = Test.connect(server: context.root)
    refute Origin.valid?(origin)
  end

  test "execution generation replacement retires both active and completed origins" do
    for completion <- [:active, :completed] do
      {context, origin, phase} = source()
      if completion == :completed, do: complete(context, phase)
      assert {:ok, route} = Admission.route(context.table)
      Process.exit(route.scheduler, :kill)

      eventually(fn ->
        case Admission.route(context.table) do
          {:ok, %{generation: generation}} -> generation != context.generation
          _unavailable -> false
        end
      end)

      refute Origin.valid?(origin)
    end
  end

  test "an original source cutoff cannot be renewed by publication or terminal helpers" do
    {_context, origin, _phase} = source()
    later = Deadline.after_ms(10_000)
    assert Origin.limit(origin, later).deadline == origin.deadline
    assert Origin.deadline(origin, later) == origin.deadline
    assert {:error, :invalid_subscription_origin} = Origin.terminal(origin, later)
    refute Origin.valid?(Origin.limit(origin, Deadline.after_ms(0)))
  end

  test "a public option cannot forge edge-owned control authority" do
    {context, origin, _phase} = source()

    assert {:error, :invalid_subscription_origin} =
             Origin.capture(
               subscription_control: {context.table, context.token, origin.connection}
             )

    assert {:ok, nil} = Origin.capture(subscription_origin: origin)
    assert {:error, :invalid_subscription_origin} = Origin.capture(subscription_control: origin)
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
