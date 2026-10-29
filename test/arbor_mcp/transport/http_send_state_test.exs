defmodule Arbor.MCP.Transport.HTTPSendStateTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.Deadline
  alias Arbor.MCP.Transport.HTTP

  for use_sse <- [true, false] do
    test "public errors stay two-tuples after retirement with use_sse=#{use_sse}" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer A"]
        conn |> Plug.Conn.put_resp_header("www-authenticate", "Basic") |> Plug.Conn.resp(401, "")
      end)

      {:ok, state} =
        HTTP.connect(
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: unquote(use_sse),
          auth_provider: {Arbor.MCP.Authorization.Provider.Static, token: "A"}
        )

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      assert {:error, :unauthorized} = HTTP.send_message(body, state)
      assert {:error, :unauthorized, latest} = HTTP.send_message_with_state(body, state)
      assert latest.access_token == nil
      assert latest.rejected_generation == latest.credential_generation
      assert latest.rejected_generation > 0
    end
  end

  test "an expired deadline keeps the public two-tuple and internal state" do
    {:ok, state} = HTTP.connect(url: "http://127.0.0.1:1/mcp", use_sse: false)
    state = Deadline.put_on_transport(HTTP, state, Deadline.after_ms(0))
    assert {:error, reason} = HTTP.send_message("{}", state)
    assert {:error, ^reason, ^state} = HTTP.send_message_with_state("{}", state)
  end
end
