defmodule Arbor.MCP.Protocol.CacheableResultTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.CacheableResult

  @schema_path Path.expand("../../../docs/mcp-specs/2026-07-28/schema.json", __DIR__)

  test "runtime cacheable method set matches the vendored schema" do
    schema = @schema_path |> File.read!() |> Jason.decode!()
    definitions = schema["$defs"]

    schema_methods =
      definitions
      |> Enum.flat_map(fn {result_name, definition} ->
        required = Map.get(definition, "required", [])
        request_name = String.replace_suffix(result_name, "Result", "Request")

        if String.ends_with?(result_name, "Result") and
             "ttlMs" in required and
             "cacheScope" in required do
          case get_in(definitions, [request_name, "properties", "method", "const"]) do
            method when is_binary(method) -> [method]
            _no_matching_request -> []
          end
        else
          []
        end
      end)
      |> Enum.sort()

    assert Enum.sort(CacheableResult.methods()) == schema_methods
  end

  test "accepts only complete results with valid cache hints" do
    assert :ok =
             CacheableResult.validate("tools/list", :complete, %{
               "ttlMs" => 0,
               "cacheScope" => "private"
             })

    assert :ok =
             CacheableResult.validate("resources/read", :complete, %{
               ttlMs: 60_000,
               cacheScope: "public"
             })

    assert {:error, :missing_ttl_ms} =
             CacheableResult.validate("tools/list", :complete, %{"cacheScope" => "private"})

    assert {:error, {:invalid_ttl_ms, -1}} =
             CacheableResult.validate("tools/list", :complete, %{
               "ttlMs" => -1,
               "cacheScope" => "private"
             })

    assert {:error, {:invalid_ttl_ms, 1.5}} =
             CacheableResult.validate("tools/list", :complete, %{
               "ttlMs" => 1.5,
               "cacheScope" => "private"
             })

    assert {:error, :missing_cache_scope} =
             CacheableResult.validate("tools/list", :complete, %{"ttlMs" => 0})

    assert {:error, {:invalid_cache_scope, "shared"}} =
             CacheableResult.validate("tools/list", :complete, %{
               "ttlMs" => 0,
               "cacheScope" => "shared"
             })
  end

  test "rejects cache hints on non-complete cacheable results" do
    assert :ok = CacheableResult.validate("tools/list", :input_required, %{})

    assert {:error, :cache_hints_not_allowed} =
             CacheableResult.validate("tools/list", :input_required, %{"ttlMs" => 0})

    assert :ok =
             CacheableResult.validate("tools/call", :complete, %{
               "ttlMs" => -1,
               "cacheScope" => "unknown"
             })
  end
end
