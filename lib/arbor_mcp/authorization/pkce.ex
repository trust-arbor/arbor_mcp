defmodule Arbor.MCP.Authorization.PKCE do
  @moduledoc """
  PKCE (Proof Key for Code Exchange) implementation for OAuth 2.1.

  PKCE is required for all authorization code flows in OAuth 2.1 to prevent
  authorization code interception attacks.
  """

  @doc """
  Generates a cryptographically secure code verifier.

  The code verifier is a high-entropy cryptographic random string using
  unreserved characters [A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~"
  with a minimum length of 43 characters and maximum of 128 characters.

  ## Example

      verifier = PKCE.generate_code_verifier()
      # => "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  """
  @spec generate_code_verifier() :: String.t()
  def generate_code_verifier do
    # Generate 32 random bytes (256 bits) for high entropy
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Generates the code challenge from a code verifier using SHA256.

  The code challenge is the base64url encoding of the SHA256 hash of the
  code verifier.

  ## Example

      challenge = PKCE.generate_code_challenge(verifier)
      # => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  """
  @spec generate_code_challenge(String.t()) :: String.t()
  def generate_code_challenge(code_verifier) do
    :crypto.hash(:sha256, code_verifier)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Validates a code verifier against a code challenge.

  This is typically used by the authorization server to verify the PKCE flow.

  ## Example

      PKCE.validate_challenge(verifier, challenge)
      # => true
  """
  @spec validate_challenge(String.t(), String.t()) :: boolean()
  def validate_challenge(code_verifier, code_challenge) do
    expected_challenge = generate_code_challenge(code_verifier)
    secure_compare(expected_challenge, code_challenge)
  end

  @doc """
  Validates that a code verifier meets the RFC 7636 requirements.

  Returns `:ok` if valid, or `{:error, reason}` if invalid.
  """
  @spec validate_verifier(String.t()) :: :ok | {:error, String.t()}
  def validate_verifier(code_verifier) when is_binary(code_verifier) do
    cond do
      byte_size(code_verifier) < 43 ->
        {:error, "Code verifier must be at least 43 characters"}

      byte_size(code_verifier) > 128 ->
        {:error, "Code verifier must not exceed 128 characters"}

      not valid_characters?(code_verifier) ->
        {:error, "Code verifier contains invalid characters"}

      true ->
        :ok
    end
  end

  def validate_verifier(_), do: {:error, "Code verifier must be a string"}

  # Private helpers

  defp valid_characters?(verifier) do
    # Check if all characters are unreserved per RFC 7636
    # [A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~"
    Regex.match?(~r/^[A-Za-z0-9\-._~]+$/, verifier)
  end

  defp secure_compare(a, b) do
    if byte_size(a) == byte_size(b) do
      a_bytes = :binary.bin_to_list(a)
      b_bytes = :binary.bin_to_list(b)

      result =
        Enum.zip(a_bytes, b_bytes)
        |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)

      result == 0
    else
      false
    end
  end
end
