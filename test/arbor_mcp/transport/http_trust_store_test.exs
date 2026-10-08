defmodule Arbor.MCP.Transport.HTTPTrustStoreTest do
  # Sets :arbor_mcp application env, so it cannot run concurrently with others.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Transport.HTTP

  setup do
    previous = Application.fetch_env(:arbor_mcp, :cacerts)
    key = {__MODULE__, make_ref()}
    Application.put_env(:arbor_mcp, :cacerts, loader: fn -> [] end, cache_key: key)

    on_exit(fn ->
      :persistent_term.erase(key)

      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :cacerts, value)
        :error -> Application.delete_env(:arbor_mcp, :cacerts)
      end
    end)
  end

  test "an HTTPS request fails closed with an error when the trust store is unavailable" do
    {:ok, state} = HTTP.connect(url: "https://127.0.0.1:1", endpoint: "/mcp", use_sse: false)
    message = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    capture_log(fn ->
      assert HTTP.send_message(message, state) ==
               {:error, {:trust_store_unavailable, :no_certificates}}
    end)
  end
end
