defmodule Arbor.MCP.Authorization.ResourceASAuthentication do
  @moduledoc false

  alias Arbor.MCP.Authorization.{HTTPClient, IdPAuthentication, Issuer, RegistrationPolicy}

  def client_info(metadata, config) do
    with {:ok, auth} <- IdPAuthentication.validate_config(config[:as_auth]),
         :ok <- Issuer.compare(auth.issuer, metadata["issuer"]),
         :ok <- match_config(config, :as_issuer, auth.issuer),
         :ok <- match_config(config, :credential_issuer, auth.issuer),
         :ok <- match_config(config, :client_id, auth.client_id),
         :ok <- match_config(config, :as_token_endpoint, metadata["token_endpoint"]),
         {:ok, method} <- match_registration(config[:client_registration], auth, metadata, config) do
      {:ok, %{client_id: auth.client_id, issuer: auth.issuer, registration_method: method}}
    end
  end

  def exchange(body, metadata, config) do
    with {:ok, _info} <- client_info(metadata, config) do
      # Construct a fresh configuration: no IdP credentials or endpoint aliases
      # can be reused at the resource authorization server.
      request =
        config
        |> Map.take([:http_client, :metadata_fetch, :oauth_http])
        |> Map.put(:idp_auth, config.as_auth)
        |> Map.put(:idp_token_endpoint, metadata["token_endpoint"])
        |> Map.put(:client_assertion_audience, metadata["issuer"])

      case IdPAuthentication.exchange(body, request, &HTTPClient.make_mcp_token_request/3) do
        {:ok, token} -> {:ok, token}
        {:error, reason} -> {:error, {:as_auth_failed, reason}}
      end
    end
  end

  defp match_registration(nil, _auth, _metadata, _config), do: {:ok, :pre_registered}
  defp match_registration(:auto, _auth, _metadata, _config), do: {:ok, :pre_registered}

  defp match_registration(
         {:pre_registered, client_id, nil},
         %{client_id: client_id},
         _metadata,
         _config
       ) do
    {:ok, :pre_registered}
  end

  defp match_registration(
         {:cimd, client_id},
         %{
           client_id: client_id,
           auth_method: :private_key_jwt
         },
         metadata,
         config
       ) do
    with {:ok, {:cimd, _selection}} <- RegistrationPolicy.select(metadata, config),
         do: {:ok, :cimd}
  end

  defp match_registration(_registration, _auth, _metadata, _config),
    do: {:error, :as_auth_registration_conflict}

  defp match_config(config, field, expected) do
    case config[field] do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, {:as_auth_config_mismatch, field}}
    end
  end
end
