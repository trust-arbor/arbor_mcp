defmodule Arbor.MCP.Authorization.Provider.Static do
  @moduledoc """
  Static token provider for pre-existing bearer tokens.

  Use this when you already have a token and don't need OAuth discovery or refresh.

  ## Configuration

      {Arbor.MCP.Authorization.Provider.Static, token: "sk-my-api-key"}
  """

  @behaviour Arbor.MCP.Authorization.Provider

  defstruct [:token]

  @impl true
  def init(config) do
    config = if is_list(config), do: Map.new(config), else: config
    {:ok, %__MODULE__{token: config[:token]}}
  end

  @impl true
  def get_token(%__MODULE__{token: token} = state) do
    {:ok, token, state}
  end

  @impl true
  def handle_unauthorized(_www_authenticate, _scopes, state) do
    {:error, :unauthorized, state}
  end

  @impl true
  def handle_forbidden(_www_authenticate, _scopes, state) do
    {:error, :forbidden, state}
  end
end
