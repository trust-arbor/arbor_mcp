defmodule Arbor.MCP.ConsentHandler.CLI do
  @moduledoc """
  A consent handler that prompts the user for consent via the command line.
  Suitable for interactive `stdio` transport sessions.
  """

  @behaviour Arbor.MCP.ConsentHandler

  @impl Arbor.MCP.ConsentHandler
  def request_consent(user_id, resource_origin, request_context) do
    # Default TTL is 1 hour in seconds
    default_ttl_seconds = 3600
    ttl = Map.get(request_context, :consent_ttl, default_ttl_seconds)

    IO.puts("User '#{user_id}' is requesting access to an external resource: #{resource_origin}")

    case IO.gets("Allow access? (y/n) ") do
      "y\n" ->
        # Relative TTL: unambiguous, unlike a bare integer (see
        # `t:Arbor.MCP.ConsentHandler.expiry/0`).
        {:ok, {:ttl, ttl}}

      _ ->
        {:error, :denied}
    end
  end

  @impl Arbor.MCP.ConsentHandler
  def check_existing_consent(_user_id, _resource_origin) do
    # This handler is interactive and does not persist consent itself.
    # It relies on the ConsentCache.
    {:not_found}
  end

  @impl Arbor.MCP.ConsentHandler
  def revoke_consent(_user_id, _resource_origin) do
    # Consent is managed in the cache, so we just acknowledge.
    :ok
  end
end
