defmodule Arbor.MCP.ConsentHandler.Deny do
  @moduledoc """
  A consent handler that denies all requests for external resource access.
  This is the default, production-safe handler.
  """

  @behaviour Arbor.MCP.ConsentHandler

  @impl Arbor.MCP.ConsentHandler
  def request_consent(_user_id, _resource_origin, _request_context) do
    {:error, :denied}
  end

  @impl Arbor.MCP.ConsentHandler
  def check_existing_consent(_user_id, _resource_origin) do
    {:not_found}
  end

  @impl Arbor.MCP.ConsentHandler
  def revoke_consent(_user_id, _resource_origin) do
    :ok
  end
end
