defmodule Arbor.MCP.Testing.SchemaInstanceProbe do
  @moduledoc false
  defstruct [:observer]
end

defimpl Jason.Encoder, for: Arbor.MCP.Testing.SchemaInstanceProbe do
  def encode(value, opts) do
    send(value.observer, :instance_encoder_invoked)
    Jason.Encode.map(%{}, opts)
  end
end

defimpl Inspect, for: Arbor.MCP.Testing.SchemaInstanceProbe do
  def inspect(value, _opts) do
    send(value.observer, :instance_inspect_invoked)
    "private probe"
  end
end

defimpl Enumerable, for: Arbor.MCP.Testing.SchemaInstanceProbe do
  def count(value) do
    send(value.observer, :instance_enumerable_invoked)
    {:ok, 0}
  end

  def member?(_value, _item), do: {:ok, false}
  def slice(_value), do: {:error, __MODULE__}
  def reduce(_value, {:cont, acc}, _fun), do: {:done, acc}
  def reduce(_value, {:halt, acc}, _fun), do: {:halted, acc}
  def reduce(value, {:suspend, acc}, fun), do: {:suspended, acc, &reduce(value, &1, fun)}
end
