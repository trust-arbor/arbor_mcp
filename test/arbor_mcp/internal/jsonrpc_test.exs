defmodule Arbor.RPC.JSONRPCTest do
  use ExUnit.Case, async: true

  alias Arbor.RPC.JSONRPC

  test "builds requests, notifications, responses, and errors" do
    assert JSONRPC.request("tools/list", %{}, 1) == %{
             "jsonrpc" => "2.0",
             "method" => "tools/list",
             "params" => %{},
             "id" => 1
           }

    assert JSONRPC.notification("initialized") == %{
             "jsonrpc" => "2.0",
             "method" => "initialized",
             "params" => %{}
           }

    assert JSONRPC.response("abc", %{"ok" => true}) == %{
             "jsonrpc" => "2.0",
             "id" => "abc",
             "result" => %{"ok" => true}
           }

    assert JSONRPC.error(nil, -32_600, "Invalid", false) == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_600, "message" => "Invalid", "data" => false}
           }
  end

  test "parses unvalidated JSON-RPC frames" do
    assert JSONRPC.parse_unvalidated(%{
             "jsonrpc" => "2.0",
             "method" => "ping",
             "params" => %{},
             "id" => 1
           }) == {:request, "ping", %{}, 1}

    assert JSONRPC.parse_unvalidated(~s({"jsonrpc":"2.0","result":{},"id":"req"})) ==
             {:result, %{}, "req"}

    assert JSONRPC.parse_unvalidated([%{"jsonrpc" => "2.0"}]) ==
             {:batch, [%{"jsonrpc" => "2.0"}]}

    assert JSONRPC.parse_unvalidated(%{"method" => "ping"}) == {:error, :invalid_message}
  end
end
