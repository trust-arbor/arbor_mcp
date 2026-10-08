defmodule Arbor.MCP.SessionManager.RuntimeEvents do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{
    HTTPWriterRegistry,
    OutputLedger,
    OutputTicket,
    ServiceOperation
  }

  alias Arbor.MCP.SessionManager.{EventTicket, SessionLease}

  def prepare(context, primary) do
    with %{session: %{service: service, lease: lease}, binding: binding, source: source} <-
           context.http,
         {:ok, origin} <- HTTPWriterRegistry.event_source(binding, source, primary),
         {:ok, key} <- SessionLease.validate(lease, service, :sessions),
         {:ok, wire} <- OutputLedger.prepared_wire(primary),
         {:ok, ticket} <-
           call(service, :prepare_event, [key, origin, wire, context.group], origin.deadline),
         do: {:ok, OutputTicket.with_session(primary, ticket)}
  end

  def valid?(primary) do
    case OutputTicket.session(primary) do
      nil -> true
      ticket -> operate_ticket(ticket, :event_current) == true
    end
  end

  def handoff(primary), do: operate(primary, :handoff_event)
  def release(primary), do: operate(primary, :release_event)

  def finalize(primary, member) do
    with event when not is_nil(event) <- OutputTicket.session(member),
         {:ok, service, token, _version} <- EventTicket.address(event),
         {:ok, final} <-
           call(service, :finalize_event, [token, primary], EventTicket.deadline(event)),
         do: {:ok, OutputTicket.with_session(primary, final)},
         else: (error -> normalize(error))
  end

  def publish(primary) do
    case OutputTicket.session(primary) do
      nil -> {:error, :invalid_session_event_ticket}
      event -> publish_ticket(event, primary)
    end
  end

  defp publish_ticket(event, primary) do
    result =
      case EventTicket.address(event) do
        {:ok, service, _token, _version} ->
          call(service, :publish_event, [event, primary], EventTicket.deadline(event))

        error ->
          normalize(error)
      end

    case {result, EventTicket.receipt(event)} do
      {{:ok, _event}, 1} -> :ok
      {_, 3} -> {:error, :session_event_durability_unconfirmed}
      {{:error, reason}, _} -> {:error, reason}
      _ -> {:error, :session_event_durability_unconfirmed}
    end
  end

  defp operate(primary, operation) do
    case OutputTicket.session(primary) do
      nil -> :ok
      ticket -> operate_ticket(ticket, operation)
    end
  end

  defp operate_ticket(ticket, operation) do
    if operation == :release_event and EventTicket.receipt(ticket) == 3 do
      {:error, :session_event_durability_unconfirmed}
    else
      with {:ok, service, _token, _version} <- EventTicket.address(ticket),
           do: call(service, operation, [ticket], EventTicket.deadline(ticket))
    end
  end

  defp call(service, operation, args, deadline),
    do: ServiceOperation.call(service, :sessions, operation, args, deadline: deadline)

  defp normalize({:error, _reason} = error), do: error
  defp normalize(_invalid), do: {:error, :invalid_session_event_ticket}
end
