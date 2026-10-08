defmodule Arbor.MCP.Client.EraCacheTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.EraCache
  alias Arbor.MCP.Transport.HTTP

  test "legacy observations expire while modern observations remain pinned" do
    legacy_identity = EraCache.identity(__MODULE__, nil, era_cache_key: make_ref())
    modern_identity = EraCache.identity(__MODULE__, nil, era_cache_key: make_ref())

    assert :ok =
             EraCache.observe(legacy_identity, :legacy, "2025-11-25", era_cache_legacy_ttl: 0)

    assert EraCache.lookup(legacy_identity) == :miss

    assert :ok = EraCache.observe(modern_identity, :modern, "2026-07-28")
    assert :ok = EraCache.observe(modern_identity, :legacy, "2025-11-25")

    assert {:ok, observation} = EraCache.lookup(modern_identity)
    assert observation.era == :modern
    assert observation.protocol_version == "2026-07-28"
    assert observation.expires_at == :infinity

    assert :ok = EraCache.clear(modern_identity)
    assert EraCache.lookup(modern_identity) == :miss
  end

  test "HTTP identities include the canonical endpoint and auth configuration" do
    base = http_state("https://EXAMPLE.com:443", "/mcp/", [{"Authorization", "Bearer one"}])
    equivalent = http_state("https://example.com", "mcp", [{"authorization", "Bearer one"}])
    different_path = http_state("https://example.com", "/other", base.headers)
    different_auth = http_state("https://example.com", "/mcp", [{"Authorization", "Bearer two"}])

    assert EraCache.identity(HTTP, base, []) == EraCache.identity(HTTP, equivalent, [])
    refute EraCache.identity(HTTP, base, []) == EraCache.identity(HTTP, different_path, [])
    refute EraCache.identity(HTTP, base, []) == EraCache.identity(HTTP, different_auth, [])

    # The custom-transport test hook cannot collapse built-in HTTP paths.
    refute EraCache.identity(HTTP, base, era_cache_key: :same) ==
             EraCache.identity(HTTP, different_path, era_cache_key: :same)

    refute EraCache.identity(HTTP, base, auth_provider: {__MODULE__, tenant: 1}) ==
             EraCache.identity(HTTP, base, auth_provider: {__MODULE__, tenant: 2})
  end

  defp http_state(base_url, endpoint, headers) do
    %HTTP{
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      http_client: :httpc,
      security: nil,
      origin: "https://example.com",
      auth_config: nil,
      auth_provider: nil
    }
  end
end
