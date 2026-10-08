defmodule Arbor.MCP.Protocol.InitializeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.Initialize

  test "builds a canonical string-keyed initialize result" do
    result =
      Initialize.build_initialize_result(
        %{"protocolVersion" => "2025-06-18"},
        %{
          serverInfo: %{name: "example", version: "1.0.0"},
          capabilities: %{tools: %{listChanged: true}},
          instructions: "Use carefully"
        }
      )

    assert result == %{
             "protocolVersion" => "2025-06-18",
             "serverInfo" => %{"name" => "example", "version" => "1.0.0"},
             "capabilities" => %{"tools" => %{"listChanged" => true}},
             "instructions" => "Use carefully"
           }
  end

  test "prefers an explicitly negotiated result version" do
    result =
      Initialize.build_initialize_result(
        %{"protocolVersion" => "2025-03-26"},
        %{"protocolVersion" => "2025-06-18"}
      )

    assert result["protocolVersion"] == "2025-06-18"
  end

  test "uses the supported preference when the version is omitted or staged" do
    omitted = Initialize.build_initialize_result(%{}, %{})

    staged =
      Initialize.build_initialize_result(
        %{"protocolVersion" => "2026-07-28"},
        %{"protocolVersion" => "2026-07-28"}
      )

    assert omitted["protocolVersion"] == "2025-11-25"
    assert staged["protocolVersion"] == "2025-11-25"
  end

  test "supports legacy flat server name and version fields" do
    result = Initialize.build_initialize_result(%{}, %{name: "legacy", version: "0.1.0"})

    assert result["serverInfo"] == %{"name" => "legacy", "version" => "0.1.0"}
    refute Map.has_key?(result, "name")
    refute Map.has_key?(result, "version")
  end
end
