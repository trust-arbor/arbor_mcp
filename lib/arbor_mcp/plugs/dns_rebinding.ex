defmodule Arbor.MCP.Plugs.DnsRebinding do
  @moduledoc """
  Plug for DNS rebinding protection.

  Validates that the request `Host` header is in an allow-list of expected
  hostnames, rejecting requests whose Host points anywhere else. This
  prevents DNS rebinding attacks where a malicious website resolves its own
  domain to a loopback address so the victim's browser sends requests to a
  local MCP server.

  Ports are ignored when comparing hosts, and bracketed IPv6 forms such as
  `"[::1]:8080"` match both `"[::1]"` and `"::1"` allow-list entries.

  By default only localhost names are allowed. `"0.0.0.0"` is deliberately
  not in the defaults: it is a bind address, not a name legitimate clients
  send in a Host header.

  ## Usage

      plug Arbor.MCP.Plugs.DnsRebinding

  Or with custom allowed hosts:

      plug Arbor.MCP.Plugs.DnsRebinding, allowed_hosts: ["localhost", "myhost.local"]

  """

  @behaviour Plug
  import Plug.Conn

  alias Arbor.MCP.HttpPlug.Core

  @default_allowed_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  @impl true
  def init(opts) do
    %{
      allowed_hosts:
        opts
        |> Keyword.get(:allowed_hosts, @default_allowed_hosts)
        |> Enum.map(&String.downcase/1)
    }
  end

  @impl true
  def call(conn, opts) do
    host =
      conn
      |> get_req_header("host")
      |> List.first(conn.host)

    if Core.host_allowed?(host, opts.allowed_hosts) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Forbidden: Invalid Host header")
      |> halt()
    end
  end
end
