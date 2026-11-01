defmodule Arbor.MCP.AuthExtensionFixture do
  @moduledoc false

  def config(opts \\ []) do
    idp = Bypass.open()
    as = Bypass.open()
    idp_origin = "http://localhost:#{idp.port}"
    as_origin = "http://localhost:#{as.port}"
    parent = self()

    for {peer, leg} <- [{idp, :idp}, {as, :as}] do
      Bypass.stub(peer, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        send(parent, {leg, Plug.Conn.get_req_header(conn, "authorization"), params})

        response =
          cond do
            leg == :as ->
              %{"access_token" => "resource-token", "token_type" => "Bearer"}

            params["subject_token_type"] == "urn:ietf:params:oauth:token-type:saml2" ->
              %{
                "access_token" => "refresh-from-saml",
                "token_type" => Keyword.get(opts, :idp_token_type, "N_A"),
                "issued_token_type" =>
                  Keyword.get(
                    opts,
                    :saml_issued_type,
                    "urn:ietf:params:oauth:token-type:refresh_token"
                  )
              }

            true ->
              %{
                "access_token" => "id-jag",
                "token_type" => Keyword.get(opts, :idp_token_type, "N_A"),
                "issued_token_type" =>
                  Keyword.get(opts, :idp_issued_type, "urn:ietf:params:oauth:token-type:id-jag")
              }
          end

        response =
          if leg == :idp and opts[:idp_token_type] == :omitted,
            do: Map.delete(response, "token_type"),
            else: response

        response =
          if leg == :idp and opts[:idp_issued_type] == :omitted,
            do: Map.delete(response, "issued_token_type"),
            else: response

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)
    end

    metadata = fn uri, _address, _options ->
      {issuer, origin} =
        if uri.host == "idp-contract.example",
          do: {"https://idp-contract.example", idp_origin},
          else: {"https://as-contract.example", as_origin}

      data =
        if uri.host == "mcp-contract.example" do
          %{
            "resource" => "https://mcp-contract.example/mcp",
            "authorization_servers" => ["https://as-contract.example"]
          }
        else
          %{
            "issuer" => issuer,
            "authorization_endpoint" => origin <> "/authorize",
            "token_endpoint" => origin <> "/token",
            "grant_types_supported" =>
              Keyword.get(opts, :grants, ["urn:ietf:params:oauth:grant-type:jwt-bearer"]),
            "authorization_grant_profiles_supported" =>
              Keyword.get(opts, :profiles, ["urn:ietf:params:oauth:grant-profile:id-jag"]),
            "token_endpoint_auth_methods_supported" =>
              Keyword.get(opts, :methods, [
                "client_secret_basic",
                "client_secret_post",
                "private_key_jwt"
              ]),
            "token_endpoint_auth_signing_alg_values_supported" => ["ES256"]
          }
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(data)}}
    end

    %{
      resource_url: "https://mcp-contract.example/mcp",
      as_issuer: "https://as-contract.example",
      as_token_endpoint: as_origin <> "/token",
      idp_token_endpoint: idp_origin <> "/token",
      id_token: "id-token",
      idp_id_token: "id-token",
      client_id: "as-client",
      credential_issuer: "https://as-contract.example",
      idp_auth: %{
        issuer: "https://idp-contract.example",
        client_id: "idp-client",
        auth_method: :client_secret_basic,
        client_secret: "fake-idp-secret"
      },
      metadata_fetch: [
        http_client: metadata,
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        allowed_endpoint_origins: [idp_origin, as_origin],
        allow_insecure_loopback: true
      ]
    }
  end
end
