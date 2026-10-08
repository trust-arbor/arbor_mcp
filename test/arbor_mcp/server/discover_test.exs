defmodule Arbor.MCP.Server.DiscoverTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Discover

  test "builds discovery data from the explicitly enabled protocol mode" do
    result =
      Discover.build(
        %{"name" => "weather", "version" => "1.0.0"},
        %{"tools" => %{}},
        protocol_mode: :modern_only,
        ttl_ms: 0,
        cache_scope: :private,
        instructions: "Call tools deliberately"
      )

    assert result["supportedVersions"] == ["2026-07-28"]
    assert result["capabilities"] == %{"tools" => %{}}
    assert result["ttlMs"] == 0
    assert result["cacheScope"] == "private"
    assert result["instructions"] == "Call tools deliberately"

    assert result["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
             "name" => "weather",
             "version" => "1.0.0"
           }
  end

  test "keeps modern support out of legacy-only discovery data" do
    result = Discover.build(%{}, %{}, protocol_mode: :legacy_only)

    refute "2026-07-28" in result["supportedVersions"]
    assert "2025-11-25" in result["supportedVersions"]
  end

  test "parses string-keyed and atom-keyed discovery metadata" do
    for meta <- [
          %{"io.modelcontextprotocol/serverInfo" => %{"name" => "server"}},
          %{"io.modelcontextprotocol/serverInfo": %{name: "server"}}
        ] do
      result = %{
        supportedVersions: ["2026-07-28"],
        capabilities: %{tools: %{}},
        ttlMs: 10,
        cacheScope: :public,
        _meta: meta
      }

      assert {:ok, parsed} = Discover.parse_result(result)
      assert parsed.server_info
      assert parsed.ttl_ms == 10
      assert parsed.cache_scope == "public"
    end
  end

  test "rejects invalid discovery cache metadata" do
    valid = %{
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{},
      "ttlMs" => 10,
      "cacheScope" => "public"
    }

    assert {:error, {:invalid_discover_field, "ttlMs"}} =
             Discover.parse_result(%{valid | "ttlMs" => -1})

    assert {:error, {:invalid_discover_field, "ttlMs"}} =
             Discover.parse_result(%{valid | "ttlMs" => 1.5})

    assert {:error, {:invalid_discover_field, "cacheScope"}} =
             Discover.parse_result(%{valid | "cacheScope" => "shared"})
  end
end
