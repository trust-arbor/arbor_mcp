defmodule Arbor.MCP.Transport.HTTPNotFoundTest do
  @moduledoc """
  The 2026-07-28 Streamable HTTP transport answers a method the server
  doesn't implement with 404 and a JSON-RPC `-32601` error, whose body tells
  it apart from a server without the endpoint. The client takes that error
  as the request's answer, as it would in a 200. Other 404s stay HTTP errors,
  with legacy session requests classified as session expiry.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.HTTP

  @request Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "prompts/list"})

  @not_found %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "error" => %{"code" => -32601, "message" => "Method not found: prompts/list"}
  }

  defp transport(bypass, era) do
    {:ok, transport} =
      HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)

    version = if era == :modern, do: "2026-07-28", else: "2025-06-18"
    HTTP.settle_protocol_era(transport, era, version)
  end

  defp respond_404(body) do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, body)
    end)

    bypass
  end

  test "a modern 404 with the request's JSON-RPC error is that error" do
    bypass = respond_404(Jason.encode!(@not_found))

    assert {:ok, _state, response} = HTTP.send_authenticated(@request, transport(bypass, :modern))
    assert Jason.decode!(response) == @not_found
  end

  test "any other modern 404 stays an HTTP error" do
    for body <- [
          "",
          "Not Found",
          Jason.encode!(%{"error" => "Not found"}),
          Jason.encode!(%{@not_found | "id" => 2}),
          Jason.encode!(Map.put(@not_found, "result", %{}))
        ] do
      bypass = respond_404(body)

      assert {:error, {:http_error, 404, ^body}, _state} =
               HTTP.send_authenticated(@request, transport(bypass, :modern))
    end
  end

  test "a legacy 404 stays an HTTP error whatever its body" do
    body = Jason.encode!(@not_found)
    bypass = respond_404(body)

    assert {:error, {:http_error, 404, ^body}, _state} =
             HTTP.send_authenticated(@request, transport(bypass, :legacy))
  end

  test "a legacy session 404 ends the session even with a matching JSON-RPC error" do
    body = Jason.encode!(@not_found)
    bypass = respond_404(body)
    transport = %{transport(bypass, :legacy) | session_id: "ended-session"}

    assert {:error, {:session_expired, {:http_error, 404, ^body}}, _state} =
             HTTP.send_authenticated(@request, transport)
  end
end
