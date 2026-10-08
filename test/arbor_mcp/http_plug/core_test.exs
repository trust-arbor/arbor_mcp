defmodule Arbor.MCP.HttpPlug.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.HttpPlug.Core

  describe "parse_json/1" do
    test "accepts JSON objects and rejects scalars" do
      assert {:ok, %{"jsonrpc" => "2.0"}} = Core.parse_json(~s({"jsonrpc":"2.0"}))
      assert {:error, :invalid_json_rpc_envelope} = Core.parse_json(~s(["not", "an", "object"]))
      assert {:error, :parse_error} = Core.parse_json("{")
    end
  end

  describe "origin_allowed?/2" do
    test "allows requests without an Origin header" do
      assert Core.origin_allowed?(%{origin: nil}, %{allowed_origins: []})
      assert Core.origin_allowed?(%{}, %{allowed_origins: []})
      assert Core.origin_allowed?(%{origin: ""}, %{allowed_origins: []})
    end

    test "rejects origins matching the request host (no same-origin fallback)" do
      # The Host header is attacker-controlled in a DNS rebinding attack, so
      # an Origin equal to scheme/host/port must NOT be implicitly trusted.
      context = %{origin: "http://localhost:4000", scheme: "http", host: "localhost", port: 4000}

      refute Core.origin_allowed?(context, %{allowed_origins: []})
    end

    test "allows explicit origins and rejects others" do
      opts = %{allowed_origins: ["https://allowed.example"]}

      assert Core.origin_allowed?(%{origin: "https://allowed.example"}, opts)
      refute Core.origin_allowed?(%{origin: "https://blocked.example"}, opts)
    end

    test "allows any origin when configured with :any" do
      opts = %{allowed_origins: :any}

      assert Core.origin_allowed?(%{origin: "https://anything.example"}, opts)
    end
  end

  describe "host_allowed?/2" do
    test ":any allows every host" do
      assert Core.host_allowed?("evil.example", :any)
      assert Core.host_allowed?(nil, :any)
    end

    test "rejects hosts not in the allow-list" do
      refute Core.host_allowed?("evil.example", ["localhost"])
      refute Core.host_allowed?("evil.example:4000", ["localhost"])
      refute Core.host_allowed?(nil, ["localhost"])
    end

    test "matches allowed hosts ignoring port and case" do
      assert Core.host_allowed?("localhost", ["localhost"])
      assert Core.host_allowed?("localhost:4000", ["localhost"])
      assert Core.host_allowed?("LOCALHOST:4000", ["localhost"])
      assert Core.host_allowed?("127.0.0.1:8080", ["127.0.0.1"])
    end

    test "matches IPv6 hosts with or without brackets" do
      assert Core.host_allowed?("[::1]:8080", ["[::1]"])
      assert Core.host_allowed?("[::1]:8080", ["::1"])
      assert Core.host_allowed?("[::1]", ["::1"])
      assert Core.host_allowed?("::1", ["[::1]"])
      refute Core.host_allowed?("[::2]:8080", ["::1", "[::1]"])
    end
  end

  describe "normalize_host/1" do
    test "strips ports from bracketed and plain hosts" do
      assert Core.normalize_host("localhost:4000") == "localhost"
      assert Core.normalize_host("[::1]:8080") == "[::1]"
      assert Core.normalize_host("[2001:db8::1]:443") == "[2001:db8::1]"
    end

    test "does not mangle raw IPv6 literals" do
      assert Core.normalize_host("::1") == "::1"
      assert Core.normalize_host("2001:db8::1") == "2001:db8::1"
    end

    test "downcases and trims" do
      assert Core.normalize_host(" LocalHost ") == "localhost"
    end
  end
end
