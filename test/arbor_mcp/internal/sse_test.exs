defmodule Arbor.MCP.Internal.SSETest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.SSE

  describe "parse_complete/1" do
    test "parses CRLF-framed events and ignores comment keepalives" do
      body = ":\r\n\r\ndata: {\"ok\":true}\r\n\r\n"

      assert SSE.parse_complete(body) == [%{data: ~s({"ok":true})}]
    end

    test "parses complete SSE response bodies into atom-keyed events" do
      body = """
      event: message
      id: 1
      retry: 3000
      : ignored
      data: {"jsonrpc":"2.0"}

      """

      assert SSE.parse_complete(body) == [
               %{
                 event: "message",
                 id: "1",
                 retry: 3000,
                 data: ~s({"jsonrpc":"2.0"})
               }
             ]
    end

    test "preserves POST response data concatenation behavior" do
      body = """
      data: {"a":
      data: 1}

      """

      assert SSE.parse_complete(body) == [%{data: ~s({"a":1})}]
    end

    test "ignores empty and malformed complete blocks" do
      assert SSE.parse_complete("\n\n: comment\n\nnot-a-field\n\n") == []
      assert SSE.parse_complete(nil) == []
    end

    test "ignores negative and partially parsed retry values" do
      assert SSE.parse_complete("retry: -1\ndata: one\n\n") == [%{data: "one"}]
      assert SSE.parse_complete("retry: 999junk\ndata: two\n\n") == [%{data: "two"}]
    end
  end

  describe "parse_stream/1" do
    test "parses CRLF chunks and discards comment keepalives" do
      body = ":\r\n\r\ndata: {\"ok\":true}\r\n\r\n"

      assert SSE.parse_stream(body) == {[%{"data" => ~s({"ok":true})}], ""}
    end

    test "parses complete streaming events into string-keyed events" do
      body = "event: update\nid: 1\nretry: 5000\ndata: hello\n\n"

      assert SSE.parse_stream(body) ==
               {[
                  %{
                    "event" => "update",
                    "id" => "1",
                    "retry" => "5000",
                    "data" => "hello"
                  }
                ], ""}
    end

    test "preserves streaming repeated field newline behavior" do
      body = "data: hello\ndata: world\n\n"

      assert SSE.parse_stream(body) == {[%{"data" => "hello\nworld"}], ""}
    end

    test "returns partial event text as remaining buffer" do
      assert {[], "data: hello"} = SSE.parse_stream("data: hello")
    end

    test "returns incomplete line text as remaining buffer" do
      assert {[], "partial"} = SSE.parse_stream("partial")
    end

    test "ignores comments" do
      assert SSE.parse_stream(": keep-alive\n\n") == {[], ""}
    end
  end
end
