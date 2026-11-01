defmodule Arbor.MCP.Authorization.ClientCredentialsPolicy do
  @moduledoc false

  def only_grant?(%{"grant_types_supported" => grants}) when is_list(grants),
    do: "client_credentials" in grants and "authorization_code" not in grants

  def only_grant?(_metadata), do: false

  def validate_auth(:none, _metadata, _algorithm),
    do: {:error, :client_credentials_requires_authentication}

  def validate_auth(:private_key_jwt, metadata, algorithm) do
    case metadata["token_endpoint_auth_signing_alg_values_supported"] do
      supported when is_list(supported) and supported != [] ->
        if Enum.all?(supported, &is_binary/1) and algorithm in supported,
          do: :ok,
          else: {:error, :client_signing_algorithm_not_supported}

      _other ->
        {:error, :client_signing_algorithm_not_supported}
    end
  end

  def validate_auth(_method, _metadata, _algorithm), do: :ok
end
