defmodule Arbor.MCP.Internal.Authorization.PKCE do
  @moduledoc """
  This module implements the standard MCP specification.

  PKCE (Proof Key for Code Exchange) implementation for OAuth 2.1.

  PKCE is required by the MCP authorization specification for all
  authorization code flows to prevent authorization code interception attacks.

  This module implements RFC 7636 with S256 code challenge method.

  ## Example

      # Generate code verifier and challenge
      {:ok, verifier, challenge} = Arbor.MCP.Internal.Authorization.PKCE.generate_challenge()

      # Use challenge in authorization request
      # Use verifier in token exchange request

      # Verify a code challenge (server-side)
      :ok = Arbor.MCP.Internal.Authorization.PKCE.verify_challenge(verifier, challenge)
  """

  @doc """
  Generates a code verifier and code challenge for PKCE.

  Returns a cryptographically random code verifier and its SHA256-based
  code challenge suitable for OAuth 2.1 authorization code flow.

  ## Example

      iex> {:ok, verifier, challenge} = Arbor.MCP.Internal.Authorization.PKCE.generate_challenge()
      iex> is_binary(verifier) and is_binary(challenge)
      true
      iex> String.length(verifier) >= 43 and String.length(verifier) <= 128
      true
  """
  @spec generate_challenge() :: {:ok, String.t(), String.t()} | {:error, term()}
  def generate_challenge do
    # Generate cryptographically secure random bytes
    # RFC 7636 recommends 256 bits of entropy (32 bytes)
    code_verifier =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    # Generate code challenge using S256 method
    code_challenge =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    {:ok, code_verifier, code_challenge}
  rescue
    error ->
      {:error, {:pkce_generation_failed, error}}
  end

  @doc """
  Verifies that a code verifier matches the provided code challenge.

  This is used by authorization servers to validate that the client
  presenting the authorization code is the same client that initiated
  the authorization request.

  ## Example

      iex> {:ok, verifier, challenge} = Arbor.MCP.Internal.Authorization.PKCE.generate_challenge()
      iex> Arbor.MCP.Internal.Authorization.PKCE.verify_challenge(verifier, challenge)
      :ok
  """
  @spec verify_challenge(String.t(), String.t()) :: :ok | {:error, :invalid_challenge}
  def verify_challenge(code_verifier, expected_challenge) do
    computed_challenge =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    if computed_challenge == expected_challenge do
      :ok
    else
      {:error, :invalid_challenge}
    end
  rescue
    _error ->
      {:error, :invalid_challenge}
  end

  @doc """
  Validates that a code verifier meets RFC 7636 requirements.

  Code verifiers must be between 43 and 128 characters long and
  contain only unreserved URI characters.

  ## Example

      iex> Arbor.MCP.Internal.Authorization.PKCE.validate_code_verifier("invalid!")
      {:error, :invalid_code_verifier}

      iex> {:ok, verifier, _} = Arbor.MCP.Internal.Authorization.PKCE.generate_challenge()
      iex> Arbor.MCP.Internal.Authorization.PKCE.validate_code_verifier(verifier)
      :ok
  """
  @spec validate_code_verifier(String.t()) :: :ok | {:error, :invalid_code_verifier}
  def validate_code_verifier(code_verifier) when is_binary(code_verifier) do
    length = String.length(code_verifier)

    cond do
      length < 43 or length > 128 ->
        {:error, :invalid_code_verifier}

      not valid_unreserved_chars?(code_verifier) ->
        {:error, :invalid_code_verifier}

      true ->
        :ok
    end
  end

  def validate_code_verifier(_), do: {:error, :invalid_code_verifier}

  # Private functions

  # RFC 7636: code verifier must contain only unreserved URI characters
  # unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"
  defp valid_unreserved_chars?(string) do
    Regex.match?(~r/^[A-Za-z0-9\-._~]+$/, string)
  end
end
