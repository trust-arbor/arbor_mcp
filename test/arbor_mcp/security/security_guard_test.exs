defmodule Arbor.MCP.Security.SecurityGuardTest do
  @moduledoc """
  Tests the outbound trust boundary enforced by `Arbor.MCP.Transport.SecurityGuard`.

  The default configuration is fail-closed: a server that is not on localhost
  has its credential headers stripped and is then denied. These tests pin down
  that behaviour, the `:trusted_origins` escape from it, the two enforcement
  switches, and the actionable log message that tells an operator what to set.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Internal.ConsentCache
  alias Arbor.MCP.Transport.SecurityError
  alias Arbor.MCP.Transport.SecurityGuard

  @external_url "https://mcp.example.com/mcp"
  @credentials [{"Authorization", "Bearer s3cret"}, {"Cookie", "session=abc"}]
  @safe_headers [{"Content-Type", "application/json"}]

  defmodule AllowHandler do
    @moduledoc false
    @behaviour Arbor.MCP.ConsentHandler

    @impl Arbor.MCP.ConsentHandler
    def request_consent(_user_id, _origin, _context), do: {:ok, {:ttl, 600}}

    @impl Arbor.MCP.ConsentHandler
    def check_existing_consent(_user_id, _origin), do: {:not_found}

    @impl Arbor.MCP.ConsentHandler
    def revoke_consent(_user_id, _origin), do: :ok
  end

  setup do
    ConsentCache.clear()
    :ok
  end

  defp request(headers \\ @credentials ++ @safe_headers) do
    %{
      url: @external_url,
      headers: headers,
      method: "POST",
      transport: :http,
      user_id: "guard-test-#{System.unique_integer([:positive])}"
    }
  end

  defp header_names(headers) do
    headers |> Enum.map(fn {name, _value} -> String.downcase(name) end) |> Enum.sort()
  end

  describe "default configuration" do
    test "blocks a non-localhost server" do
      # Nothing configured: loopback-only trusted origins + Deny handler.
      capture_log(fn ->
        assert {:error, %SecurityError{type: :consent_denied}} =
                 SecurityGuard.validate_request(request(), %{})
      end)
    end

    test "names the exact setting to add when it blocks" do
      log =
        capture_log(fn ->
          SecurityGuard.validate_request(request(), %{})
        end)

      assert log =~ "trusted_origins"
      refute log =~ "https://mcp.example.com"
      # The remediation must never quote the credentials it stripped.
      refute log =~ "s3cret"
    end

    test "warns when it removes credential headers" do
      log =
        capture_log(fn ->
          SecurityGuard.validate_request(request(), %{consent_handler: AllowHandler})
        end)

      assert log =~ "removed credential headers"
      refute log =~ "s3cret"
    end

    test "stays quiet when there are no credentials to remove" do
      config = %{consent_handler: AllowHandler}

      log =
        capture_log(fn ->
          SecurityGuard.validate_request(request(@safe_headers), config)
        end)

      refute log =~ "removed credential headers"
    end
  end

  describe "trusted origins" do
    test "an explicitly trusted origin is exempt from stripping and consent" do
      # Deny handler stays in place: a trusted origin must not consult it.
      config = %{trusted_origins: ["https://mcp.example.com"]}

      assert {:ok, sanitized} = SecurityGuard.validate_request(request(), config)
      assert header_names(sanitized.headers) == ["authorization", "content-type", "cookie"]
    end

    test "an explicitly broad trusted host matches regardless of scheme" do
      config = %{trusted_hosts: ["mcp.example.com"]}
      assert {:ok, sanitized} = SecurityGuard.validate_request(request(), config)
      assert length(sanitized.headers) == 3
    end

    test "a wildcard entry matches subdomains" do
      config = %{trusted_hosts: ["*.example.com"]}
      assert {:ok, sanitized} = SecurityGuard.validate_request(request(), config)
      assert length(sanitized.headers) == 3
    end

    test "an unrelated trusted origin does not help" do
      config = %{trusted_origins: ["https://other.example.org"]}

      capture_log(fn ->
        assert {:error, %SecurityError{type: :consent_denied}} =
                 SecurityGuard.validate_request(request(), config)
      end)
    end
  end

  describe "enforcement switches" do
    test "disabling passthrough prevention forwards credentials" do
      config = %{
        enable_token_passthrough_prevention: false,
        consent_handler: AllowHandler
      }

      assert {:ok, sanitized} = SecurityGuard.validate_request(request(), config)
      assert header_names(sanitized.headers) == ["authorization", "content-type", "cookie"]
    end

    test "disabling consent validation skips the consent handler" do
      # The default Deny handler would block this request if it were consulted.
      config = %{enable_user_consent_validation: false}

      capture_log(fn ->
        assert {:ok, sanitized} = SecurityGuard.validate_request(request(), config)
        # Passthrough prevention is independent and still applies.
        assert header_names(sanitized.headers) == ["content-type"]
      end)
    end

    test "both switches default to on" do
      config = SecurityGuard.get_security_config(%{})
      assert config.enable_token_passthrough_prevention == true
      assert config.enable_user_consent_validation == true

      capture_log(fn ->
        assert {:error, %SecurityError{}} = SecurityGuard.validate_request(request(), %{})
      end)
    end
  end
end
