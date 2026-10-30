defmodule Arbor.MCP.Client.HTTPProviderTokenTest do
  @moduledoc """
  A request carries the token its auth provider's `get_token/1` gives for it.
  When the provider gives none, the request is refused before it is sent
  (#176): it goes out neither with the token the provider gave before nor
  without one, on every send path and in both eras, and it fails as not sent
  with `{:auth_provider_token_failed, provider, reason}`. "No token yet",
  `{:ok, nil, state}`, sends the request without an Authorization header.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # A client whose test process exits stops through terminate/2, and a
  # refused connection logs its failure; neither is under test.
  @moduletag :capture_log

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error.TransportError
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Transport.{HTTP, ReliabilityWrapper}

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool("echo", _args, state),
      do: {:ok, %{content: [%{type: "text", text: "ran"}]}, state}
  end

  # Reports each POST's JSON-RPC method and Authorization header to the test,
  # then hands it to the server.
  defmodule Spy do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{method: "POST"} = conn, {owner, inner}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      method =
        case Jason.decode(body) do
          {:ok, %{"method" => method}} -> method
          _other -> :other
        end

      send(owner, {:seen, method, Plug.Conn.get_req_header(conn, "authorization")})
      conn |> Plug.Conn.assign(:raw_body, body) |> Arbor.MCP.HttpPlug.call(inner)
    end

    def call(conn, {_owner, inner}), do: Arbor.MCP.HttpPlug.call(conn, inner)
  end

  # Gives what its script (an Agent) says. get_token/1's error carries no
  # state, so a provider that fails and recovers keeps its script elsewhere.
  defmodule ScriptedProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{script: Keyword.fetch!(config, :script)}}

    @impl true
    def get_token(%{script: script} = state) do
      case Agent.get(script, & &1) do
        {:token, token} -> {:ok, token, state}
        :none -> {:ok, nil, state}
        {:error, reason} -> {:error, reason}
        {:ok, token} -> {:ok, token, state}
        # A token the provider has just acquired: its state changes.
        {:acquired, token} -> {:ok, token, Map.update(state, :acquisitions, 1, &(&1 + 1))}
        :raise -> raise ArgumentError, "s3cret-raised"
        :throw -> throw({:s3cret, "thrown"})
        :exit -> exit({:s3cret, "exited"})
        :invalid -> {:s3cret, "invalid"}
      end
    end

    @impl true
    def handle_unauthorized(_www, _scopes, state), do: {:error, :unauthorized, state}

    @impl true
    def handle_forbidden(_www, _scopes, state), do: {:error, :forbidden, state}
  end

  # Has no token until the server's 401 makes it authenticate, as the OAuth
  # provider before its first flow.
  defmodule PreAuthProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(_config), do: {:ok, %{token: nil}}

    @impl true
    def get_token(state), do: {:ok, state.token, state}

    @impl true
    def handle_unauthorized(_www, _scopes, state), do: {:ok, "fresh", %{state | token: "fresh"}}

    @impl true
    def handle_forbidden(www, scopes, state), do: handle_unauthorized(www, scopes, state)
  end

  @modes [
    legacy_only: :legacy,
    prefer_legacy: :legacy,
    prefer_modern: :modern,
    modern_only: :modern
  ]

  for {mode, era} <- [legacy_only: :legacy, modern_only: :modern] do
    describe "a #{era} connection" do
      test "refuses a request after get_token/1 fails, without sending it" do
        {client, script} = connect(unquote(mode))
        assert {:ok, _} = Client.list_tools(client)
        assert_receive {:seen, "tools/list", ["Bearer t1"]}

        set(script, {:error, :expired})

        assert {:error,
                %TransportError{reason: {:auth_provider_token_failed, ScriptedProvider, :expired}} =
                  error} = Client.list_tools(client)

        assert Client.delivery_outcome(error) == :not_sent
        assert Client.delivery_outcome({:error, error}) == :not_sent

        # The provider recovers, and the next request carries its token.
        set(script, {:token, "t2"})
        assert {:ok, _} = Client.list_tools(client)
        assert_receive {:seen, "tools/list", ["Bearer t2"]}
        refute_received {:seen, _method, _auth}
      end

      test "refuses a tool call after get_token/1 fails, in either result format" do
        {client, script} = connect(unquote(mode))
        set(script, {:error, :expired})

        assert {:error,
                %{reason: {:auth_provider_token_failed, ScriptedProvider, :expired}} = map} =
                 Client.call_tool(client, "echo", %{}, format: :map)

        assert Client.delivery_outcome(map) == :not_sent
        refute_received {:seen, "tools/call", _auth}
      end

      test "sends no Authorization header after get_token/1 gives no token" do
        {client, script} = connect(unquote(mode))
        assert {:ok, _} = Client.list_tools(client)
        assert_receive {:seen, "tools/list", ["Bearer t1"]}

        set(script, :none)
        assert {:ok, _} = Client.list_tools(client)
        assert_receive {:seen, "tools/list", []}
        assert :sys.get_state(client).transport_state.access_token == nil
      end

      # Notifications are sent from the client process itself.
      test "refuses a notification after get_token/1 fails, without sending it" do
        {client, script} = connect(unquote(mode))
        set(script, {:error, :expired})

        assert :ok = Client.notify(client, "notifications/roots/list_changed", %{})
        # The cast is handled before this call returns.
        _state = :sys.get_state(client)

        set(script, {:token, "t1"})
        assert {:ok, _} = Client.list_tools(client)
        assert_receive {:seen, "tools/list", ["Bearer t1"]}
        refute_received {:seen, "notifications/roots/list_changed", _auth}
      end
    end
  end

  describe "a modern request stream or subscription" do
    test "refuses a request stream (progress_token:) after get_token/1 fails" do
      {client, script} = connect(:modern_only)
      assert {:ok, _} = Client.call_tool(client, "echo", %{}, progress_token: "p1")
      assert_receive {:seen, "tools/call", ["Bearer t1"]}

      set(script, {:error, :expired})
      attach_stream_retry()

      assert {:error,
              %TransportError{reason: {:auth_provider_token_failed, ScriptedProvider, :expired}} =
                error} = Client.call_tool(client, "echo", %{}, progress_token: "p2")

      assert Client.delivery_outcome(error) == :not_sent
      refute_received {:stream_retry, _attempt}
      refute_received {:seen, "tools/call", _auth}
    end

    test "refuses a subscription after get_token/1 fails" do
      {client, script} = connect(:modern_only)
      set(script, {:error, :expired})

      assert {:error,
              {:stream_error,
               {:auth_refused, {:auth_provider_token_failed, ScriptedProvider, :expired}}}} =
               Client.listen(client, %{"toolsListChanged" => true})

      refute_received {:seen, "subscriptions/listen", _auth}
    end

    test "sends a request stream without the earlier token after get_token/1 gives none" do
      {client, script} = connect(:modern_only)
      assert {:ok, _} = Client.call_tool(client, "echo", %{}, progress_token: "p1")
      assert_receive {:seen, "tools/call", ["Bearer t1"]}

      set(script, :none)
      assert {:ok, _} = Client.call_tool(client, "echo", %{}, progress_token: "p2")
      assert_receive {:seen, "tools/call", []}
    end
  end

  describe "a provider's failure is reported" do
    for {script, reason} <- [
          {{:error, :expired}, :expired},
          {{:error, %{token: "s3cret-reason"}}, :redacted},
          {{:error, "s3cret-reason"}, :redacted},
          {:raise, {:raised, ArgumentError}},
          {:throw, :throw},
          {:exit, :exit},
          {:invalid, :invalid_token_result},
          {{:ok, 42}, :invalid_token_result}
        ] do
      test "as #{inspect(reason)} when get_token/1 returns #{inspect(script)}" do
        {client, script} = connect(:modern_only)
        set(script, unquote(Macro.escape(script)))

        assert {:error, %TransportError{reason: reason} = error} = Client.list_tools(client)
        assert reason == {:auth_provider_token_failed, ScriptedProvider, unquote(reason)}
        refute inspect(error) =~ "s3cret"
        assert Client.delivery_outcome(error) == :not_sent
        refute_received {:seen, "tools/list", _auth}
      end
    end
  end

  # The opening request gets no token either, so the connection fails as an
  # init failure does, and no mode falls back to the other era over it.
  for {mode, _era} <- @modes do
    test "a #{mode} connection fails at once when the provider has no token for it" do
      Process.flag(:trap_exit, true)
      port = start_listener()

      for {script, reason} <- [{{:error, :expired}, :expired}, {:raise, {:raised, ArgumentError}}] do
        script = start_supervised!({Agent, fn -> script end}, id: make_ref())

        log =
          capture_log(fn ->
            assert {:error,
                    {:transport_connect_failed,
                     {:auth_provider_token_failed, ScriptedProvider, ^reason}}} =
                     start_client(unquote(mode), script, port)
          end)

        refute log =~ "s3cret"
      end

      refute_received {:seen, _method, _auth}
    end
  end

  # A peer observed as modern stays modern: a probe the provider refused
  # was never sent, so it is no evidence to downgrade on, and it isn't
  # reported as the pinned peer's probe failure either.
  test "a peer cached as modern stays modern across a refused connection" do
    Process.flag(:trap_exit, true)
    port = start_listener()
    script = start_supervised!({Agent, fn -> {:token, "t1"} end}, id: make_ref())

    assert {:ok, first} = start_client(:prefer_modern, script, port)
    assert {:ok, "2026-07-28"} = Client.negotiated_version(first)
    :ok = Client.disconnect(first)

    set(script, {:error, :expired})

    capture_log(fn ->
      assert {:error,
              {:transport_connect_failed,
               {:auth_provider_token_failed, ScriptedProvider, :expired}}} =
               start_client(:prefer_modern, script, port)
    end)

    set(script, {:token, "t1"})
    flush_seen()
    assert {:ok, again} = start_client(:prefer_modern, script, port)
    assert {:ok, "2026-07-28"} = Client.negotiated_version(again)
    assert_received {:seen, "server/discover", ["Bearer t1"]}
    refute_received {:seen, "initialize", _auth}
    :ok = Client.disconnect(again)
  end

  # The transport keeps the generation of the provider's last token after
  # dropping it, so a token the server rejected, returned again with the
  # provider's state unchanged, is still refused before it is sent; only a
  # token the provider acquires anew gets past the rejection. A request sent
  # without a token presents no generation, so its 401 retires none.
  describe "a token the server rejected" do
    @request Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call"})

    setup do
      bypass = Bypass.open()
      owner = self()
      # The Authorization headers the server refuses; a request without one
      # is refused too.
      rejected = start_supervised!({Agent, fn -> MapSet.new(["Bearer A"]) end}, id: make_ref())

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        send(owner, {:posted, auth})

        refused = Agent.get(rejected, & &1)

        if auth == [] or Enum.any?(auth, &MapSet.member?(refused, &1)) do
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
        else
          result = %{"resultType" => "complete", "content" => []}

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
          )
        end
      end)

      script = start_supervised!({Agent, fn -> {:token, "A"} end}, id: make_ref())

      {:ok, transport} =
        HTTP.connect(
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          use_sse: false,
          auth_provider: {ScriptedProvider, script: script}
        )

      %{
        transport: HTTP.settle_protocol_era(transport, :modern, "2026-07-28"),
        script: script,
        rejected: rejected
      }
    end

    for clear <- [{:error, :expired}, :none], kind <- [:sync, :post, :request] do
      test "stays refused after the provider gives #{inspect(clear)}, then it again (#{kind})",
           context do
        cleared = reject_then_clear(context, unquote(Macro.escape(clear)))

        set(context.script, {:token, "A"})

        assert {:error, {:auth_refused, {:authentication_failed, :rejected_credential}} = reason,
                refused} = send_as(unquote(kind), cleared)

        assert Client.delivery_outcome({:transport_error, reason}) == :not_sent
        assert refused.rejected_generation == cleared.rejected_generation
        refute_received {:posted, _auth}
      end

      test "is replaced by a token acquired after #{inspect(clear)} (#{kind})", context do
        cleared = reject_then_clear(context, unquote(Macro.escape(clear)))

        set(context.script, {:token, "A"})

        assert {:error, {:auth_refused, {:authentication_failed, :rejected_credential}}, cleared} =
                 HTTP.send_authenticated(@request, cleared)

        set(context.script, {:acquired, "B"})
        assert_sent(unquote(kind), cleared)
        assert_received {:posted, ["Bearer B"]}
        refute_received {:posted, _auth}
      end
    end

    test "a 401 to a request sent without a token retires none of the provider's", context do
      Agent.update(context.rejected, fn _ -> MapSet.new() end)

      assert {:ok, %HTTP{} = accepted, _data} =
               HTTP.send_authenticated(@request, context.transport)

      assert_received {:posted, ["Bearer A"]}

      set(context.script, :none)
      assert {:error, :unauthorized, cleared} = HTTP.send_authenticated(@request, accepted)
      assert_received {:posted, []}
      assert cleared.rejected_generation == accepted.rejected_generation

      set(context.script, {:token, "A"})
      assert {:ok, %HTTP{}, _data} = HTTP.send_authenticated(@request, cleared)
      assert_received {:posted, ["Bearer A"]}
    end
  end

  # The provider owns the Authorization header: one configured through
  # :headers or :security is dropped when the transport connects, so a
  # request carries the provider's token or none, never the configured one,
  # and a 401 to a request without the provider's token retires none of its.
  describe "an Authorization header configured alongside a provider" do
    setup do
      bypass = Bypass.open()
      owner = self()

      # Refuses a request without credentials, answers any other.
      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        send(owner, {:posted, auth})

        if auth == [] do
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.resp(401, "")
        else
          result = %{"resultType" => "complete", "content" => []}

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
          )
        end
      end)

      %{url: "http://127.0.0.1:#{bypass.port}/mcp"}
    end

    for {source, configured} <- [
          headers: [headers: [{"Authorization", "Bearer configured-s3cret"}]],
          security: [security: %{auth: {:bearer, "configured-s3cret"}}]
        ] do
      test "set through :#{source} is dropped at connect, and the provider's token sent", %{
        url: url
      } do
        script = start_supervised!({Agent, fn -> {:token, "A"} end}, id: make_ref())

        {transport, log} =
          with_log(fn ->
            connect_with(
              url,
              {ScriptedProvider, script: script},
              unquote(Macro.escape(configured))
            )
          end)

        assert Arbor.MCP.Internal.Headers.get(transport.headers, "authorization") == nil
        assert transport.credential_generation == 0
        assert log =~ "supplies the Authorization header"
        refute log =~ "s3cret"

        assert {:ok, %HTTP{}, _data} = HTTP.send_authenticated(@request, transport)
        assert_received {:posted, ["Bearer A"]}
      end

      test "set through :#{source} isn't sent when the provider has no token", %{url: url} do
        script = start_supervised!({Agent, fn -> :none end}, id: make_ref())

        transport =
          connect_with(url, {ScriptedProvider, script: script}, unquote(Macro.escape(configured)))

        assert {:error, :unauthorized, after_401} = HTTP.send_authenticated(@request, transport)
        assert_received {:posted, []}
        # The 401 was to no credential of the provider's.
        assert after_401.rejected_generation == 0
      end

      test "set through :#{source} isn't sent after a provider error", %{url: url} do
        script = start_supervised!({Agent, fn -> {:error, :expired} end}, id: make_ref())

        transport =
          connect_with(url, {ScriptedProvider, script: script}, unquote(Macro.escape(configured)))

        assert {:error,
                {:auth_refused, {:auth_provider_token_failed, ScriptedProvider, :expired}},
                refused} = HTTP.send_authenticated(@request, transport)

        refute_received {:posted, _auth}

        set(script, :none)
        assert {:error, :unauthorized, _state} = HTTP.send_authenticated(@request, refused)
        assert_received {:posted, []}
      end

      test "set through :#{source} leaves the provider's pre-auth request tokenless", %{url: url} do
        transport = connect_with(url, {PreAuthProvider, []}, unquote(Macro.escape(configured)))

        # The tokenless request draws the 401 that starts the provider's flow.
        assert {:ok, %HTTP{access_token: "fresh"}, _data} =
                 HTTP.send_authenticated(@request, transport)

        assert_received {:posted, []}
        assert_received {:posted, ["Bearer fresh"]}
        refute_received {:posted, _auth}
      end
    end

    test "is still sent without a provider", %{url: url} do
      {:ok, transport} =
        HTTP.connect(
          url: url,
          use_sse: false,
          headers: [{"Authorization", "Bearer configured"}]
        )

      transport = HTTP.settle_protocol_era(transport, :modern, "2026-07-28")
      assert {:ok, %HTTP{}, _data} = HTTP.send_authenticated(@request, transport)
      assert_received {:posted, ["Bearer configured"]}
    end
  end

  # A request refused before it was sent was never an upstream failure.
  describe "with reliability:" do
    @strict [circuit_breaker: [failure_threshold: 1, reset_timeout: 60_000]]

    for {mode, era} <- [legacy_only: :legacy, modern_only: :modern] do
      test "a #{era} refusal counts no circuit-breaker failure" do
        {client, script} = connect(unquote(mode), reliability: @strict)
        set(script, {:error, :expired})

        # A POST from its own task, and a notification sent from the client.
        assert {:error, %TransportError{reason: {:auth_provider_token_failed, _, _}}} =
                 Client.list_tools(client)

        assert :ok = Client.notify(client, "notifications/roots/list_changed", %{})
        _state = :sys.get_state(client)

        if unquote(era) == :modern do
          assert {:error, %TransportError{reason: {:auth_provider_token_failed, _, _}}} =
                   Client.call_tool(client, "echo", %{}, progress_token: "p1")
        end

        assert %{total_failures: 0, state: :closed} = breaker_stats(client)

        set(script, {:token, "t1"})
        assert {:ok, _} = Client.list_tools(client)
        assert_receive {:seen, "tools/list", ["Bearer t1"]}
      end
    end
  end

  defp connect(protocol_mode, opts \\ []) do
    script = start_supervised!({Agent, fn -> {:token, "t1"} end}, id: make_ref())
    assert {:ok, client} = start_client(protocol_mode, script, start_listener(), opts)
    flush_seen()

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    {client, script}
  end

  defp start_listener do
    runtime =
      start_supervised!({Runtime, handler: Handler, transport: :mounted_http}, id: make_ref())

    inner = Arbor.MCP.HttpPlug.init(runtime: runtime, path: "/mcp", protocol_mode: :prefer_modern)

    listener =
      start_supervised!(
        {Bandit, plug: {Spy, {self(), inner}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp start_client(protocol_mode, script, port, opts \\ []) do
    Client.start_link(
      [
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: protocol_mode,
        use_sse: false,
        security: %{origin: nil},
        health_check_interval: nil,
        reconnect: false,
        auth_provider: {ScriptedProvider, script: script}
      ] ++ opts
    )
  end

  defp set(script, value), do: Agent.update(script, fn _ -> value end)

  defp connect_with(url, provider, configured) do
    {:ok, transport} =
      HTTP.connect([url: url, use_sse: false, auth_provider: provider] ++ configured)

    HTTP.settle_protocol_era(transport, :modern, "2026-07-28")
  end

  # The server rejects the provider's token A, and the provider then gives
  # an error or no token. The transport drops A but keeps its generation.
  defp reject_then_clear(%{transport: transport, script: script}, clear) do
    assert {:error, :unauthorized, retired} = HTTP.send_authenticated(@request, transport)
    assert_received {:posted, ["Bearer A"]}
    assert retired.rejected_generation == retired.credential_generation

    set(script, clear)
    result = HTTP.send_authenticated(@request, retired)

    cleared =
      case clear do
        {:error, reason} ->
          assert {:error,
                  {:auth_refused, {:auth_provider_token_failed, ScriptedProvider, ^reason}},
                  cleared} = result

          refute_received {:posted, _auth}
          cleared

        :none ->
          assert {:error, :unauthorized, cleared} = result
          assert_received {:posted, []}
          cleared
      end

    assert cleared.access_token == nil
    assert cleared.credential_generation == retired.credential_generation
    assert cleared.rejected_generation == retired.rejected_generation
    cleared
  end

  defp send_as(:sync, state), do: HTTP.send_authenticated(@request, state)
  defp send_as(:post, state), do: HTTP.send_async(@request, state)

  defp send_as(:request, state),
    do: HTTP.open_stream(@request, state, self(), stream_kind: :request)

  # Sends and waits for the request to finish, so no server handler outlives
  # the test.
  defp assert_sent(:sync, state),
    do: assert({:ok, %HTTP{}, _data} = send_as(:sync, state))

  defp assert_sent(:post, state) do
    assert {:ok, %HTTP{}} = send_as(:post, state)
    assert_receive {:async_post_task, _monitor, _task, 1}
    assert_receive {:async_post_result, {:ok, _state, _data}, %{request_id: 1}}
  end

  defp assert_sent(:request, state) do
    assert {:ok, %HTTP{modern_streams: %{1 => stream}}} = send_as(:request, state)
    assert_receive {:modern_http_stream_message, ^stream, 1, %{"result" => _result}}
    send(stream, {:modern_http_stream_ack, self(), 1})
    assert_receive {:modern_http_stream_finished, ^stream, 1}
  end

  defp flush_seen do
    receive do
      {:seen, _method, _auth} -> flush_seen()
    after
      0 -> :ok
    end
  end

  defp attach_stream_retry do
    test_pid = self()
    handler = "provider-token-retry-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:arbor_mcp, :client, :http, :request, :retry],
      fn _event, %{attempt: attempt}, _metadata, _config ->
        send(test_pid, {:stream_retry, attempt})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp breaker_stats(client),
    do:
      ReliabilityWrapper.get_circuit_breaker_stats(
        :sys.get_state(client).transport_state.reliability
      )
end
