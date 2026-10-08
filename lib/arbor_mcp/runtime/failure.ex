defmodule Arbor.MCP.Server.Runtime.Failure do
  @moduledoc false

  def result(_reservation, reason) when reason in [:runtime_restarted, :runtime_stopped],
    do: {:error, reason}

  def result(%{kind: kind}, reason)
      when kind in [:ingress, :edge_control, :edge_response, :call, :cast],
      do: {:error, reason}

  def result(%{request_id: nil}, _reason), do: :notification

  def result(reservation, reason) do
    {:error,
     %{
       "jsonrpc" => "2.0",
       "id" => reservation.request_id,
       "error" => %{
         "code" => if(reason == :request_cancelled, do: -32001, else: -32603),
         "message" => message(reason),
         "data" => %{"type" => Atom.to_string(reason)}
       }
     }}
  end

  defp message(:request_cancelled), do: "Request cancelled"
  defp message(:handler_timeout), do: "Request timeout"
  defp message(_reason), do: "Internal server error"
end
