defmodule Arbor.MCP.Authorization.EnterpriseSubject do
  @moduledoc false

  alias Arbor.MCP.Authorization.{HTTPClient, IdPAuthentication, TokenExchange}

  @types %{
    id_token: "urn:ietf:params:oauth:token-type:id_token",
    refresh_token: "urn:ietf:params:oauth:token-type:refresh_token",
    saml2: "urn:ietf:params:oauth:token-type:saml2"
  }

  def exchange(config, legacy_key, audience, legacy_client_id) do
    with {:ok, subject} <- subject(config, legacy_key),
         {:ok, subject} <- transition(subject, config) do
      body =
        [
          {"grant_type", TokenExchange.grant_type()},
          {"subject_token", subject.token},
          {"subject_token_type", @types[subject.type]},
          {"requested_token_type", TokenExchange.token_type_id_jag()},
          {"audience", audience},
          {"resource", config[:resource] || config[:resource_url]},
          {"scope", config[:scope]},
          {"client_id", legacy_client_id}
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      with {:ok, result} <- request(body, config),
           "urn:ietf:params:oauth:token-type:id-jag" <- result[:issued_token_type],
           "N_A" <- result[:token_type],
           token when is_binary(token) and byte_size(token) > 0 <- result[:access_token] do
        {:ok, result}
      else
        {:error, _reason} = error -> error
        _invalid -> {:error, :invalid_id_jag_exchange_response}
      end
    end
  end

  defp subject(%{idp_subject: %{type: type, token: token} = subject} = config, legacy_key)
       when is_map_key(@types, type) and is_binary(token) and byte_size(token) > 0 do
    if Map.keys(subject) -- [:type, :token] == [] and String.valid?(token) and
         (is_nil(config[legacy_key]) or
            (type == :id_token and config[legacy_key] == token)),
       do: {:ok, subject},
       else: {:error, :conflicting_idp_subject}
  end

  defp subject(%{idp_subject: subject}, _key) when not is_nil(subject),
    do: {:error, :invalid_idp_subject}

  defp subject(config, key) do
    case config[key] do
      token when is_binary(token) and byte_size(token) > 0 ->
        {:ok, %{type: :id_token, token: token}}

      _other ->
        {:error, :missing_idp_subject}
    end
  end

  defp transition(%{type: :saml2} = subject, %{idp_auth: auth} = config) when not is_nil(auth) do
    body = [
      {"grant_type", TokenExchange.grant_type()},
      {"subject_token", subject.token},
      {"subject_token_type", @types.saml2},
      {"requested_token_type", @types.refresh_token},
      {"scope", "openid offline_access"}
    ]

    with {:ok, result} <- request(body, config),
         token when is_binary(token) and byte_size(token) > 0 <- result[:access_token],
         "urn:ietf:params:oauth:token-type:refresh_token" <- result[:issued_token_type],
         "N_A" <- result[:token_type] do
      {:ok, %{type: :refresh_token, token: token}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_saml_exchange_response}
    end
  end

  defp transition(%{type: :saml2}, _config), do: {:error, :saml_exchange_requires_idp_auth}
  defp transition(subject, _config), do: {:ok, subject}

  defp request(body, %{idp_auth: auth} = config) when not is_nil(auth),
    do: IdPAuthentication.exchange(body, config)

  defp request(body, config),
    do: HTTPClient.make_token_request(config[:idp_token_endpoint], body, auth_method: :none)
end
