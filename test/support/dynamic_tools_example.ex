defmodule Arbor.MCP.Test.DynamicToolsExample do
  @moduledoc false
  @example Path.expand("../../examples/dynamic_tools.exs", __DIR__)

  def ensure_loaded do
    unless Code.ensure_loaded?(Arbor.MCP.Examples.DynamicTools), do: Code.require_file(@example)
    :ok
  end
end
