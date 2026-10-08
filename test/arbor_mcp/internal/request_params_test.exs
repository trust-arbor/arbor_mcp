defmodule Arbor.MCP.Internal.RequestParamsTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.RequestParams

  @traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

  describe "cursor/1" do
    test "omits cursor params when no cursor is present" do
      assert RequestParams.cursor(nil) == %{}
    end

    test "builds cursor params when a cursor is present" do
      assert RequestParams.cursor("next-page") == %{"cursor" => "next-page"}
    end
  end

  describe "cursor_from_opts/1" do
    test "omits cursor params when options do not contain a cursor" do
      assert RequestParams.cursor_from_opts([]) == %{}
      assert RequestParams.cursor_from_opts(timeout: 5_000) == %{}
    end

    test "builds cursor params from options" do
      assert RequestParams.cursor_from_opts(cursor: "next-page") == %{"cursor" => "next-page"}
    end
  end

  describe "take_cursor/1" do
    test "returns cursor params and remaining options" do
      assert RequestParams.take_cursor(cursor: "next-page", timeout: 5_000) ==
               {%{"cursor" => "next-page"}, [timeout: 5_000]}
    end

    test "returns empty params when cursor is absent" do
      assert RequestParams.take_cursor(timeout: 5_000) == {%{}, [timeout: 5_000]}
    end
  end

  describe "uri/1" do
    test "builds URI params" do
      assert RequestParams.uri("file:///tmp/example.txt") == %{"uri" => "file:///tmp/example.txt"}
    end
  end

  describe "named/2" do
    test "builds named operation params with arguments" do
      assert RequestParams.named("weather", %{"location" => "Chicago"}) == %{
               "name" => "weather",
               "arguments" => %{"location" => "Chicago"}
             }
    end

    test "defaults arguments to an empty map" do
      assert RequestParams.named("weather") == %{"name" => "weather", "arguments" => %{}}
    end
  end

  describe "completion/2" do
    test "builds completion params" do
      ref = %{"type" => "ref/prompt", "name" => "code"}
      argument = %{"name" => "language", "value" => "elixir"}

      assert RequestParams.completion(ref, argument) == %{"ref" => ref, "argument" => argument}
    end
  end

  describe "metadata helpers" do
    test "adds request metadata when meta is a map" do
      params = RequestParams.named("weather")

      assert RequestParams.with_meta(params, %{"progressToken" => "token-1"}) == %{
               "name" => "weather",
               "arguments" => %{},
               "_meta" => %{"progressToken" => "token-1"}
             }
    end

    test "preserves client option behavior by adding empty metadata maps" do
      params = RequestParams.named("weather")

      assert RequestParams.with_opts_meta(params, meta: %{}) == %{
               "name" => "weather",
               "arguments" => %{},
               "_meta" => %{}
             }
    end

    test "ignores metadata values that are not maps" do
      params = RequestParams.named("weather")

      assert RequestParams.with_meta(params, "token-1") == params
      assert RequestParams.with_opts_meta(params, []) == params
    end

    test "omits empty metadata maps for protocol encoding" do
      params = RequestParams.named("weather")

      assert RequestParams.with_non_empty_meta(params, %{}) == params

      assert RequestParams.with_non_empty_meta(params, %{"requestId" => "req-1"}) == %{
               "name" => "weather",
               "arguments" => %{},
               "_meta" => %{"requestId" => "req-1"}
             }
    end

    test "normalizes progress tokens into metadata" do
      params = RequestParams.named("weather")

      assert RequestParams.with_progress_or_meta(params, "token-1") == %{
               "name" => "weather",
               "arguments" => %{},
               "_meta" => %{"progressToken" => "token-1"}
             }

      assert RequestParams.with_progress_or_meta(params, 123) == %{
               "name" => "weather",
               "arguments" => %{},
               "_meta" => %{"progressToken" => 123}
             }
    end
  end

  describe "for_request/2" do
    test "leaves legacy request params unchanged" do
      params = %{"name" => "weather", "_meta" => %{"progressToken" => 1}}

      assert {:ok, ^params} =
               RequestParams.for_request(params, %{
                 protocol_version: "2025-11-25",
                 client_info: %{"name" => "Arbor.MCP", "version" => "1"}
               })
    end

    test "injects the required metadata on every modern request" do
      params = %{
        "name" => "weather",
        "_meta" => %{
          "progressToken" => 1,
          "io.modelcontextprotocol/protocolVersion" => "spoofed"
        }
      }

      context = %{
        protocol_version: "2026-07-28",
        client_info: %{"name" => "Arbor.MCP", "version" => "1.0"},
        client_capabilities: %{elicitation: %{form: %{}}}
      }

      assert {:ok, modern_params} = RequestParams.for_request(params, context)
      meta = modern_params["_meta"]

      assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"

      assert meta["io.modelcontextprotocol/clientCapabilities"] == %{
               "elicitation" => %{"form" => %{}}
             }

      assert meta["io.modelcontextprotocol/clientInfo"] == %{
               "name" => "Arbor.MCP",
               "version" => "1.0"
             }

      assert meta["progressToken"] == 1
    end

    test "reads capabilities from client transport options" do
      context = %{
        protocol_version: "2026-07-28",
        client_info: %{"name" => "Arbor.MCP", "version" => "1.0"},
        transport_opts: [capabilities: %{roots: %{}}]
      }

      assert {:ok, %{"_meta" => meta}} = RequestParams.for_request(%{}, context)
      assert meta["io.modelcontextprotocol/clientCapabilities"] == %{"roots" => %{}}
    end

    test "propagates validated trace context from client transport options" do
      context = %{
        protocol_version: "2026-07-28",
        client_info: %{"name" => "Arbor.MCP", "version" => "1.0"},
        transport_opts: [trace_context: %{traceparent: @traceparent}]
      }

      assert {:ok, %{"_meta" => meta}} = RequestParams.for_request(%{}, context)
      assert meta["traceparent"] == @traceparent
    end
  end
end
