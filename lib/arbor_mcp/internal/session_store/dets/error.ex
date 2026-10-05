defmodule Arbor.MCP.Internal.SessionStore.DETS.Error do
  @moduledoc false
  defexception [:operation, :reason]

  @impl true
  def message(_error), do: "DETS operation failed; physical effects may be unresolved"
end
