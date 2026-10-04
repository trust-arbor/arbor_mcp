defmodule Arbor.MCP.Server.SubscriptionOriginTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Runtime.{CallbackContext, Deadline}
  alias Arbor.MCP.Server.Subscriptions.Origin

  defp source do
    table = :ets.new(__MODULE__, [:set, :public])
    token = make_ref()
    generation = make_ref()
    connection = make_ref()
    scope = make_ref()
    phase = :atomics.new(1, signed: false)
    :atomics.put(phase, 1, 1)
    deadline = Deadline.after_ms(1_000)
    context = %{table: table, token: token, generation: generation, scope: scope}
    reservation = Map.merge(context, %{terminal: false, output_phase: phase, deadline: deadline})
    :ets.insert(table, {:route, %{scheduler: self(), generation: generation}})
    :ets.insert(table, {:edge_connection, self(), connection})
    :ets.insert(table, {{:reservation, token}, reservation})
    {:ok, origin} = CallbackContext.with_context(context, fn -> Origin.capture([]) end)
    {context, origin, phase}
  end

  test "active cancellation revokes the captured original cell" do
    {context, origin, _phase} = source()
    assert Origin.valid?(origin)
    :ets.insert(context.table, {{:cancelled, context.token}, :client_cancelled})
    refute Origin.valid?(origin)
  end

  test "completed success survives row retirement and reused IDs without a tombstone" do
    {context, origin, phase} = source()
    :atomics.put(phase, 1, 2)
    :ets.delete(context.table, {:reservation, context.token})
    assert Origin.valid?(origin)
    replacement_phase = :atomics.new(1, signed: false)
    :atomics.put(replacement_phase, 1, 3)

    :ets.insert(
      context.table,
      {{:reservation, context.token}, %{output_phase: replacement_phase}}
    )

    :ets.insert(context.table, {{:cancelled, context.token}, :new_invocation})
    assert Origin.valid?(origin)
  end

  test "peer replacement independently retires a completed origin" do
    {context, origin, phase} = source()
    :atomics.put(phase, 1, 2)
    :ets.insert(context.table, {:edge_connection, self(), make_ref()})
    refute Origin.valid?(origin)
  end

  test "execution generation replacement retires both active and completed origins" do
    {context, origin, phase} = source()
    :atomics.put(phase, 1, 2)
    :ets.insert(context.table, {:route, %{scheduler: self(), generation: make_ref()}})
    refute Origin.valid?(origin)
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
end
