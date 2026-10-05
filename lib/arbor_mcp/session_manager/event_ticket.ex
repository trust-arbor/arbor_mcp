defmodule Arbor.MCP.SessionManager.EventTicket do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{ServiceRef, Services}

  @enforce_keys [:service, :generation, :token, :version, :receipt, :deadline]
  defstruct [:service, :generation, :token, :version, :receipt, :deadline]

  @opaque t :: %__MODULE__{
            service: ServiceRef.t(),
            generation: reference(),
            token: reference(),
            version: reference(),
            receipt: :atomics.atomics_ref(),
            deadline: integer()
          }

  @spec new(
          ServiceRef.t(),
          reference(),
          reference(),
          reference(),
          :atomics.atomics_ref(),
          integer()
        ) :: t()
  def new(service, generation, token, version, receipt, deadline),
    do: %__MODULE__{
      service: service,
      generation: generation,
      token: token,
      version: version,
      receipt: receipt,
      deadline: deadline
    }

  @spec address(t()) :: {:ok, ServiceRef.t(), reference(), reference()} | {:error, atom()}
  def address(%__MODULE__{} = ticket) do
    with {:ok, binding} <- Services.resolve(ticket.service, :sessions),
         true <- binding.generation == ticket.generation,
         true <- is_reference(ticket.token) and is_reference(ticket.version),
         do: {:ok, ticket.service, ticket.token, ticket.version},
         else: (_retired -> {:error, :session_event_retired})
  end

  def address(_invalid), do: {:error, :invalid_session_event_ticket}

  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{} = ticket, entry),
    do:
      ticket.token == entry.token and ticket.version == entry.version and
        ticket.receipt == entry.receipt and ticket.generation == entry.service_generation and
        ticket.deadline == entry.source.deadline

  def matches?(_ticket, _entry), do: false

  @spec deadline(t()) :: integer()
  def deadline(%__MODULE__{deadline: deadline}), do: deadline

  # Receipt is independent of a service table's lifetime. A store that dies
  # after entering durability cannot manufacture a successful publication.
  @spec receipt(t()) :: 0 | 1 | 2 | 3
  def receipt(%__MODULE__{receipt: receipt}), do: :atomics.get(receipt, 1)
end
