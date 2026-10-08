defmodule Arbor.MCP.Authorization.FullOAuthFlowRedirectSecurityTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.FullOAuthFlow

  @callback_uri "http://127.0.0.1:45123/callback"

  test "follows only same-origin hops and the exact callback through the hardened boundary" do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    request_fun = fn _method, request, http_options, _request_options ->
      url = request |> elem(0) |> to_string()
      Agent.update(requests, &[{url, http_options} | &1])

      response =
        cond do
          url =~ "/authorize" -> redirect("/login")
          url =~ "/login" -> redirect(@callback_uri <> "?code=abc&state=xyz")
          url =~ "/callback" -> ok()
        end

      response
    end

    assert {:ok, callback} =
             FullOAuthFlow.follow_authorization_redirects(
               "https://auth.example/authorize",
               @callback_uri,
               oauth_http: http_options(request_fun)
             )

    assert callback == @callback_uri <> "?code=abc&state=xyz"

    requested = requests |> Agent.get(&Enum.reverse/1)
    assert length(requested) == 3

    assert [first, second, third] = Enum.map(requested, &elem(&1, 0))
    assert first == "https://93.184.216.34/authorize"
    assert second == "https://93.184.216.34/login"
    assert third == "http://127.0.0.1:45123/callback?code=abc&state=xyz"

    assert Enum.all?(requested, fn {_url, options} -> options[:autoredirect] == false end)
    assert Enum.all?(requested, fn {_url, options} -> is_integer(options[:timeout]) end)
  end

  test "rejects a cross-origin intermediate redirect before connecting to it" do
    owner = self()

    request_fun = fn _method, request, _http_options, _request_options ->
      send(owner, {:requested, request |> elem(0) |> to_string()})
      redirect("https://evil.example/steal")
    end

    assert {:error, :cross_origin_authorization_redirect} =
             FullOAuthFlow.follow_authorization_redirects(
               "https://auth.example/authorize",
               @callback_uri,
               oauth_http: http_options(request_fun)
             )

    assert_receive {:requested, "https://93.184.216.34/authorize"}
    refute_receive {:requested, _other}
  end

  test "rejects callback lookalikes with a different port or path" do
    for location <- [
          "http://127.0.0.1:45124/callback?code=abc",
          "http://127.0.0.1:45123/callback/extra?code=abc",
          "http://127.0.0.1.evil.example:45123/callback?code=abc"
        ] do
      request_fun = fn _method, _request, _http_options, _request_options ->
        redirect(location)
      end

      assert {:error, :cross_origin_authorization_redirect} =
               FullOAuthFlow.follow_authorization_redirects(
                 "https://auth.example/authorize",
                 @callback_uri,
                 oauth_http: http_options(request_fun)
               )
    end
  end

  test "enforces redirect and cycle bounds" do
    loop = fn _method, _request, _http_options, _request_options -> redirect("/authorize") end

    assert {:error, :authorization_redirect_cycle} =
             FullOAuthFlow.follow_authorization_redirects(
               "https://auth.example/authorize",
               @callback_uri,
               oauth_http: http_options(loop)
             )

    next = Agent.start_link(fn -> 0 end) |> elem(1)

    chain = fn _method, _request, _http_options, _request_options ->
      hop = Agent.get_and_update(next, &{&1, &1 + 1})
      redirect("/hop-#{hop}")
    end

    assert {:error, :authorization_redirect_limit} =
             FullOAuthFlow.follow_authorization_redirects(
               "https://auth.example/authorize",
               @callback_uri,
               authorization_max_redirects: 1,
               oauth_http: http_options(chain)
             )
  end

  test "enforces one aggregate authorization deadline even when a client stalls" do
    stalled = fn _method, _request, _http_options, _request_options ->
      Process.sleep(100)
      ok()
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, :authorization_deadline_exceeded} =
             FullOAuthFlow.follow_authorization_redirects(
               "https://auth.example/authorize",
               @callback_uri,
               authorization_deadline_ms: 10,
               oauth_http: http_options(stalled)
             )

    assert System.monotonic_time(:millisecond) - started < 90
  end

  defp http_options(request_fun) do
    [
      dns_resolver: fn
        "auth.example", _timeout -> {:ok, [{93, 184, 216, 34}]}
        "127.0.0.1", _timeout -> {:ok, [{127, 0, 0, 1}]}
        _host, _timeout -> {:ok, [{93, 184, 216, 35}]}
      end,
      request_fun: request_fun
    ]
  end

  defp redirect(location) do
    {:ok, {{~c"HTTP/1.1", 302, ~c"Found"}, [{~c"location", String.to_charlist(location)}], ""}}
  end

  defp ok, do: {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "ok"}}
end
