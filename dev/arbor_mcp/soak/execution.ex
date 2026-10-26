defmodule Arbor.MCP.Soak.Execution do
  @moduledoc false

  def protected(fun, scenario) do
    case fun.() do
      {:scenario_update, result, updated} -> {result, updated}
      result -> {result, scenario}
    end
  rescue
    error -> {{:error, {:exception, Exception.format(:error, error, __STACKTRACE__)}}, scenario}
  catch
    kind, reason -> {{:error, {kind, reason}}, scenario}
  end
end
