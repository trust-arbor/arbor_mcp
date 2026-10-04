defmodule Arbor.MCP.Server.Runtime.HTTPOutput do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{
    HTTPWriterBinding,
    HTTPWriterRegistry,
    OutputLedger,
    OutputTicket
  }

  # Reserve the complete physical frame before the handler proposal can commit.
  # HTTP IO stays unpublished and independently charged until actual IO return.
  def prepare(%{http: %{binding: binding, format: format, owner: owner}} = context, ticket) do
    with {:ok, json} <- OutputLedger.prepared_wire(ticket),
         {:ok, wire} <- frame(json, format, context.group),
         {:ok, {domain, _binding_token}} <- HTTPWriterBinding.address(binding),
         handles = 4 * (:erlang.external_size(domain) + :erlang.external_size(ticket) + 512),
         {:ok, effect} <-
           prepare_io(context, binding, wire,
             owner: owner,
             release_owner: context.owner,
             deadline: context.deadline,
             handle_bytes: handles,
             metadata: %{
               primary: ticket,
               group: context.group,
               format: format,
               notification: Map.get(context.http, :notification, false)
             }
           ) do
      {:ok, OutputTicket.with_http(ticket, effect)}
    end
  end

  def prepare(_context, ticket), do: {:ok, ticket}

  defp prepare_io(%{http: %{terminal: token}}, binding, wire, opts),
    do: HTTPWriterRegistry.prepare_failure(binding, token, wire, opts)

  defp prepare_io(_context, binding, wire, opts),
    do: HTTPWriterRegistry.prepare(binding, wire, opts)

  def handoff(ticket) do
    case OutputTicket.http(ticket) do
      nil -> :ok
      effect -> HTTPWriterRegistry.handoff(effect)
    end
  end

  def valid?(ticket) do
    case OutputTicket.http(ticket) do
      nil -> true
      effect -> HTTPWriterRegistry.prepared?(effect)
    end
  end

  def release(ticket) do
    case OutputTicket.http(ticket) do
      nil -> :ok
      effect -> HTTPWriterRegistry.release(effect)
    end
  end

  def release_all(ticket) do
    release(ticket)
    OutputLedger.release(ticket)
  end

  def publish(ticket) do
    case OutputTicket.http(ticket) do
      nil -> {:error, :missing_http_output_effect}
      effect -> HTTPWriterRegistry.publish(effect)
    end
  end

  def mark_committed(ticket) do
    case OutputTicket.http(ticket) do
      nil -> :ok
      effect -> HTTPWriterRegistry.commit_member(effect, ticket)
    end
  end

  def finish_group(binding, primary) do
    with {:ok, effect} <- HTTPWriterRegistry.finish_group(binding, primary),
         do: {:ok, OutputTicket.with_http(primary, effect)}
  end

  defp frame(json, _format, true), do: {:ok, json}
  defp frame(json, format, false), do: frame(json, format)

  defp frame(json, :json), do: {:ok, json}
  defp frame(json, :sse), do: {:ok, "data: " <> json <> "\r\n\r\n"}
  defp frame(_json, _format), do: {:error, :invalid_http_output_format}
end
