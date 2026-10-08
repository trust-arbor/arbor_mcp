defmodule Arbor.MCP.Server.DSL.ResultReplacementTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Internal.Result, as: CallbackResult

  alias Arbor.MCP.Server.DSL.Result

  defmodule PrivateReason do
    defstruct [:secret]
  end

  defmodule ReplacementServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "media", "Returns mixed media" do
      run(fn _args, state ->
        {:ok,
         ToolResult.content([
           %{type: "text", text: "preview"},
           hd(ToolResult.image("aW1hZ2U=", "image/png").content),
           hd(ToolResult.audio("YXVkaW8=", "audio/wav").content),
           hd(ToolResult.resource(%{uri: "file:///notes", text: "notes"}).content)
         ]), Map.put(state, :completed, true)}
      end)
    end

    tool "structured_error", "Returns authored structured failure" do
      output_schema(%{
        type: "object",
        properties: %{retryable: %{type: "boolean"}},
        required: ["retryable"]
      })

      run(fn _args, state ->
        {:ok, ToolResult.structured("Try again", %{retryable: true}, is_error: true), state}
      end)
    end

    tool "string_keys", "Preserves complete string-keyed results" do
      run(fn _args, state ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => "unavailable"}],
           "structuredContent" => %{"retryable" => false},
           "isError" => true,
           "_meta" => %{"request" => "authored"}
         }, state}
      end)
    end

    tool "unsupported", "Rejects private non-result values" do
      run(fn _args, state ->
        {:ok, {:private, "credential-value"}, Map.put(state, :completed, true)}
      end)
    end

    tool "opaque_error", "Does not expose private error values" do
      run(fn _args, state ->
        {:error, %{credentials: "credential-value", connection: self()}, state}
      end)
    end
  end

  test "text, binary errors and structured/2 retain their existing complete shapes" do
    assert Result.text("hello") == %{content: [%{type: "text", text: "hello"}]}

    assert Result.error("authored detail") == %{
             content: [%{type: "text", text: "authored detail"}],
             isError: true
           }

    assert Result.structured("done", %{count: 1}) == %{
             content: [%{type: "text", text: "done"}],
             structuredContent: %{count: 1}
           }
  end

  test "mixed content maps, annotations and nested data remain unchanged" do
    entries = [
      %{type: "text", text: "description", annotations: %{audience: ["user"]}},
      %{"type" => "image", "data" => "aW1hZ2U=", "mimeType" => "image/png"}
    ]

    assert Result.content(entries) == %{content: entries}
    assert CallbackResult.normalize_tool_result(entries) == %{content: entries}
    assert Result.content([]) == %{content: []}
  end

  test "image and audio constructors require already-base64 data and explicit MIME" do
    assert Result.image("aW1hZ2U=", "image/png") == %{
             content: [%{type: "image", data: "aW1hZ2U=", mimeType: "image/png"}]
           }

    assert Result.audio("YXVkaW8=", "audio/wav") == %{
             content: [%{type: "audio", data: "YXVkaW8=", mimeType: "audio/wav"}]
           }

    for constructor <- [&Result.image/2, &Result.audio/2],
        {data, mime} <- [
          {"not base64", "image/png"},
          {<<255>>, "image/png"},
          {"aW1hZ2U=", ""},
          {"aW1hZ2U=", nil},
          {self(), "image/png"}
        ] do
      assert_invalid(fn -> constructor.(data, mime) end)
    end
  end

  test "resource contents carry exactly one text or blob without URI fetching" do
    text = %{uri: "file:///notes", text: "notes", mimeType: "text/plain", _meta: %{source: "app"}}

    blob = %{
      "uri" => "memory://bytes",
      "blob" => "Ynl0ZXM=",
      "mimeType" => "application/octet-stream"
    }

    assert Result.resource(text) == %{content: [%{type: "resource", resource: text}]}
    assert Result.resource(blob) == %{content: [%{type: "resource", resource: blob}]}
    assert Result.resource(%{uri: "memory://empty", text: ""}).content != []
  end

  test "incomplete, ambiguous or invalid embedded resource contents fail explicitly" do
    for contents <- [
          %{uri: "file:///notes"},
          %{uri: "", text: "notes"},
          %{text: "notes"},
          %{uri: "file:///notes", text: "notes", blob: "Ynl0ZXM="},
          %{uri: "file:///notes", text: nil},
          %{uri: "file:///notes", blob: "not base64"},
          %{uri: "file:///notes", text: "notes", mimeType: nil},
          %{uri: "file:///notes", text: "notes", _meta: "private"},
          %{:uri => "file:///notes", "uri" => "other://notes", :text => "notes"},
          %PrivateReason{secret: "credential-value"},
          "file:///notes"
        ] do
      assert_invalid(fn -> Result.resource(contents) end)
    end
  end

  test "structured/3 represents successful or failed structured tool results" do
    assert Result.structured("done", %{count: 1}, is_error: false) == %{
             content: [%{type: "text", text: "done"}],
             structuredContent: %{count: 1},
             isError: false
           }

    assert Result.structured("retry", %{retryable: true}, is_error: true).isError
    assert Result.structured("done", %{count: 1}, []) == Result.structured("done", %{count: 1})
  end

  test "error/2 adds structured data while preserving binary error text" do
    assert Result.error("authored", structured_content: %{retryable: false}) == %{
             content: [%{type: "text", text: "authored"}],
             structuredContent: %{retryable: false},
             isError: true
           }

    assert Result.error("authored", []) == Result.error("authored")
  end

  test "options reject unsupported types, unknown names and ambiguous duplicates" do
    for opts <- [
          [is_error: nil],
          [is_error: "true"],
          [is_error: true, is_error: false],
          [unknown: true],
          %{is_error: true},
          [:is_error],
          [{:is_error, true} | :tail]
        ] do
      assert_invalid(fn -> Result.structured("done", %{}, opts) end)
    end

    for opts <- [
          [structured_content: self()],
          [structured_content: {:private, "value"}],
          [structured_content: %PrivateReason{}],
          [is_error: false]
        ] do
      assert_invalid(fn -> Result.error("authored", opts) end)
    end

    assert_invalid(fn -> Result.structured("done", [1 | :tail], []) end)
    assert_invalid(fn -> Result.structured(nil, %{}, []) end)
  end

  test "nonbinary error reasons expose only deliberately authored safe detail" do
    assert error_text(Result.error(:unavailable)) == "Tool execution failed: unavailable"

    assert error_text(Result.error(%{message: "retry later", secret: "credential-value"})) ==
             "Tool execution failed: retry later"

    assert error_text(Result.error(%{"message" => "retry later", "secret" => "credential-value"})) ==
             "Tool execution failed: retry later"

    for reason <- [
          self(),
          make_ref(),
          fn -> :private end,
          nil,
          true,
          false,
          %{credentials: "credential-value"},
          {:private, "credential-value"},
          %PrivateReason{secret: "credential-value"}
        ] do
      assert error_text(Result.error(reason)) == "Tool execution failed"
    end
  end

  test "complete atom and string result maps preserve errors, structured data and metadata" do
    for result <- [
          %{
            content: [%{type: "text", text: "retry"}],
            structuredContent: %{retryable: true},
            isError: true,
            _meta: %{source: "app"}
          },
          %{
            "content" => [%{"type" => "text", "text" => "retry"}],
            "structuredContent" => %{"retryable" => true},
            "isError" => true,
            "_meta" => %{"source" => "app"}
          }
        ] do
      assert CallbackResult.normalize_tool_result(result) == result
    end
  end

  test "complete results take precedence over shorthand text fields" do
    complete = %{text: "shorthand", content: [], structuredContent: %{ok: true}, isError: false}
    assert CallbackResult.normalize_tool_result(complete) == complete

    assert CallbackResult.normalize_tool_result(text: "shorthand") ==
             Result.text("shorthand")

    assert CallbackResult.normalize_tool_result(%{text: "shorthand"}) ==
             Result.text("shorthand")

    assert CallbackResult.normalize_tool_result(%{"text" => "shorthand"}) ==
             Result.text("shorthand")
  end

  test "legacy structuredOutput aliases normalize without overriding canonical content" do
    assert CallbackResult.normalize_tool_result(%{structuredOutput: %{count: 1}}) ==
             %{content: [], structuredContent: %{count: 1}}

    assert CallbackResult.normalize_tool_result(%{
             "structuredOutput" => %{"count" => 1}
           }) ==
             %{"content" => [], "structuredContent" => %{"count" => 1}}

    assert CallbackResult.normalize_tool_result(%{
             content: [],
             structuredContent: %{count: 2},
             structuredOutput: %{count: 1}
           }) ==
             %{content: [], structuredContent: %{count: 2}}
  end

  test "unsupported top-level values fail before callback state can be returned" do
    for value <- [
          self(),
          make_ref(),
          {:private, "credential-value"},
          %{credentials: "credential-value"},
          %PrivateReason{secret: "credential-value"},
          ["text"],
          [%PrivateReason{}],
          [%{} | :tail],
          %{content: "not a list"}
        ] do
      assert_invalid(fn ->
        CallbackResult.normalize_tool({:ok, value, %{committed: true}}, %{})
      end)
    end

    assert_invalid(fn -> ReplacementServer.handle_call_tool("unsupported", %{}, %{}) end)
  end

  test "nested unknown values remain for protocol output admission to reject" do
    opaque = %PrivateReason{secret: "credential-value"}
    result = Result.structured("done", %{nested: opaque, pid: self()})
    assert result.structuredContent.nested == opaque
    assert CallbackResult.normalize_tool_result(result) == result
    assert Result.content([%{type: "text", text: "done", _meta: %{opaque: opaque}}]).content != []
  end

  test "MRTR markers retain their existing distinct normalization path" do
    marker = Result.input_required(%{"form" => %{"message" => "more information"}}, %{step: 1})
    assert CallbackResult.normalize_tool_result(marker) == marker
  end

  test "real DSL inline handlers consume mixed constructors and retain state" do
    assert {:ok, result, %{completed: true}} =
             ReplacementServer.handle_call_tool("media", %{}, %{})

    assert Enum.map(result.content, & &1.type) == ["text", "image", "audio", "resource"]
  end

  test "real DSL output schema validates structured failure and string-keyed complete maps survive" do
    assert {:ok, %{isError: true, structuredContent: %{retryable: true}}, %{}} =
             ReplacementServer.handle_call_tool("structured_error", %{}, %{})

    assert {:ok, result, %{}} = ReplacementServer.handle_call_tool("string_keys", %{}, %{})
    assert result["isError"]
    assert result["structuredContent"] == %{"retryable" => false}
    assert result["_meta"] == %{"request" => "authored"}
    assert {:ok, opaque_error, %{}} = ReplacementServer.handle_call_tool("opaque_error", %{}, %{})
    assert error_text(opaque_error) == "Tool execution failed"
  end

  defp error_text(%{content: [%{text: text}]}), do: text

  defp assert_invalid(function) do
    assert_raise ArgumentError, "Invalid tool result or result options", function
  end
end
