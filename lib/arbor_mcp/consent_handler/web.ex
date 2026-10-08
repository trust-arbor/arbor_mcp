defmodule Arbor.MCP.ConsentHandler.Web do
  @moduledoc """
  A consent handler for web applications.

  This handler indicates that consent must be obtained through a separate
  web flow, rather than being handled synchronously.
  """

  @behaviour Arbor.MCP.ConsentHandler

  # Note: These are placeholder implementations. The web handler defers actual
  # consent logic to the parent web application. The parameters are marked as
  # unused because this module only signals that consent is required from
  # an external process.

  @impl Arbor.MCP.ConsentHandler
  def request_consent(_user_id, _resource_origin, _request_context) do
    {:error, :consent_required}
  end

  @impl Arbor.MCP.ConsentHandler
  def check_existing_consent(_user_id, _resource_origin) do
    # This handler assumes consent is managed by the web application and
    # populated into the ConsentCache out-of-band.
    {:not_found}
  end

  @impl Arbor.MCP.ConsentHandler
  def revoke_consent(_user_id, _resource_origin) do
    :ok
  end
end
