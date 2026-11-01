defmodule Arbor.MCP.KeycloakFixture do
  @moduledoc false

  alias Arbor.MCP.Authorization.JWT

  @image "quay.io/keycloak/keycloak@sha256:3f3c5f8e03c614774b4bd9173b88391fefa4153bfc010d8012d59ad825377332"

  def start!(resource) do
    docker =
      System.find_executable("docker") || raise "Docker is required for real-provider tests"

    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    name = "arbor-mcp-auth-#{suffix}"
    directory = Path.join(System.tmp_dir!(), name)
    File.mkdir!(directory)
    key = JWT.generate_rsa_key()
    {_type, public_pem} = key |> JWT.to_public_key() |> JOSE.JWK.to_pem()
    [entry] = :public_key.pem_decode(public_pem)
    public_key = :public_key.pem_entry_decode(entry)

    public_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])

    File.write!(
      Path.join(directory, "arbor-mcp-realm.json"),
      Jason.encode!(realm(resource, public_pem))
    )

    try do
      command!(docker, [
        "run",
        "--detach",
        "--rm",
        "--name",
        name,
        "--memory",
        "1g",
        "--cpus",
        "2",
        "--env",
        "JAVA_OPTS_APPEND=-Xms64m -Xmx384m -XX:ActiveProcessorCount=2",
        "--label",
        "arbor.mcp.auth.run=#{System.get_env("GITHUB_RUN_ID", "local-" <> suffix)}",
        "--publish",
        "127.0.0.1::8080",
        "--volume",
        "#{directory}:/opt/keycloak/data/import:ro",
        @image,
        "start-dev",
        "--import-realm",
        "--features=identity-assertion-jwt",
        "--hostname-strict=false"
      ])

      address = command!(docker, ["port", name, "8080/tcp"]) |> String.trim()
      issuer = "http://#{address}/realms/arbor-mcp"
      await_metadata!(issuer, System.monotonic_time(:millisecond) + 120_000)

      %{
        docker: docker,
        name: name,
        directory: directory,
        issuer: issuer,
        key: key,
        resource: resource
      }
    rescue
      error ->
        stop(%{docker: docker, name: name, directory: directory})
        reraise error, __STACKTRACE__
    end
  end

  def stop(ctx) do
    {logs, _status} = System.cmd(ctx.docker, ["logs", ctx.name], stderr_to_stdout: true)
    File.mkdir_p!("tmp/mcp-assurance/provider-logs")
    File.write!("tmp/mcp-assurance/provider-logs/#{ctx.name}.log", logs)
    System.cmd(ctx.docker, ["rm", "--force", ctx.name], stderr_to_stdout: true)
    File.rm_rf!(ctx.directory)
    :ok
  end

  defp realm(resource, public_pem) do
    mapper = %{
      name: "mcp-audience",
      protocol: "openid-connect",
      protocolMapper: "oidc-audience-mapper",
      config: %{
        "included.custom.audience" => resource,
        "access.token.claim" => "true"
      }
    }

    common = %{
      protocol: "openid-connect",
      enabled: true,
      publicClient: false,
      standardFlowEnabled: false,
      serviceAccountsEnabled: true,
      defaultClientScopes: [],
      fullScopeAllowed: false,
      protocolMappers: [
        mapper,
        %{
          mapper
          | name: "introspection-audience",
            config: %{
              "included.client.audience" => "mcp-resource",
              "access.token.claim" => "true"
            }
        }
      ]
    }

    %{
      realm: "arbor-mcp",
      enabled: true,
      sslRequired: "none",
      clients: [
        Map.merge(common, %{
          clientId: "basic-client",
          secret: "fixture-basic-secret",
          clientAuthenticatorType: "client-secret"
        }),
        Map.merge(common, %{
          clientId: "jwt-client",
          clientAuthenticatorType: "client-jwt",
          attributes: %{
            "jwt.credential.public.key" => public_pem,
            "token.endpoint.auth.signing.alg" => "RS256"
          }
        }),
        Map.merge(common, %{
          clientId: "mcp-resource",
          secret: "fixture-resource-secret",
          clientAuthenticatorType: "client-secret"
        })
      ]
    }
  end

  defp await_metadata!(issuer, deadline) do
    result =
      :httpc.request(
        :get,
        {String.to_charlist(issuer <> "/.well-known/openid-configuration"), []},
        [timeout: 1_000, connect_timeout: 1_000],
        body_format: :binary
      )

    case result do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("Keycloak startup timed out")

        # Bounded external service readiness polling, not test/process synchronization.
        receive do: (:keycloak_poll -> :ok), after: (250 -> :ok)
        await_metadata!(issuer, deadline)
    end
  end

  defp command!(docker, args) do
    case System.cmd(docker, args, stderr_to_stdout: true) do
      {output, 0} -> output
      {_output, code} -> raise "Keycloak fixture command failed (#{code})"
    end
  end
end
