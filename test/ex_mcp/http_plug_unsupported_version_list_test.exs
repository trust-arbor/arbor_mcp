defmodule ExMCP.HttpPlugUnsupportedVersionListTest do
  # An unsupported-version error (-32022) lists exactly the revisions the
  # mount accepts, from the mode it was configured with, in its preference
  # order — not every revision the library knows. A legacy-only mount that
  # advertised 2026-07-28, or a modern-only mount that advertised the legacy
  # dates, told clients to retry a version the mount rejects (2.x e5b9470,
  # PR #159; the server-side RequestContext list was already mode-aware).
  use ExUnit.Case, async: true

  alias ExMCP.HttpPlug
  alias ExMCP.Internal.VersionRegistry

  @unknown "2030-07-28"

  test "a legacy_only mount lists only the legacy revisions" do
    conn = request(protocol_mode: :legacy_only)

    assert %{"error" => %{"code" => -32022, "data" => data}} = Jason.decode!(conn.resp_body)
    assert data["supported"] == VersionRegistry.supported_versions(:legacy_only)
    refute "2026-07-28" in data["supported"]
    assert data["requested"] == @unknown
  end

  test "a modern_only mount lists only the modern revisions" do
    conn = request(protocol_mode: :modern_only)

    assert %{"error" => %{"code" => -32022, "data" => data}} = Jason.decode!(conn.resp_body)
    assert data["supported"] == VersionRegistry.supported_versions(:modern_only)
    refute "2025-11-25" in data["supported"]
  end

  test "a mount without a mode accepts both eras, in preference order" do
    conn = request([])

    assert %{"error" => %{"code" => -32022, "data" => data}} = Jason.decode!(conn.resp_body)

    assert data["supported"] ==
             VersionRegistry.supported_versions(VersionRegistry.protocol_mode())

    assert "2026-07-28" in data["supported"]
    assert "2025-11-25" in data["supported"]
  end

  defp request(plug_opts) do
    opts = HttpPlug.init(Keyword.merge([handler: NoopHandler], plug_opts))

    Plug.Test.conn(:post, "/mcp", Jason.encode!(modern_request()))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("mcp-protocol-version", @unknown)
    |> Plug.Conn.put_req_header("mcp-method", "tools/list")
    |> HttpPlug.call(opts)
  end

  defp modern_request do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => @unknown}
      }
    }
  end
end

defmodule NoopHandler do
  @moduledoc false
  use ExMCP.Server.Handler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}
end
