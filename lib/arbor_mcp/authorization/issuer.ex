defmodule Arbor.MCP.Authorization.Issuer do
  @moduledoc """
  Exact authorization-server issuer comparison.

  OAuth issuer identifiers are compared as identifiers, not as URLs to be
  normalized. In particular, ArborMCP does not add or remove trailing slashes,
  rewrite paths, fold case, or otherwise canonicalize issuer values before
  comparing them.
  """

  @type mismatch ::
          :missing_expected_issuer
          | :missing_authorization_server_issuer
          | {:issuer_mismatch, keyword(String.t())}

  @doc "Compares two issuer identifiers byte-for-byte."
  @spec compare(String.t() | nil, String.t() | nil) :: :ok | {:error, mismatch()}
  def compare(nil, _actual), do: {:error, :missing_expected_issuer}
  def compare(_expected, nil), do: {:error, :missing_authorization_server_issuer}
  def compare(issuer, issuer) when is_binary(issuer) and issuer != "", do: :ok

  def compare(expected, actual) when is_binary(expected) and is_binary(actual) do
    {:error, {:issuer_mismatch, expected: expected, actual: actual}}
  end

  def compare(_expected, _actual), do: {:error, :invalid_authorization_server_issuer}
end
