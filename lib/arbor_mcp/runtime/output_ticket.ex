defmodule Arbor.MCP.Server.Runtime.OutputTicket do
  @moduledoc false
  @enforce_keys [:ledger, :table, :generation, :token, :scope]
  defstruct [:ledger, :table, :generation, :token, :scope]
  @scope_limit 4_096

  @opaque t :: %__MODULE__{
            ledger: pid(),
            table: :ets.tid(),
            generation: reference(),
            token: reference(),
            scope: term()
          }

  @type error :: {:error, atom()}

  @spec new(pid(), :ets.tid(), reference(), reference(), term()) :: t()
  def new(ledger, table, generation, token, scope) do
    %__MODULE__{ledger: ledger, table: table, generation: generation, token: token, scope: scope}
  end

  @spec address(t()) :: {:ok, {pid(), reference()}} | error()
  def address(%__MODULE__{} = ticket) do
    with :ok <- validate_scope_value(ticket.scope),
         true <- is_reference(ticket.token) || {:error, :invalid_output_ticket},
         do: {:ok, {ticket.ledger, ticket.token}}
  end

  def address(_invalid), do: {:error, :invalid_output_ticket}

  @spec validate_ledger(t(), pid(), :ets.tid(), reference()) :: :ok | error()
  def validate_ledger(%__MODULE__{} = ticket, ledger, table, generation) do
    if ticket.ledger == ledger and ticket.table == table and ticket.generation == generation,
      do: :ok,
      else: {:error, :output_unavailable}
  end

  @spec validate_scope(t(), term()) :: :ok | error()
  def validate_scope(%__MODULE__{} = ticket, scope) do
    if ticket.scope == scope, do: :ok, else: {:error, :invalid_output_ticket}
  end

  @spec validate_scope_value(term()) :: :ok | error()
  def validate_scope_value(scope) do
    if :erlang.external_size(scope) <= @scope_limit,
      do: :ok,
      else: {:error, :invalid_output_scope}
  end
end
