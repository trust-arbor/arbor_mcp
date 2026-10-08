defmodule Arbor.MCP.Content.SchemaHTTPClientTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Content.SchemaHTTPClient

  test "connects to the approved IP while preserving the URI host and request target" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/schema.json", fn conn ->
      assert Plug.Conn.get_req_header(conn, "host") == ["schema-host.invalid:#{bypass.port}"]
      assert conn.query_string == "version=1"

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/schema+json")
      |> Plug.Conn.resp(200, ~s({"type":"string"}))
    end)

    uri = URI.parse("http://schema-host.invalid:#{bypass.port}/schema.json?version=1")

    assert {:ok, response} =
             SchemaHTTPClient.get(uri, {127, 0, 0, 1}, client_options(max_response_bytes: 100))

    assert response.status == 200
    assert response.body == ~s({"type":"string"})
    assert {"content-type", "application/schema+json"} in response.headers
  end

  test "stops an oversized streamed response" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/large.json", fn conn ->
      Plug.Conn.resp(conn, 200, String.duplicate("x", 1_024))
    end)

    uri = URI.parse("http://schema-host.invalid:#{bypass.port}/large.json")

    assert {:error, :response_too_large} =
             SchemaHTTPClient.get(uri, {127, 0, 0, 1}, client_options(max_response_bytes: 32))
  end

  defp client_options(overrides) do
    Keyword.merge(
      [connect_timeout_ms: 1_000, request_timeout_ms: 1_000, max_response_bytes: 262_144],
      overrides
    )
  end
end
