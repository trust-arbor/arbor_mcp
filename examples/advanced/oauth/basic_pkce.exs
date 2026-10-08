#!/usr/bin/env elixir

# Offline OAuth 2.1 PKCE helper example.

Mix.install([
  {:arbor_mcp, path: Path.expand("../../..", __DIR__)}
])

alias Arbor.MCP.Authorization
alias Arbor.MCP.Authorization.PKCE

IO.puts("Arbor.MCP OAuth 2.1 PKCE example")
IO.puts(String.duplicate("=", 32))

{:ok, verifier, challenge} = Authorization.generate_pkce_challenge()

IO.puts("Verifier length: #{byte_size(verifier)}")
IO.puts("Challenge length: #{byte_size(challenge)}")
IO.puts("Verifier valid?: #{inspect(PKCE.validate_verifier(verifier))}")

IO.puts(
  "Challenge verifies?: #{inspect(Authorization.verify_pkce_challenge(verifier, challenge))}"
)

authorization_url =
  URI.new!("https://auth.example.com/oauth/authorize")
  |> URI.append_query(
    URI.encode_query(%{
      client_id: "example-mcp-client",
      redirect_uri: "http://localhost:4000/oauth/callback",
      response_type: "code",
      scope: "mcp:read mcp:write",
      code_challenge: challenge,
      code_challenge_method: "S256"
    })
  )
  |> URI.to_string()

IO.puts("\nAuthorization URL:")
IO.puts(authorization_url)
