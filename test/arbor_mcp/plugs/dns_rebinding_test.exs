defmodule Arbor.MCP.Plugs.DnsRebindingTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Arbor.MCP.Plugs.DnsRebinding

  defp call(host_header, opts \\ []) do
    # Plug forbids put_req_header/3 for "host"; inject it directly.
    %Plug.Conn{} = base = conn(:get, "/")
    conn = %{base | req_headers: [{"host", host_header} | base.req_headers]}
    DnsRebinding.call(conn, DnsRebinding.init(opts))
  end

  describe "default allow-list" do
    test "allows localhost with and without port" do
      refute call("localhost").halted
      refute call("localhost:4000").halted
      refute call("LOCALHOST:4000").halted
    end

    test "allows 127.0.0.1" do
      refute call("127.0.0.1").halted
      refute call("127.0.0.1:8080").halted
    end

    test "allows IPv6 loopback in bracketed form with port" do
      refute call("[::1]").halted
      refute call("[::1]:8080").halted
      refute call("::1").halted
    end

    test "rejects 0.0.0.0 (bind address, not a legitimate client Host)" do
      conn = call("0.0.0.0")

      assert conn.halted
      assert conn.status == 403
    end

    test "rejects non-localhost hosts" do
      conn = call("evil.example")

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body == "Forbidden: Invalid Host header"
    end

    test "rejects non-loopback IPv6 hosts" do
      conn = call("[2001:db8::1]:8080")

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "custom allow-list" do
    test "allows configured hosts, ignoring port and case" do
      opts = [allowed_hosts: ["myhost.local"]]

      refute call("myhost.local", opts).halted
      refute call("MyHost.LOCAL:9999", opts).halted
    end

    test "rejects hosts outside the configured list" do
      opts = [allowed_hosts: ["myhost.local"]]

      assert call("localhost", opts).halted
      assert call("evil.example", opts).halted
    end

    test "matches bracketed IPv6 hosts against unbracketed entries" do
      opts = [allowed_hosts: ["::1"]]

      refute call("[::1]:8080", opts).halted
    end
  end

  test "falls back to conn.host when no Host header is present" do
    # Plug.Test sets conn.host to www.example.com without a host req header.
    conn =
      conn(:get, "/")
      |> DnsRebinding.call(DnsRebinding.init(allowed_hosts: ["www.example.com"]))

    refute conn.halted
  end
end
