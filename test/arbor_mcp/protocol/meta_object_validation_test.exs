defmodule Arbor.MCP.Protocol.MetaObjectValidationTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.RequestParams
  alias Arbor.MCP.Protocol.Meta

  test "non-object metadata returns the documented typed error before defaults are read" do
    for meta <- [nil, "invalid", [], 5, true] do
      assert {:error, {:invalid_meta, :not_an_object}} ==
               Meta.build_request_meta(meta, "2026-07-28", %{}, [])
    end
  end

  test "modern request preparation preserves typed metadata validation failure" do
    context = %{protocol_version: "2026-07-28", client_capabilities: %{}}

    assert {:error, {:invalid_meta, :not_an_object}} ==
             RequestParams.for_request(%{"_meta" => "invalid"}, context)
  end

  test "valid inherited log level and custom fields preserve their exact metadata values" do
    meta = %{"io.modelcontextprotocol/logLevel" => "debug", "app.example/field" => "kept"}
    assert {:ok, result} = Meta.build_request_meta(meta, "2026-07-28", %{})

    assert result ==
             Map.merge(meta, %{
               "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
               "io.modelcontextprotocol/clientCapabilities" => %{}
             })
  end

  test "explicit log level continues to take precedence over inherited metadata" do
    assert {:ok, result} =
             Meta.build_request_meta(
               %{"io.modelcontextprotocol/logLevel" => "debug"},
               "2026-07-28",
               %{},
               log_level: :warning
             )

    assert result["io.modelcontextprotocol/logLevel"] == "warning"
  end

  test "invalid keys and invalid inherited log level remain typed failures" do
    assert {:error, {:invalid_meta_key, "bad/key/shape"}} ==
             Meta.build_request_meta(%{"bad/key/shape" => 1}, "2026-07-28", %{})

    assert {:error, {:invalid_meta_field, "io.modelcontextprotocol/logLevel"}} ==
             Meta.build_request_meta(
               %{"io.modelcontextprotocol/logLevel" => "wrong"},
               "2026-07-28",
               %{}
             )
  end
end
