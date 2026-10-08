defmodule Arbor.MCP.Internal.SessionStore.Factory do
  @moduledoc false

  # Selects and opens the concrete session-store backend for a SessionManager
  # configuration. Kept apart from the `Arbor.MCP.Internal.SessionStore` behaviour
  # so the behaviour never references the implementations that adopt it.

  alias Arbor.MCP.Internal.SessionStore

  @spec open(map()) :: {:ok, SessionStore.t()} | {:error, term()}
  def open(%{storage_backend: :dets} = config) do
    SessionStore.DETS.open(config)
  end

  def open(config) do
    SessionStore.ETS.open(config)
  end
end
