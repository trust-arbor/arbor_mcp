defmodule Arbor.MCP.Plugs.JWKSTest do
  @moduledoc """
  Tests for the JWKS endpoint Plug.

  Verifies correct HTTP responses, JSON format, static and dynamic key serving,
  and empty key handling.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @moduletag :oauth

  alias Arbor.MCP.Plugs.JWKS

  describe "call/2 with static keys" do
    test "returns 200 with application/json content type" do
      opts = JWKS.init(keys: [%{"kty" => "RSA", "n" => "abc", "e" => "AQAB"}])
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "response body is valid JWKS format with keys array" do
      test_key = %{"kty" => "RSA", "n" => "test_n_value", "e" => "AQAB", "kid" => "key-1"}
      opts = JWKS.init(keys: [test_key])
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert is_map(body)
      assert Map.has_key?(body, "keys")
      assert is_list(body["keys"])
      assert length(body["keys"]) == 1

      [key] = body["keys"]
      assert key["kty"] == "RSA"
      assert key["n"] == "test_n_value"
      assert key["e"] == "AQAB"
      assert key["kid"] == "key-1"
    end

    test "serves multiple static keys" do
      keys = [
        %{"kty" => "RSA", "n" => "key1_n", "e" => "AQAB", "kid" => "k1"},
        %{"kty" => "RSA", "n" => "key2_n", "e" => "AQAB", "kid" => "k2"}
      ]

      opts = JWKS.init(keys: keys)
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      assert length(body["keys"]) == 2

      kids = Enum.map(body["keys"], & &1["kid"])
      assert "k1" in kids
      assert "k2" in kids
    end

    test "strips private key material from JWK maps" do
      # Key with private fields that should be stripped
      key_with_private = %{
        "kty" => "RSA",
        "n" => "public_n",
        "e" => "AQAB",
        "d" => "private_d",
        "p" => "private_p",
        "q" => "private_q",
        "dp" => "private_dp",
        "dq" => "private_dq",
        "qi" => "private_qi"
      }

      opts = JWKS.init(keys: [key_with_private])
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      [served_key] = body["keys"]

      # Public fields present
      assert served_key["kty"] == "RSA"
      assert served_key["n"] == "public_n"
      assert served_key["e"] == "AQAB"

      # Private fields stripped
      refute Map.has_key?(served_key, "d")
      refute Map.has_key?(served_key, "p")
      refute Map.has_key?(served_key, "q")
      refute Map.has_key?(served_key, "dp")
      refute Map.has_key?(served_key, "dq")
      refute Map.has_key?(served_key, "qi")
    end

    test "includes cache-control header" do
      opts = JWKS.init(keys: [%{"kty" => "RSA", "n" => "n", "e" => "e"}])
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      cache_control = get_resp_header(conn, "cache-control") |> hd()
      assert cache_control =~ "public"
      assert cache_control =~ "max-age=3600"
    end
  end

  describe "call/2 with dynamic keys (keys_fn)" do
    test "calls the key function to get keys" do
      test_pid = self()

      keys_fn = fn ->
        send(test_pid, :keys_fn_called)
        [%{"kty" => "RSA", "n" => "dynamic_n", "e" => "AQAB"}]
      end

      opts = JWKS.init(keys_fn: keys_fn)
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      assert_received :keys_fn_called
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      [key] = body["keys"]
      assert key["n"] == "dynamic_n"
    end

    test "keys_fn takes precedence over static keys" do
      keys_fn = fn ->
        [%{"kty" => "RSA", "n" => "from_fn", "e" => "AQAB"}]
      end

      opts =
        JWKS.init(
          keys: [%{"kty" => "RSA", "n" => "from_static", "e" => "AQAB"}],
          keys_fn: keys_fn
        )

      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      body = Jason.decode!(conn.resp_body)
      [key] = body["keys"]
      assert key["n"] == "from_fn"
    end

    test "handles keys_fn errors gracefully" do
      keys_fn = fn ->
        raise "key retrieval failed"
      end

      opts = JWKS.init(keys_fn: keys_fn)
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      assert conn.status == 500

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "server_error"
    end
  end

  describe "call/2 with empty keys" do
    test "returns {\"keys\": []} for empty key list" do
      opts = JWKS.init(keys: [])
      conn = conn(:get, "/.well-known/jwks.json")

      conn = JWKS.call(conn, opts)

      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body == %{"keys" => []}
    end
  end

  describe "init/1 validation" do
    test "raises when neither keys nor keys_fn is provided" do
      assert_raise ArgumentError, ~r/requires either :keys or :keys_fn/, fn ->
        JWKS.init([])
      end
    end
  end
end
