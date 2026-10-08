defmodule Arbor.MCP.Transport.HTTPConnectionTrustTest do
  @moduledoc """
  An HTTP connection's own `security: %{trusted_origins: [...]}` is honored by
  the SecurityGuard check on that connection's requests, in addition to the
  VM-wide `config :arbor_mcp, :security`, without trusting the origin for any
  other connection.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.HTTP

  @origin "https://mcp.example.com"
  @credential {"authorization", "Bearer secret"}

  test "a connection's trusted origin keeps its credentials and needs no consent" do
    state = connect(security: %{trusted_origins: [@origin]})

    assert {:ok, headers} =
             HTTP.sanitize_http_request("POST", @origin <> "/mcp", [@credential], state)

    assert @credential in headers
  end

  test "the trust is exact: another port, scheme or host is still refused" do
    state = connect(security: %{trusted_origins: [@origin]})

    for url <- [
          "https://mcp.example.com:8443/mcp",
          "http://mcp.example.com/mcp",
          "https://evil.example.com/mcp"
        ] do
      assert {:error, _refused} = HTTP.sanitize_http_request("POST", url, [@credential], state),
             url
    end
  end

  test "the trust belongs to that connection only" do
    _trusting = connect(security: %{trusted_origins: [@origin]})
    other = connect([])

    assert {:error, _refused} =
             HTTP.sanitize_http_request("POST", @origin <> "/mcp", [@credential], other)
  end

  test "an invalid trusted origin is refused at connect" do
    for origins <- [["mcp.example.com"], ["https://mcp.example.com/path"], "https://x.example"] do
      assert {:error, _invalid} =
               HTTP.connect(url: @origin <> "/mcp", security: %{trusted_origins: origins}),
             inspect(origins)
    end
  end

  defp connect(opts) do
    {:ok, state} = HTTP.connect([url: @origin <> "/mcp", use_sse: false] ++ opts)
    state
  end
end
