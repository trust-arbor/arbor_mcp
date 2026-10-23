defmodule Arbor.MCP.Authorization.LogSanitizerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Arbor.MCP.Authorization.{ErrorHandler, HTTPClient, LogSanitizer}

  test "redacts nested OAuth credentials and raw response bodies" do
    reason =
      {:oauth_error, 400,
       %{
         "error" => "invalid_grant",
         "access_token" => "access-secret",
         nested: %{
           refresh_token: "refresh-secret",
           client_secret: "client-secret",
           code_verifier: "verifier-secret"
         }
       }}

    formatted = LogSanitizer.format(reason)

    refute formatted =~ "access-secret"
    refute formatted =~ "refresh-secret"
    refute formatted =~ "client-secret"
    refute formatted =~ "verifier-secret"
    assert formatted =~ "[REDACTED]"

    raw =
      Jason.encode!(%{
        "error" => "invalid_request",
        "state" => "state-secret",
        "code" => "code-secret"
      })

    sanitized_raw = LogSanitizer.format({:http_error, 400, raw})
    refute sanitized_raw =~ "state-secret"
    refute sanitized_raw =~ "code-secret"
  end

  test "redacts authorization values and strips URI queries and fragments" do
    formatted =
      LogSanitizer.format(
        "Bearer bearer-secret code=code-secret state=state-secret " <>
          "code_verifier=verifier-secret " <>
          "https://errors.example/help?access_token=query-secret#fragment-secret"
      )

    refute formatted =~ "bearer-secret"
    refute formatted =~ "code-secret"
    refute formatted =~ "state-secret"
    refute formatted =~ "verifier-secret"
    refute formatted =~ "query-secret"
    refute formatted =~ "fragment-secret"
  end

  test "OAuth error logging does not emit tokens, cookies, codes, or state" do
    log =
      capture_log(fn ->
        assert {:error, {"invalid_request", _description}} =
                 ErrorHandler.handle_oauth_error(%{
                   "error" => "invalid_request",
                   "error_description" =>
                     "access_token=access-secret cookie=cookie-secret code=code-secret",
                   "error_uri" =>
                     "https://errors.example/help?state=state-secret&token=query-secret"
                 })
      end)

    for secret <- ~w(access-secret cookie-secret code-secret state-secret query-secret) do
      refute log =~ secret
    end
  end

  test "malformed token response is logged without leaking the raw body or crashing" do
    secret = "leak-me-oauth-token-9f3c2a1b"
    malformed_body = "<html>bad gateway #{secret}</html>"

    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, malformed_body)
    end)

    result =
      HTTPClient.make_token_request(
        "http://localhost:#{bypass.port}/token",
        [{"grant_type", "client_credentials"}, {"client_id", "cid"}, {"client_secret", "cs"}]
      )

    assert {:error, {:json_decode_error, reason}} = result

    log =
      capture_log(fn ->
        formatted = LogSanitizer.format({:json_decode_error, reason})
        Logger.error("Token refresh failed: #{formatted}")
      end)

    refute inspect(result) =~ secret
    refute log =~ secret
  end

  test "sanitizes exception structs without crashing" do
    secret = "leak-me-oauth-token-9f3c2a1b"
    assert {:error, %Jason.DecodeError{} = decode_error} = Jason.decode("not-json #{secret}")

    formatted = LogSanitizer.format(decode_error)

    refute formatted =~ secret
    assert formatted =~ "[REDACTED]"
    assert is_binary(LogSanitizer.format(%RuntimeError{message: "boom"}))
    assert is_binary(LogSanitizer.format(%URI{path: "/token"}))
  end
end
