defmodule Arbor.MCP.Security.TokenHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Security.TokenHandler

  describe "exact trusted origins" do
    test "bind scheme, normalized host, and effective port" do
      config = %{trusted_origins: ["https://API.example.com:443"]}

      assert :internal = TokenHandler.classify_url("https://api.example.com/path", config)
      assert :external = TokenHandler.classify_url("http://api.example.com/path", config)
      assert :external = TokenHandler.classify_url("https://api.example.com:8443/path", config)
    end

    test "rejects host-only strings in the exact origin list" do
      assert :external =
               TokenHandler.classify_url("https://api.example.com", ["api.example.com"])

      refute TokenHandler.valid_trusted_origin?("api.example.com")
    end

    test "fails closed for userinfo, fragments, and unsupported schemes" do
      config = %{trusted_origins: ["https://api.example.com"]}

      assert :external =
               TokenHandler.classify_url("https://user@api.example.com/path", config)

      assert :external =
               TokenHandler.classify_url("https://api.example.com/path#fragment", config)

      assert :external = TokenHandler.classify_url("ftp://api.example.com/path", config)
    end

    test "canonicalizes IPv6 and default ports" do
      assert {:ok, "https://[::1]"} = TokenHandler.extract_origin("https://[::1]:443/path")

      assert :internal =
               TokenHandler.classify_url("https://[::1]/path", %{
                 trusted_origins: ["https://[::1]:443"]
               })
    end
  end

  describe "explicit broad host trust" do
    test "host entries deliberately span schemes and ports" do
      config = %{trusted_hosts: ["api.example.com"]}

      assert :internal = TokenHandler.classify_url("https://api.example.com", config)
      assert :internal = TokenHandler.classify_url("http://api.example.com:8080", config)
    end

    test "wildcards match subdomains but never the apex" do
      config = %{trusted_hosts: ["*.example.com"]}

      assert :internal = TokenHandler.classify_url("https://a.example.com", config)
      assert :external = TokenHandler.classify_url("https://example.com", config)
    end
  end

  test "credentials are stripped when only scheme or port differs" do
    headers = [{"Authorization", "Bearer secret"}, {"Accept", "application/json"}]
    config = %{trusted_origins: ["https://api.example.com"]}

    assert {:ok, [{"Accept", "application/json"}]} =
             TokenHandler.check_token_passthrough(
               "http://api.example.com:8080/path",
               headers,
               config
             )
  end
end
