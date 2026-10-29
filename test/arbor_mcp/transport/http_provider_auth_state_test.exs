defmodule Arbor.MCP.Transport.HTTPProviderAuthStateTest do
  @moduledoc """
  When an auth provider fails, the state it returns records what it tried
  (the OAuth provider's loop guards). The HTTP transport used to drop it, so
  the next 401 could start the same flow again.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.HTTP

  defmodule FailingProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(_config), do: {:ok, %{tried: 0}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    @impl true
    def handle_unauthorized(_www_auth, _scopes, state),
      do: {:error, :flow_failed, %{state | tried: state.tried + 1}}

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}
  end

  defmodule RotatingProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(_config), do: {:ok, %{refresh_token: "r1"}}

    @impl true
    def get_token(state), do: {:ok, nil, state}

    # A refresh that rotates the refresh token.
    @impl true
    def handle_unauthorized(_www_auth, _scopes, state),
      do: {:ok, "new-access", %{state | refresh_token: "r2"}}

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}
  end

  defmodule SequenceProvider do
    @behaviour Arbor.MCP.Authorization.Provider
    @impl true
    def init(_opts), do: {:ok, []}
    @impl true
    def get_token(state), do: {:ok, nil, state}
    @impl true
    def handle_unauthorized(_www, _scopes, state), do: {:ok, "A", state ++ [401]}
    @impl true
    def handle_forbidden(_www, _scopes, state), do: {:ok, "B", state ++ [403]}
  end

  @tag :reauth_round7
  test "synchronous provider auth retires B after 401 then 403 then a terminal 401" do
    bypass = Bypass.open()
    attempts = start_supervised!({Agent, fn -> [] end})

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      authorization = Plug.Conn.get_req_header(conn, "authorization")
      Agent.update(attempts, &(&1 ++ [authorization]))
      status = if authorization == ["Bearer A"], do: 403, else: 401

      conn
      |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
      |> Plug.Conn.resp(status, "")
    end)

    {:ok, transport} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        use_sse: false,
        auth_provider: {SequenceProvider, []}
      )

    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert {:error, {:unauthorized, 401, "", "Bearer"}, retired} =
             HTTP.send_authenticated(request, transport)

    assert retired.access_token == nil
    assert retired.credential_generation == retired.rejected_generation
    assert retired.rejected_generation > 0
    assert retired.auth_provider_state == [401, 403]
    assert Agent.get(attempts, & &1) == [[], ["Bearer A"], ["Bearer B"]]
  end

  test "a retried request that still fails keeps a rotated refresh token" do
    bypass = Bypass.open()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
      |> Plug.Conn.resp(401, "")
    end)

    {:ok, transport} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        auth_provider: {RotatingProvider, []}
      )

    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert {:error, _still_unauthorized, transport} = HTTP.send_authenticated(request, transport)
    assert transport.auth_provider_state.refresh_token == "r2"
  end

  test "an authenticated send that fails keeps the provider's new state" do
    bypass = Bypass.open()

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
      |> Plug.Conn.resp(401, "")
    end)

    {:ok, transport} =
      HTTP.connect(
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        auth_provider: {FailingProvider, []}
      )

    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert {:error, :flow_failed, transport} = HTTP.send_authenticated(request, transport)
    assert transport.auth_provider_state.tried == 1
  end
end
