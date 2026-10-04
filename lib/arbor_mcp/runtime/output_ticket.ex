defmodule Arbor.MCP.Server.Runtime.OutputTicket do
  @moduledoc false
  @enforce_keys [:ledger, :table, :generation, :token, :scope]
  defstruct [:ledger, :table, :generation, :token, :scope]

  @opaque t :: %__MODULE__{
            ledger: pid(),
            table: :ets.tid(),
            generation: reference(),
            token: reference(),
            scope: term()
          }
end
