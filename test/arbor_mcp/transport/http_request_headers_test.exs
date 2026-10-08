defmodule Arbor.MCP.Transport.HTTP.RequestHeadersTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Headers
  alias Arbor.MCP.Transport.HTTP.RequestHeaders

  test "modern requests mirror method and name while dropping legacy transport state" do
    state = state()

    headers =
      RequestHeaders.build(
        request("tools/call", %{"name" => "weather", "arguments" => %{}}),
        state
      )

    assert Headers.get(headers, "mcp-protocol-version") == "2026-07-28"
    assert Headers.get(headers, "mcp-method") == "tools/call"
    assert Headers.get(headers, "mcp-name") == "weather"
    assert Headers.get(headers, "authorization") == "Bearer secret"
    refute Headers.get(headers, "mcp-session-id")
    refute Headers.get(headers, "last-event-id")

    assert Enum.count(headers, fn {name, _value} ->
             String.downcase(name) == "mcp-protocol-version"
           end) == 1
  end

  test "forces identity encoding so compressed responses cannot bypass byte limits" do
    configured = %{state() | headers: [{"Accept-Encoding", "gzip"}]}
    headers = RequestHeaders.build(request("tools/list", %{}), configured)

    assert [{"accept-encoding", "identity"}] ==
             Enum.filter(headers, fn {name, _value} ->
               String.downcase(name) == "accept-encoding"
             end)
  end

  test "Mcp-Name uses uri for resources/read and is absent on methods without a name source" do
    resource_headers =
      RequestHeaders.build(request("resources/read", %{"uri" => "file:///safe"}), state())

    assert Headers.get(resource_headers, "mcp-name") == "file:///safe"

    list_headers = RequestHeaders.build(request("tools/list", %{}), state())
    assert Headers.get(list_headers, "mcp-method") == "tools/list"
    refute Headers.get(list_headers, "mcp-name")
  end

  test "encodes unsafe and sentinel-shaped values with the exact Base64 sentinel" do
    assert RequestHeaders.encode_value("plain ASCII") == "plain ASCII"
    assert RequestHeaders.encode_value(42) == "42"
    assert RequestHeaders.encode_value(true) == "true"

    assert RequestHeaders.encode_value("Hello, 世界") ==
             "=?base64?SGVsbG8sIOS4lueVjA==?="

    assert RequestHeaders.encode_value(" padded ") == "=?base64?IHBhZGRlZCA=?="
    assert RequestHeaders.encode_value("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?="

    assert RequestHeaders.encode_value("=?base64?literal?=") ==
             "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="
  end

  test "decodes only values with the complete Base64 sentinel wrapper" do
    assert RequestHeaders.decode_value("=?base64?SGVsbG8=?=") == {:ok, "Hello"}
    assert RequestHeaders.decode_value("=?base64?SGVsbG8=") == {:ok, "=?base64?SGVsbG8="}
    assert RequestHeaders.decode_value("SGVsbG8=?=") == {:ok, "SGVsbG8=?="}

    assert {:error, "Base64 sentinel header value is malformed"} =
             RequestHeaders.decode_value("=?base64?SGVsbG8?=")
  end

  test "legacy requests retain session and resumability headers without modern metadata" do
    state = %{state() | protocol_version: "2025-11-25"}

    headers =
      RequestHeaders.build(
        request("tools/call", %{"name" => "weather"}, "2025-11-25"),
        state
      )

    assert Headers.get(headers, "mcp-protocol-version") == "2025-11-25"
    assert Headers.get(headers, "mcp-session-id") == "legacy-session"
    assert Headers.get(headers, "last-event-id") == "legacy-event"
    refute Headers.get(headers, "mcp-method")
    refute Headers.get(headers, "mcp-name")
  end

  test "validates required mirrored headers and decodes an encoded name" do
    body = Jason.decode!(request("resources/read", %{"uri" => "résumé://one"}))

    headers = [
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "resources/read"},
      {"mcp-name", RequestHeaders.encode_value("résumé://one")}
    ]

    assert :ok = RequestHeaders.validate(headers, body)

    assert {:error, message} =
             RequestHeaders.validate(
               List.keyreplace(headers, "mcp-method", 0, {"mcp-method", "tools/list"}),
               body
             )

    assert message =~ "does not match"
  end

  test "rejects missing, duplicate, unsafe, and malformed sentinel headers" do
    body = Jason.decode!(request("tools/call", %{"name" => "weather", "arguments" => %{}}))

    base = [
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", "tools/call"},
      {"mcp-name", "weather"}
    ]

    assert {:error, _message} = RequestHeaders.validate(tl(base), body)
    assert {:error, _message} = RequestHeaders.validate([hd(base) | base], body)

    assert {:error, _message} =
             RequestHeaders.validate(
               List.keyreplace(base, "mcp-name", 0, {"mcp-name", "line\nbreak"}),
               body
             )

    assert {:error, _message} =
             RequestHeaders.validate(
               List.keyreplace(base, "mcp-name", 0, {"mcp-name", "=?base64?not-valid!?="}),
               body
             )
  end

  test "mirrors cached x-mcp-header arguments and omits absent or null values" do
    state = %{
      state()
      | tool_headers: %{
          "query" => [
            %{header: "Region", path: ["region"], type: "string"},
            %{header: "Limit", path: ["options", "limit"], type: "integer"},
            %{header: "Trace", path: ["trace"], type: "boolean"},
            %{header: "Missing", path: ["missing"], type: "string"},
            %{header: "Null", path: ["null"], type: "string"}
          ]
        }
    }

    body =
      request("tools/call", %{
        "name" => "query",
        "arguments" => %{
          "region" => "us-west1",
          "options" => %{"limit" => 42},
          "trace" => false,
          "null" => nil
        }
      })

    headers = RequestHeaders.build(body, state)
    assert Headers.get(headers, "mcp-param-region") == "us-west1"
    assert Headers.get(headers, "mcp-param-limit") == "42"
    assert Headers.get(headers, "mcp-param-trace") == "false"
    refute Headers.get(headers, "mcp-param-missing")
    refute Headers.get(headers, "mcp-param-null")
  end

  defp state do
    %{
      headers: [
        {"Authorization", "Bearer secret"},
        {"MCP-Protocol-Version", "stale"},
        {"Mcp-Session-Id", "stale-session"}
      ],
      security: nil,
      origin: nil,
      session_id: "legacy-session",
      last_event_id: "legacy-event",
      protocol_version: "2025-11-25",
      tool_headers: %{}
    }
  end

  defp request(method, params, version \\ "2026-07-28") do
    params =
      Map.put(params, "_meta", %{
        "io.modelcontextprotocol/protocolVersion" => version,
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "1"}
      })

    Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
  end
end
