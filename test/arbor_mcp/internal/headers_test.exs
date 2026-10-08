defmodule Arbor.MCP.Internal.HeadersTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Headers

  describe "get/2" do
    test "looks up list headers case-insensitively" do
      headers = [{"Authorization", "Bearer token"}]

      assert Headers.get(headers, "authorization") == "Bearer token"
      assert Headers.get(headers, "AUTHORIZATION") == "Bearer token"
    end

    test "looks up charlist headers and normalizes charlist values" do
      headers = [{~c"www-authenticate", ~c"Bearer realm=\"example\""}]

      assert Headers.get(headers, "WWW-Authenticate") == ~s(Bearer realm="example")
    end

    test "looks up map headers with binary, atom, and charlist keys" do
      assert Headers.get(%{"content-type" => "application/json"}, "Content-Type") ==
               "application/json"

      assert Headers.get(%{authorization: "Bearer token"}, "authorization") == "Bearer token"
      assert Headers.get(%{~c"mcp-session-id" => ~c"session-1"}, "Mcp-Session-Id") == "session-1"
    end

    test "ignores malformed header entries and unsupported containers" do
      assert Headers.get([:not_a_header], "authorization") == nil
      assert Headers.get(nil, "authorization") == nil
      assert Headers.get([], :authorization) == nil
    end
  end

  describe "delete/2" do
    test "removes matching list headers case-insensitively" do
      headers = [
        {"Authorization", "Bearer old"},
        {~c"authorization", ~c"Bearer older"},
        {"Accept", "application/json"}
      ]

      assert Headers.delete(headers, "authorization") == [{"Accept", "application/json"}]
    end

    test "ignores malformed list entries" do
      headers = [:not_a_header, {"Accept", "application/json"}]

      assert Headers.delete(headers, "authorization") == headers
    end

    test "leaves headers unchanged for unsupported header names" do
      headers = [{"Accept", "application/json"}]

      assert Headers.delete(headers, 123) == headers
    end
  end
end
