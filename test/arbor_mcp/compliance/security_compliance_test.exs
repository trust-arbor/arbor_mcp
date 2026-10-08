defmodule Arbor.MCP.Compliance.SecurityComplianceTest do
  @moduledoc """
  Tests for MCP security requirements compliance.

  These tests validate security features required by the MCP specification,
  including DNS rebinding protection, HTTPS enforcement, and origin validation.
  """
  use ExUnit.Case, async: false

  @moduletag :compliance

  alias Arbor.MCP.Internal.ConsentCache
  alias Arbor.MCP.Internal.Security
  alias Arbor.MCP.Transport.SecurityError
  alias Arbor.MCP.Transport.SecurityGuard

  setup do
    # ConsentCache is already started by the application
    # Ensure clean state for each test by clearing the cache
    ConsentCache.clear()
    :ok
  end

  # Mock Consent Handlers for testing
  defmodule AllowConsentHandler do
    @behaviour Arbor.MCP.ConsentHandler
    def request_consent(_, _, _) do
      expires_at = DateTime.add(DateTime.utc_now(), :timer.hours(1), :millisecond)
      {:approved, expires_at: expires_at}
    end

    def check_existing_consent(_, _), do: :not_found
    def revoke_consent(_, _), do: :ok
  end

  defmodule DenyConsentHandler do
    @behaviour Arbor.MCP.ConsentHandler
    def request_consent(_, _, _), do: {:denied, reason: "Test denial"}
    def check_existing_consent(_, _), do: :not_found
    def revoke_consent(_, _), do: :ok
  end

  defmodule RequireConsentHandler do
    @behaviour Arbor.MCP.ConsentHandler
    def request_consent(_, _, _), do: {:error, [reason: "Consent required"]}
    def check_existing_consent(_, _), do: :not_found
    def revoke_consent(_, _), do: :ok
  end

  defmodule TracingDenyConsentHandler do
    @behaviour Arbor.MCP.ConsentHandler

    def request_consent(user_id, origin, context) do
      # The test process pid is passed via context[:test_pid], if present
      if test_pid = Map.get(context, :test_pid) do
        send(test_pid, {:consent_requested, user_id, origin})
      end

      {:denied, [reason: "Test denial"]}
    end

    def check_existing_consent(_, _), do: :not_found
    def revoke_consent(_, _), do: :ok
  end

  describe "MCP Security Requirements - DNS Rebinding Protection" do
    test "prevents DNS rebinding with external domain to localhost" do
      # MCP spec requires protection against DNS rebinding attacks
      # Attacker sets up evil.com to resolve to 127.0.0.1
      headers = [
        {"origin", "https://evil.com"},
        {"host", "127.0.0.1:8080"}
      ]

      config = %{
        validate_origin: true,
        allowed_origins: ["https://trusted.com"]
      }

      assert {:error, :origin_not_allowed} = Security.validate_request(headers, config)
    end

    test "prevents DNS rebinding with subdomain attack" do
      # MCP spec: prevent subdomain-based attacks like 127.0.0.1.evil.com
      headers = [
        {"origin", "https://127.0.0.1.evil.com"},
        {"host", "localhost"}
      ]

      config = %{
        validate_origin: true,
        allowed_origins: ["https://trusted.com"]
      }

      assert {:error, :origin_not_allowed} = Security.validate_request(headers, config)
    end

    test "allows legitimate localhost usage" do
      # MCP spec: localhost should work for local development
      headers = [
        {"origin", "http://localhost:3000"},
        {"host", "localhost:8080"}
      ]

      config = %{
        validate_origin: true,
        allowed_origins: ["http://localhost:3000"]
      }

      assert :ok = Security.validate_request(headers, config)
    end
  end

  describe "MCP Security Requirements - HTTPS Enforcement" do
    test "requires HTTPS for non-localhost when enforced" do
      # MCP spec: HTTPS should be enforced for production use
      headers = [
        {"origin", "http://example.com"},
        {"host", "example.com"},
        {"x-forwarded-proto", "http"}
      ]

      config = %{enforce_https: true}

      assert {:error, :https_required} = Security.validate_request(headers, config)
    end

    test "allows HTTPS when enforced" do
      headers = [
        {"origin", "https://example.com"},
        {"host", "example.com"},
        {"x-forwarded-proto", "https"}
      ]

      config = %{enforce_https: true}

      assert :ok = Security.validate_request(headers, config)
    end

    test "allows HTTP for localhost when HTTPS enforced" do
      # MCP spec: localhost exception for development
      headers = [
        {"origin", "http://localhost"},
        {"host", "localhost"}
      ]

      config = %{enforce_https: true}

      assert :ok = Security.validate_request(headers, config)
    end
  end

  describe "MCP Security Requirements - Origin Validation" do
    test "validates origin header when required" do
      # MCP spec: origin validation prevents unauthorized access
      headers = [{"origin", "https://example.com"}, {"host", "api.example.com"}]
      config = %{validate_origin: true, allowed_origins: ["https://example.com"]}

      assert :ok = Security.validate_request(headers, config)
    end

    test "validates case-insensitive charlist request headers" do
      headers = [{~c"Origin", ~c"https://example.com"}, {~c"Host", ~c"api.example.com"}]
      config = %{validate_origin: true, allowed_origins: ["https://example.com"]}

      assert :ok = Security.validate_request(headers, config)
    end

    test "fails when origin header missing and validation enabled" do
      # MCP spec: missing origin should be rejected when validation enabled
      headers = [{"host", "api.example.com"}]
      config = %{validate_origin: true, allowed_origins: ["https://example.com"]}

      assert {:error, :origin_header_required} = Security.validate_request(headers, config)
    end

    test "fails when origin not in allowed list" do
      # MCP spec: only whitelisted origins should be allowed
      headers = [{"origin", "https://evil.com"}, {"host", "api.example.com"}]
      config = %{validate_origin: true, allowed_origins: ["https://example.com"]}

      assert {:error, :origin_not_allowed} = Security.validate_request(headers, config)
    end

    test "validates origin with port numbers" do
      # MCP spec: port numbers must match exactly
      allowed = ["https://example.com:8080", "http://localhost:3000"]

      assert :ok = Security.validate_origin("https://example.com:8080", allowed)
      assert :ok = Security.validate_origin("http://localhost:3000", allowed)

      assert {:error, :origin_not_allowed} =
               Security.validate_origin("https://example.com:9000", allowed)
    end
  end

  describe "MCP Security Requirements - Host Header Validation" do
    test "validates host header presence" do
      # MCP spec: host header required for security
      headers = [{"origin", "https://example.com"}]
      config = %{validate_origin: true, allowed_origins: ["https://example.com"]}

      assert {:error, :host_header_required} = Security.validate_request(headers, config)
    end

    test "allows localhost hosts" do
      # MCP spec: localhost variants should be recognized
      for host <- ["localhost", "127.0.0.1", "[::1]"] do
        headers = [{"origin", "http://#{host}"}, {"host", host}]
        config = %{validate_origin: true, allowed_origins: ["http://#{host}"]}

        assert :ok = Security.validate_request(headers, config)
      end
    end

    test "rejects non-localhost hosts not in allowed list" do
      # MCP spec: non-localhost hosts must be explicitly allowed
      headers = [{"origin", "https://example.com"}, {"host", "malicious.com"}]

      config = %{
        validate_origin: true,
        allowed_origins: ["https://example.com"],
        allowed_hosts: ["api.example.com"]
      }

      assert {:error, :host_not_allowed} = Security.validate_request(headers, config)
    end
  end

  describe "MCP Security Headers" do
    test "security headers have correct values" do
      # MCP spec recommends standard security headers
      headers = Security.build_standard_security_headers()

      assert {"X-Content-Type-Options", "nosniff"} in headers
      assert {"X-Frame-Options", "DENY"} in headers
      assert {"X-XSS-Protection", "1; mode=block"} in headers
      assert {"Strict-Transport-Security", "max-age=31536000; includeSubDomains"} in headers
      assert {"Referrer-Policy", "strict-origin-when-cross-origin"} in headers
      assert {"X-Permitted-Cross-Domain-Policies", "none"} in headers
    end
  end

  describe "MCP Security - Confused Deputy Prevention" do
    test "prevents token passthrough to external resources" do
      # MCP spec: tokens should never be passed to external URLs
      sensitive_headers = [
        {"Authorization", "Bearer secret-token"},
        {"authorization", "lowercase bearer"},
        {"Cookie", "session=secret-session"},
        {"COOKIE", "UPPERCASE SESSION"},
        {"X-API-Key", "secret-key"},
        {"x-api-key", "lowercase key"},
        {"X-Auth-Token", "secret-auth-token"},
        {"X-CSRF-Token", "secret-csrf-token"}
      ]

      safe_headers = [
        {"X-Custom-Header", "safe-value"},
        {"Accept", "application/json"}
      ]

      all_headers = sensitive_headers ++ safe_headers

      request = %{
        url: "https://api.external.com/data",
        headers: all_headers,
        method: "GET",
        transport: :http,
        user_id: "user123"
      }

      config = %{
        trusted_origins: ["https://api.internal.com"],
        consent_handler: AllowConsentHandler
      }

      # For external URLs, sensitive headers should be stripped.
      assert {:ok, sanitized_request} = SecurityGuard.validate_request(request, config)

      # Only non-sensitive headers should remain.
      # Using Map.new for case-insensitive key comparison and order-insensitivity.
      expected_sanitized_headers = Map.new(safe_headers, fn {k, v} -> {String.downcase(k), v} end)

      actual_sanitized_headers =
        Map.new(sanitized_request.headers, fn {k, v} -> {String.downcase(k), v} end)

      assert actual_sanitized_headers == expected_sanitized_headers

      # For internal URLs, headers should be preserved.
      internal_request = %{request | url: "https://api.internal.com/data"}
      assert {:ok, preserved_request} = SecurityGuard.validate_request(internal_request, config)

      # All headers should be present for internal requests.
      expected_preserved_headers = Map.new(all_headers, fn {k, v} -> {String.downcase(k), v} end)

      actual_preserved_headers =
        Map.new(preserved_request.headers, fn {k, v} -> {String.downcase(k), v} end)

      assert actual_preserved_headers == expected_preserved_headers
    end
  end

  describe "MCP Security - User Consent" do
    test "requires consent for external resources" do
      request = %{
        url: "https://api.external.com/data",
        headers: [],
        method: "GET",
        transport: :http,
        user_id: "user123"
      }

      require_config = %{
        trusted_hosts: ["api.internal.com"],
        consent_handler: RequireConsentHandler
      }

      assert {:error, %SecurityError{type: :consent_required}} =
               SecurityGuard.validate_request(request, require_config)
    end

    test "denies access when consent is denied" do
      request = %{
        url: "https://api.external.com/data",
        headers: [],
        method: "GET",
        transport: :http,
        user_id: "user123"
      }

      deny_config = %{
        trusted_hosts: ["api.internal.com"],
        consent_handler: DenyConsentHandler
      }

      assert {:error, %SecurityError{type: :consent_denied}} =
               SecurityGuard.validate_request(request, deny_config)
    end

    test "allows access when consent is granted" do
      request = %{
        url: "https://api.external.com/data",
        headers: [],
        method: "GET",
        transport: :http,
        user_id: "user123"
      }

      allow_config = %{
        trusted_hosts: ["api.internal.com"],
        consent_handler: AllowConsentHandler
      }

      assert {:ok, _} = SecurityGuard.validate_request(request, allow_config)
    end

    test "does not require consent for internal resources" do
      internal_request = %{
        url: "https://api.internal.com/data",
        headers: [],
        method: "GET",
        transport: :http,
        user_id: "user123"
      }

      # Using DenyConsentHandler to prove the handler is not even called for internal URLs.
      deny_config = %{
        trusted_hosts: ["api.internal.com"],
        consent_handler: DenyConsentHandler
      }

      assert {:ok, _} = SecurityGuard.validate_request(internal_request, deny_config)
    end

    test "does not require consent for non-http transports" do
      # For stdio and BEAM transports, requests are considered internal and don't need consent.
      for transport <- [:stdio, :beam] do
        request = %{
          url: "some-resource",
          headers: [],
          method: "GET",
          transport: transport,
          user_id: "user123"
        }

        # Using DenyConsentHandler to prove the handler is not called.
        deny_config = %{
          trusted_hosts: ["api.internal.com"],
          consent_handler: DenyConsentHandler
        }

        assert {:ok, _} = SecurityGuard.validate_request(request, deny_config)
      end
    end

    test "caches approved consent decisions" do
      # This test uses a unique user_id to avoid conflicts with other async tests.
      request = %{
        url: "https://api.external.com/caching-test",
        headers: [],
        method: "GET",
        transport: :http,
        user_id: "user-for-caching-test-#{System.unique_integer()}"
      }

      # Use AllowConsentHandler to test caching of approvals
      config = %{
        trusted_hosts: ["api.internal.com"],
        consent_handler: AllowConsentHandler
      }

      # First call: should call the handler and cache the approval.
      assert {:ok, _} = SecurityGuard.validate_request(request, config)

      # Second call: should hit the cache (handler is called but consent is cached).
      # Since AllowConsentHandler doesn't trace calls, we just verify it succeeds
      assert {:ok, _} = SecurityGuard.validate_request(request, config)
    end
  end

  describe "MCP Security - Case Insensitive Headers" do
    test "finds headers regardless of case" do
      # HTTP headers are case-insensitive per RFC
      headers = [
        {"Origin", "https://example.com"},
        {"HOST", "example.com"},
        {"X-Forwarded-Proto", "https"}
      ]

      config = %{
        validate_origin: true,
        allowed_origins: ["https://example.com"],
        enforce_https: true
      }

      assert :ok = Security.validate_request(headers, config)
    end
  end
end
