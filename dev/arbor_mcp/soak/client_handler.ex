defmodule Arbor.MCP.Soak.ClientHandler do
  @moduledoc false
  @behaviour Arbor.MCP.Client.Handler

  @impl true
  def init(opts), do: {:ok, Keyword.fetch!(opts, :owner)}

  @impl true
  def handle_ping(owner), do: {:ok, %{}, owner}

  @impl true
  def handle_list_roots(owner), do: {:ok, [], owner}

  @impl true
  def handle_create_message(_params, owner), do: {:error, "not configured", owner}

  @impl true
  def handle_elicitation_create(_message, _schema, owner) do
    send(owner, :soak_elicitation)
    {:ok, %{"action" => "accept", "content" => %{"name" => "soak"}}, owner}
  end

  @impl true
  def handle_progress(request_id, params, owner) do
    send(owner, {:soak_progress, request_id, params})
    {:ok, owner}
  end
end
