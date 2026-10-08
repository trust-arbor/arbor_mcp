defmodule Arbor.MCP.Test.MockTransport do
  @moduledoc """
  Simple mock transport for testing the state machine.
  """

  @behaviour Arbor.MCP.Transport

  defstruct [:server_fn, :state]

  @impl true
  def connect(opts) do
    server_fn = Keyword.get(opts, :server_fn)

    if server_fn do
      {:ok, %__MODULE__{server_fn: server_fn, state: :connected}}
    else
      {:error, :no_server_function}
    end
  end

  @impl true
  def send_message(message, %__MODULE__{server_fn: server_fn} = transport) do
    # Call the server function with the message
    server_fn.({:message, message})
    {:ok, transport}
  end

  @impl true
  def receive_message(%__MODULE__{} = transport) do
    receive do
      {:transport_message, message} ->
        {:ok, message, transport}

      {:transport_error, reason} ->
        {:error, reason}
    after
      5000 ->
        {:error, :timeout}
    end
  end

  @impl true
  def close(%__MODULE__{}) do
    :ok
  end

  @impl true
  def connected?(%__MODULE__{state: :connected}), do: true
  def connected?(_), do: false
end
