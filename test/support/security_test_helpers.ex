defmodule Arbor.MCP.Test.Support.SecurityTestHelpers do
  @moduledoc """
  Provides test utilities for security-related scenarios in Arbor.MCP.

  This module includes helpers for:
  - Generating various types of tokens and credentials.
  - Creating different URL patterns for testing access control.
  - Building mock security requests for different transports (HTTP, stdio, BEAM).
  - Asserting security validation outcomes.
  - Generating test scenarios for common security checks like token passthrough.
  """

  import ExUnit.Assertions

  @doc """
  Generates a random string suitable for a Bearer token.
  """
  def generate_bearer_token, do: "Bearer " <> (:crypto.strong_rand_bytes(32) |> Base.encode64())

  @doc """
  Generates a random string suitable for an API key.
  """
  def generate_api_key,
    do: "sk-" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))

  @doc """
  Generates a random string suitable for an OAuth token.
  """
  def generate_oauth_token,
    do: "oauth-" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

  @doc """
  Generates a UUID v4 string without Ecto dependency.
  """
  def generate_uuid do
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = :crypto.strong_rand_bytes(16)
    # Set version 4 bits
    u2_v4 = Bitwise.bor(Bitwise.band(u2, 0x0FFF), 0x4000)
    # Set variant bits (10xx)
    u3_var = Bitwise.bor(Bitwise.band(u3, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0B-~4.16.0B-~4.16.0B-~4.16.0B-~12.16.0B", [u0, u1, u2_v4, u3_var, u4])
    |> :erlang.iolist_to_binary()
    |> String.downcase()
  end

  @doc """
  Generates a random string suitable for a session cookie.
  """
  def generate_cookie(name \\ "session_id"),
    do: "#{name}=#{:crypto.strong_rand_bytes(16) |> Base.encode64()}"

  @doc """
  Generates a URL for a hypothetical internal service.
  """
  def internal_url(path \\ "/api/v1/data"), do: "https://internal.service.local#{path}"

  @doc """
  Generates a URL for an external service.
  """
  def external_url(path \\ "/"), do: "https://example.com#{path}"

  @doc """
  Generates a localhost URL.
  """
  def localhost_url(port \\ 8080, path \\ "/"), do: "http://localhost:#{port}#{path}"

  @doc """
  Generates a URL with an IP address.
  """
  def ip_address_url(ip \\ "192.168.1.100", port \\ 80, path \\ "/"),
    do: "http://#{ip}:#{port}#{path}"

  @doc """
  Generates a URL with a subdomain.
  """
  def subdomain_url(subdomain \\ "api", domain \\ "example.com", path \\ "/"),
    do: "https://#{subdomain}.#{domain}#{path}"

  @doc """
  Builds a mock consent request structure.
  """
  def consent_request(tool_name, arguments, origin),
    do: %{
      type: :consent_request,
      tool_name: tool_name,
      arguments: arguments,
      origin: origin
    }

  @doc """
  Updates a consent request to show it was granted.
  """
  def consent_granted(request), do: Map.put(request, :response, :granted)

  @doc """
  Updates a consent request to show it was denied.
  """
  def consent_denied(request), do: Map.put(request, :response, :denied)

  @doc """
  Builds a generic security request for the SecurityGuard.
  """
  def build_security_request(transport, opts \\ []) do
    base_request = %{
      transport: transport,
      request_id: generate_uuid(),
      source: Keyword.get(opts, :source, "test"),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    specifics =
      case transport do
        :http ->
          %{
            type: :http,
            method: Keyword.get(opts, :method, "POST"),
            url: Keyword.get(opts, :url, external_url()),
            headers: Keyword.get(opts, :headers, %{"authorization" => generate_bearer_token()}),
            body: Keyword.get(opts, :body, "{}")
          }

        :stdio ->
          %{
            type: :stdio,
            command: Keyword.get(opts, :command, "some_command"),
            args: Keyword.get(opts, :args, [])
          }

        :beam ->
          %{
            type: :beam,
            caller: Keyword.get(opts, :caller, self()),
            message: Keyword.get(opts, :message, {:call, :foo, []})
          }
      end

    Map.merge(base_request, specifics)
  end

  @doc """
  Builds a security request for the HTTP transport.
  """
  def build_http_request(opts \\ []), do: build_security_request(:http, opts)

  @doc """
  Builds a security request for the stdio transport.
  """
  def build_stdio_request(opts \\ []), do: build_security_request(:stdio, opts)

  @doc """
  Builds a security request for the BEAM transport.
  """
  def build_beam_request(opts \\ []), do: build_security_request(:beam, opts)

  @doc """
  Generates a list of test scenarios for token passthrough prevention.
  """
  def generate_token_passthrough_scenarios do
    tokens = [
      {"Authorization", generate_bearer_token()},
      {"X-API-Key", generate_api_key()},
      {"Cookie", generate_cookie()}
    ]

    urls = [
      internal_url(),
      external_url(),
      localhost_url(),
      ip_address_url()
    ]

    for {header, token} <- tokens, url <- urls do
      %{
        name: "passthrough with #{header} to #{url}",
        request: build_http_request(headers: %{header => token}, url: url)
      }
    end
  end

  @doc """
  Asserts that a security decision is to allow the request.
  """
  def assert_allowed(decision, message \\ nil) do
    assert decision.action == :allow,
           message || "Expected action to be :allow, but got #{inspect(decision.action)}"
  end

  @doc """
  Asserts that a security decision is to deny the request.
  """
  def assert_denied(decision, message \\ nil) do
    assert decision.action == :deny,
           message || "Expected action to be :deny, but got #{inspect(decision.action)}"

    assert Map.has_key?(decision, :reason), "Expected a reason for denial"
  end

  @doc """
  Asserts that a security decision is to require user consent.
  """
  def assert_requires_consent(decision, message \\ nil) do
    assert decision.action == :require_consent,
           message ||
             "Expected action to be :require_consent, but got #{inspect(decision.action)}"

    assert Map.has_key?(decision, :consent_request), "Expected a consent_request"
  end

  @doc """
  Measures the execution time of a function.

  Returns a map with `:time_us` (in microseconds) and `:result`.
  """
  def measure_performance(fun) when is_function(fun, 0) do
    :timer.tc(fun)
    |> then(fn {time, result} -> %{time_us: time, result: result} end)
  end
end
