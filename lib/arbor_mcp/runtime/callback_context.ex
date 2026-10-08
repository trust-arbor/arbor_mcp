defmodule Arbor.MCP.Server.Runtime.CallbackContext do
  @moduledoc false

  @key {Arbor.MCP.Server.Runtime, :invocation}

  def current, do: Process.get(@key)

  def cancelled? do
    case current() do
      %{table: table, token: token} ->
        :ets.member(table, {:cancelled, token})

      nil ->
        false
    end
  rescue
    ArgumentError -> true
  end

  def with_context(context, fun) do
    previous = Process.put(@key, context)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end
end
