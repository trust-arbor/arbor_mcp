defmodule Arbor.MCP.Server.ResultNormalizerProtocolTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.MCP.Server.ResultNormalizer

  test "raw Handler structured aliases retain false/null and enforce the negotiated era" do
    for value <- [false, nil, [1], "scalar"] do
      result = %{content: [], structuredOutput: value}

      assert %{"structuredContent" => ^value} =
               ResultNormalizer.protocol_result(result, %{era: :modern, method: "tools/call"})

      assert_raise ArgumentError, "Legacy structured tool content must be an object", fn ->
        ResultNormalizer.protocol_result(result, %{era: :legacy, method: "tools/call"})
      end
    end

    result = %{content: [], structuredOutput: %{count: 1}}

    assert %{"structuredContent" => %{"count" => 1}} =
             ResultNormalizer.protocol_result(result, %{era: :legacy, method: "tools/call"})
  end

  test "canonical structured content wins over its compatibility alias by presence" do
    for value <- [false, nil] do
      result = %{content: [], structuredContent: value, structuredOutput: %{ignored: true}}

      normalized =
        ResultNormalizer.protocol_result(result, %{era: :modern, method: "tools/call"})

      assert Map.fetch(normalized, "structuredContent") == {:ok, value}
      refute Map.has_key?(normalized, "structuredOutput")
    end
  end

  test "leaves legacy results unchanged" do
    result = %{"tools" => []}

    assert ResultNormalizer.protocol_result(result, %{era: :legacy},
             server_info: %{name: "example", version: "1"}
           ) == result
  end

  test "preserves handler ordering for legacy tool lists" do
    result = %{"tools" => [%{"name" => "zebra"}, %{"name" => "alpha"}]}

    assert ResultNormalizer.protocol_result(result, %{era: :legacy, method: "tools/list"}) ==
             result
  end

  test "sorts modern tool lists deterministically by name" do
    tools = [
      %{name: "zebra", description: "last"},
      %{name: "alpha", description: "first"},
      %{name: "middle", description: "second"}
    ]

    expected_names = ["alpha", "middle", "zebra"]

    for permutation <- [
          tools,
          Enum.reverse(tools),
          [Enum.at(tools, 1), hd(tools), List.last(tools)]
        ] do
      result =
        ResultNormalizer.protocol_result(
          %{tools: permutation},
          %{era: :modern, method: "tools/list"},
          server_info: %{name: "example", version: "1"}
        )

      assert Enum.map(result["tools"], & &1["name"]) == expected_names
      assert result["ttlMs"] == 0
      assert result["cacheScope"] == "private"
    end
  end

  test "removes the legacy execution hint only from modern tool lists" do
    tool = %{
      "name" => "background",
      "inputSchema" => %{"type" => "object"},
      "execution" => %{"taskSupport" => "optional"}
    }

    modern =
      ResultNormalizer.protocol_result(
        %{"tools" => [tool]},
        %{era: :modern, method: "tools/list"}
      )

    refute Map.has_key?(hd(modern["tools"]), "execution")

    legacy = ResultNormalizer.protocol_result(%{"tools" => [tool]}, %{era: :legacy})
    assert hd(legacy["tools"])["execution"] == %{"taskSupport" => "optional"}
  end

  test "adds conservative cache defaults and preserves valid handler overrides" do
    defaulted =
      ResultNormalizer.protocol_result(
        %{contents: []},
        %{era: :modern, method: "resources/read"}
      )

    assert defaulted["ttlMs"] == 0
    assert defaulted["cacheScope"] == "private"

    overridden =
      ResultNormalizer.protocol_result(
        %{prompts: [], ttl_ms: 30_000, cache_scope: :public},
        %{era: :modern, method: "prompts/list"}
      )

    assert overridden["ttlMs"] == 30_000
    assert overridden["cacheScope"] == "public"
  end

  test "repairs invalid cache hints and removes them from non-complete results" do
    repaired =
      ResultNormalizer.protocol_result(
        %{"tools" => [], "ttlMs" => -1, "cacheScope" => "shared"},
        %{era: :modern, method: "tools/list"}
      )

    assert repaired["ttlMs"] == 0
    assert repaired["cacheScope"] == "private"

    interim =
      ResultNormalizer.protocol_result(
        %{"resultType" => "input_required", "ttlMs" => 10, "cacheScope" => "public"},
        %{era: :modern, method: "resources/read"}
      )

    refute Map.has_key?(interim, "ttlMs")
    refute Map.has_key?(interim, "cacheScope")
  end

  test "stamps complete modern results with canonical server metadata" do
    result =
      ResultNormalizer.protocol_result(
        %{tools: [], _meta: %{"com.example/value" => true}},
        %{era: :modern},
        server_info: %{name: "example", version: "1"}
      )

    assert result["resultType"] == "complete"
    assert result["tools"] == []
    assert result["_meta"]["com.example/value"]

    assert result["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
             "name" => "example",
             "version" => "1"
           }
  end

  test "preserves input-required and extension result discriminators" do
    for result_type <- ["input_required", "com.example/custom"] do
      result =
        ResultNormalizer.protocol_result(
          %{"resultType" => result_type},
          %{era: :modern}
        )

      assert result["resultType"] == result_type
    end
  end

  test "marks modern tasks/get state complete and enforces task-result negotiation" do
    context = %{
      era: :modern,
      method: "tasks/get",
      client_capabilities: %{
        "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
      }
    }

    result = ResultNormalizer.protocol_result(%{"taskId" => "task-1"}, context)
    assert result["resultType"] == "complete"

    task_result = %{
      "resultType" => "task",
      "taskId" => "task-1",
      "status" => "working",
      "createdAt" => "2026-08-04T00:00:00Z",
      "lastUpdatedAt" => "2026-08-04T00:00:00Z",
      "ttlMs" => 60_000
    }

    assert :ok = ResultNormalizer.validate_result_capabilities(task_result, context)

    assert {:error, error} =
             ResultNormalizer.validate_result_capabilities(task_result, %{
               era: :modern,
               method: "tools/call",
               client_capabilities: %{}
             })

    assert error.code == -32021

    log =
      capture_log(fn ->
        assert {:error, error} =
                 ResultNormalizer.validate_result_capabilities(
                   %{"taskId" => "task-1"},
                   context
                 )

        assert error.code == -32603
        assert error.message == "Invalid task result"
      end)

    assert log =~ "invalid Tasks extension result"
  end

  test "connection-owned server identity replaces handler-supplied identity" do
    result =
      ResultNormalizer.protocol_result(
        %{
          "_meta" => %{
            "io.modelcontextprotocol/serverInfo" => %{"name" => "spoofed"}
          }
        },
        %{era: :modern},
        server_info: %{"name" => "configured", "version" => "1"}
      )

    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "configured"
  end

  test "error_code maps unknown-name strings to -32602" do
    assert ResultNormalizer.error_code("Unknown tool: nope") == -32602
    assert ResultNormalizer.error_code("Unknown prompt: nope") == -32602
    assert ResultNormalizer.error_code("Prompt not found: nope") == -32602
    assert ResultNormalizer.error_code("Unknown resource: missing://x") == -32602
    assert ResultNormalizer.error_code("Resource not found: missing://x") == -32602
    assert ResultNormalizer.error_code("render exploded") == -32000
    assert ResultNormalizer.unknown_name_reason?("Unknown prompt: nope")
    refute ResultNormalizer.unknown_name_reason?("render exploded")
  end
end
