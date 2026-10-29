defmodule Arbor.MCP.Client.ModernHTTPNonblockingTest do
  @moduledoc """
  Over modern (2026-07-28) Streamable HTTP no request runs in the client
  process: an ordinary request POSTs from its own task, and one with a
  progress token or log level gets its own request stream. So requests
  through one client run at the same time, and the client keeps serving
  other calls, MRTR rounds and request-scoped notifications while a slow one
  runs. Timeouts, cancellation, single-flight authentication and the order
  of a notification before a request still hold.
  """

  use ExUnit.Case, async: false

  # A client whose test process exits stops through terminate/2, which can
  # log its transport-close worker being refused; that is not under test.
  @moduletag :capture_log

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error.TransportError
  alias Arbor.MCP.Server.{Context, Runtime}
  alias Arbor.MCP.Transport.HTTP

  @version "2026-07-28"

  defmodule ServerHandler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def init(args), do: {:ok, %{test_pid: Keyword.fetch!(args, :test_pid)}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{name: "modern-nonblocking", version: "0"},
         capabilities: %{tools: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ["hold", "progress", "onboard"],
            do: %{name: name, inputSchema: %{type: "object"}}

      {:ok, tools, nil, state}
    end

    # Runs until the test releases it, or until the client cancels it.
    @impl true
    def handle_call_tool("hold", %{"label" => label}, state) do
      send(state.test_pid, {:holding, label, self(), Context.request_id()})

      receive do
        :release ->
          {:ok, %{content: [%{type: "text", text: label}]}, state}

        {:arbor_mcp_cancelled, _token, reason} ->
          send(state.test_pid, {:server_cancelled, label, reason})
          {:ok, %{content: []}, state}
      end
    end

    def handle_call_tool("progress", _args, state) do
      :ok = Context.report_progress(1, 2, "half")
      {:ok, %{content: [%{type: "text", text: "progressed"}]}, state}
    end

    def handle_call_tool("onboard", _args, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "profile" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "Display name",
                "requestedSchema" => %{
                  "type" => "object",
                  "properties" => %{"name" => %{"type" => "string"}}
                }
              }
            }
          }

          {:input_required, requests, state}

        %{"profile" => %{"content" => %{"name" => name}}} ->
          {:ok, %{content: [%{type: "text", text: name}]}, state}
      end
    end
  end

  defmodule ClientHandler do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_ping(test_pid), do: {:ok, %{}, test_pid}

    @impl true
    def handle_list_roots(test_pid), do: {:ok, [], test_pid}

    @impl true
    def handle_create_message(_params, test_pid), do: {:error, "not used", test_pid}

    @impl true
    def handle_elicitation_create(message, _schema, test_pid) do
      send(test_pid, {:elicitation, message})
      {:ok, %{"action" => "accept", "content" => %{"name" => "Grace"}}, test_pid}
    end

    @impl true
    def handle_progress(request_id, params, test_pid) do
      send(test_pid, {:client_progress, request_id, params})
      {:ok, test_pid}
    end
  end

  defmodule Provider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{token: "stale", test_pid: Keyword.fetch!(config, :test_pid)}}

    @impl true
    def get_token(state), do: {:ok, state.token, state}

    @impl true
    def handle_unauthorized(_www_authenticate, _scopes, state) do
      send(state.test_pid, :authenticated)
      {:ok, "fresh", %{state | token: "fresh"}}
    end

    @impl true
    def handle_forbidden(www_authenticate, scopes, state),
      do: handle_unauthorized(www_authenticate, scopes, state)
  end

  defmodule RefusingProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider
    @impl true
    def init(opts), do: Provider.init(opts)
    @impl true
    def get_token(state), do: Provider.get_token(state)
    @impl true
    def handle_unauthorized(_www, _scopes, state), do: {:error, :provider_refused, state}
    @impl true
    def handle_forbidden(www, scopes, state), do: handle_unauthorized(www, scopes, state)
  end

  for {name, tool, provider, reason} <- [
        {"Basic", "basic", nil, {:unauthorized, 401, "", ~s(Basic realm="mcp")}},
        {"provider", "protected", RefusingProvider, {:authentication_failed, :provider_refused}},
        {"OAuth", "bearer", nil, :oauth_failed}
      ],
      format <- [:map, :struct],
      stream? <- [false, true] do
    @tag :reauth_round6
    test "#{name} refusal bypasses an always-retry policy in #{format} format (stream: #{stream?})" do
      provider = unquote(provider)
      opts = if provider, do: [auth_provider: {provider, test_pid: self()}], else: []
      client = start_bypass_client(opts)

      request_opts = [
        timeout: 5_000,
        format: unquote(format),
        retry_policy: [max_attempts: 2, initial_delay: 0, should_retry?: fn _ -> true end]
      ]

      request_opts =
        if unquote(stream?),
          do: Keyword.put(request_opts, :progress_token, "round-six-refusal"),
          else: request_opts

      assert {:error, error} = Client.call_tool(client, unquote(tool), %{}, request_opts)

      if unquote(Macro.escape(reason)) == :oauth_failed do
        assert {:oauth_failed, _} = error.reason
      else
        assert error.reason == unquote(Macro.escape(reason))
      end

      assert_received {:posted, "tools/call"}
      refute_received {:posted, "tools/call"}
    end
  end

  describe "requests through one client" do
    test "run at the same time, with or without a progress token" do
      client = start_client()

      tasks =
        for label <- ["a", "b", "c", "d"] do
          opts =
            if label in ["c", "d"],
              do: [timeout: 5_000, progress_token: "token-#{label}"],
              else: [timeout: 5_000]

          Task.async(fn -> Client.call_tool(client, "hold", %{"label" => label}, opts) end)
        end

      # All four reached the server before any of them was answered, so they
      # take as long as the slowest one rather than the sum.
      handlers = for _ <- 1..4, into: %{}, do: receive_holding()
      assert map_size(handlers) == 4
      Enum.each(handlers, fn {_label, {handler, _id}} -> send(handler, :release) end)

      assert ["a", "b", "c", "d"] = Enum.map(Task.await_many(tasks, 5_000), &text!/1)
    end

    test "leave the client free for other calls and notifications while one is held" do
      client = start_client()

      held =
        Task.async(fn ->
          Client.call_tool(client, "hold", %{"label" => "held"}, timeout: 5_000)
        end)

      {"held", {handler, _id}} = receive_holding()

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
      assert {:ok, _discover} = Client.ping(client, timeout: 2_000)

      assert {:ok, %{"tools" => [_ | _]}} =
               Client.list_tools(client, format: :map, timeout: 2_000)

      assert {:ok, _} =
               Client.call_tool(client, "progress", %{}, progress_token: "quick", timeout: 2_000)

      assert_receive {:client_progress, _request_id, %{"progressToken" => "quick"}}

      send(handler, :release)
      assert "held" = text!(Task.await(held, 5_000))
    end

    test "complete an MRTR round trip while another call is held" do
      client = start_client()

      held =
        Task.async(fn ->
          Client.call_tool(client, "hold", %{"label" => "held"}, timeout: 5_000)
        end)

      {"held", {handler, _id}} = receive_holding()

      assert "Grace" = text!(Client.call_tool(client, "onboard", %{}, timeout: 5_000))
      assert_received {:elicitation, "Display name"}

      send(handler, :release)
      assert "held" = text!(Task.await(held, 5_000))
    end

    test "a timed-out call is cancelled on the server and the others carry on" do
      client = start_client()

      # On its own request stream; the one that times out POSTs from a task.
      slow =
        Task.async(fn ->
          Client.call_tool(client, "hold", %{"label" => "slow"},
            progress_token: "slow",
            timeout: 5_000
          )
        end)

      {"slow", {slow_handler, _id}} = receive_holding()

      assert {:error, :timeout} =
               Client.call_tool(client, "hold", %{"label" => "short"}, timeout: 500)

      assert {"short", _handler} = receive_holding()
      assert_receive {:server_cancelled, "short", _reason}, 3_000
      refute_received {:server_cancelled, "slow", _reason}

      send(slow_handler, :release)
      assert "slow" = text!(Task.await(slow, 5_000))
    end

    test "cancelling one call leaves the others running" do
      client = start_client()

      # One on its own request stream, the other POSTing from a task.
      tasks =
        for {label, opts} <- [{"cancelled", [progress_token: "cancelled"]}, {"kept", []}],
            into: %{},
            do:
              {label,
               Task.async(fn ->
                 Client.call_tool(client, "hold", %{"label" => label}, [timeout: 5_000] ++ opts)
               end)}

      handlers = for _ <- 1..2, into: %{}, do: receive_holding()
      {_handler, cancelled_id} = handlers["cancelled"]

      assert :ok = Client.send_cancelled(client, cancelled_id, "no longer needed")
      assert {:error, :cancelled} = Task.await(tasks["cancelled"], 2_000)
      assert_receive {:server_cancelled, "cancelled", _reason}, 3_000

      {kept_handler, _id} = handlers["kept"]
      send(kept_handler, :release)
      assert "kept" = text!(Task.await(tasks["kept"], 5_000))
    end
  end

  describe "authentication" do
    test "concurrent challenges run one authentication through the provider" do
      client = start_bypass_client(auth_provider: {Provider, test_pid: self()})

      tasks =
        for _ <- 1..4,
            do: Task.async(fn -> Client.call_tool(client, "protected", %{}, timeout: 5_000) end)

      assert Enum.all?(Task.await_many(tasks, 10_000), &match?({:ok, _}, &1))
      assert_received :authenticated
      refute_received :authenticated
    end

    # A modern request without an auth provider used to be re-sent from the
    # client process after a 401 or 403, holding every other request until
    # that POST was answered.
    test "a challenge OAuth can't answer fails the request without re-sending it" do
      client = start_bypass_client()

      assert {:error, %TransportError{reason: {:unauthorized, 401, _body, "Basic" <> _}}} =
               Client.call_tool(client, "basic", %{}, timeout: 5_000)

      assert_received {:posted, "tools/call"}
      refute_received {:posted, "tools/call"}
    end

    test "a failed OAuth flow fails the request without re-sending it" do
      client = start_bypass_client()

      assert {:error, %TransportError{reason: {:oauth_failed, _reason}}} =
               Client.call_tool(client, "bearer", %{}, timeout: 5_000)

      assert_received {:posted, "tools/call"}
      refute_received {:posted, "tools/call"}
    end

    @tag :reauth_round5
    test "a still-owned cancelled POST retires its rejected token without starting auth" do
      transport = HTTP.put_oauth_token(modern_transport(), %{access_token: "rejected"}, ["read"])
      state = %{client_state(transport) | pending_requests: %{}}
      ref = make_ref()

      challenge = %{
        status: 401,
        www_authenticate: "Basic",
        scopes: [],
        token: "rejected",
        credential_generation: transport.credential_generation
      }

      assert {:noreply, state} =
               Client.handle_info({:http_post_auth_challenge, self(), ref, challenge}, state)

      assert_receive {:http_post_auth_result, ^ref, {:error, :stream_retired}}
      assert state.transport_state.access_token == nil
      assert state.transport_state.granted_scopes == []
      refute List.keymember?(state.transport_state.headers, "Authorization", 0)
      assert state.http_auth.worker == nil
      assert state.http_auth.waiters == %{}
    end

    test "without a provider, a challenge another request already answered gets its token" do
      ref = make_ref()
      state = client_state(%{modern_transport() | access_token: "obtained"})
      challenge = %{status: 401, www_authenticate: "Bearer", scopes: [], token: nil}

      assert {:noreply, ^state} =
               Client.handle_info({:http_post_auth_challenge, self(), ref, challenge}, state)

      assert_received {:http_post_auth_result, ^ref, {:ok, "obtained", _context}}
    end

    # Two requests sent with the "stale" token both get a 403 step-up. The
    # inline flow can't run in a test (it fetches OAuth metadata only over
    # HTTPS), so this starts from the state the first one's flow leaves,
    # built as that flow builds it. Any further flow here would fail: this
    # transport's endpoint is plain http.
    test "without a provider, concurrent 403 step-ups run one flow" do
      flows = count_oauth_flows()
      stale = %{modern_transport() | access_token: "stale"}

      stepped_up =
        HTTP.put_oauth_token(
          stale,
          %{access_token: "stepped-up", scope: "tools.read tools.call"},
          [
            "tools.call"
          ]
        )

      state = client_state(stepped_up)
      ref = make_ref()

      challenge = %{
        status: 403,
        www_authenticate: ~s(Bearer error="insufficient_scope", scope="tools.call"),
        scopes: ["tools.call"],
        token: "stale"
      }

      assert {:noreply, ^state} =
               Client.handle_info({:http_post_auth_challenge, self(), ref, challenge}, state)

      assert_received {:http_post_auth_result, ^ref, {:ok, "stepped-up", _context}}
      refute_received {:oauth_flow_started, ^flows}

      # A scope the first flow didn't get still needs a flow of its own.
      admin = %{challenge | www_authenticate: ~s(Bearer scope="admin"), scopes: ["admin"]}

      assert {:noreply, state} =
               Client.handle_info({:http_post_auth_challenge, self(), ref, admin}, state)

      assert_receive {:http_inline_auth_result, _worker, _id, _result} = completed, 2_000
      assert {:noreply, _state} = Client.handle_info(completed, state)
      assert_received {:http_post_auth_result, ^ref, {:error, {:oauth_failed, _reason}}}
      assert_received {:oauth_flow_started, ^flows}
    end

    test "the inline flow records the scopes its token was granted" do
      transport = modern_transport()

      assert %HTTP{access_token: "granted", granted_scopes: ["a", "b"]} =
               HTTP.put_oauth_token(transport, %{access_token: "granted", scope: "a b"}, ["a"])

      # A token response that names no scope grants the ones asked for.
      assert %HTTP{granted_scopes: ["a"]} =
               HTTP.put_oauth_token(transport, %{"access_token" => "asked"}, ["a"])
    end
  end

  describe "a POST task without an auth provider" do
    test "on a modern connection asks its client to authenticate and re-sends itself" do
      bypass = Bypass.open()
      attempts = start_supervised!({Agent, fn -> 0 end})

      Bypass.expect(bypass, "POST", "/mcp", fn conn ->
        case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
          1 ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
            |> Plug.Conn.resp(401, "")

          2 ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer inline-token"]
            json(conn, %{"jsonrpc" => "2.0", "id" => 7, "result" => complete()})
        end
      end)

      transport = modern_transport(bypass.port)
      request = encoded_call(7)

      assert {:ok, _transport} = HTTP.send_async(request, transport)
      assert_receive {:async_post_task, _monitor, task, 7}

      assert_receive {:http_post_auth_challenge, ^task, ref,
                      %{status: 401, www_authenticate: ~s(Bearer realm="mcp"), token: nil}},
                     2_000

      send(task, {:http_post_auth_result, ref, {:ok, "inline-token"}})

      assert_receive {:async_post_result, {:ok, _state, body}, %{request_id: 7}}, 2_000
      assert %{"id" => 7, "result" => %{"resultType" => "complete"}} = Jason.decode!(body)
      assert Agent.get(attempts, & &1) == 2
    end

    test "on a legacy-era connection asks its client and preserves an unanswered challenge" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
        |> Plug.Conn.resp(401, "")
      end)

      {:ok, transport} =
        HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)

      transport = HTTP.settle_protocol_era(transport, :legacy, "2025-06-18")
      request = encoded_call(8)

      assert {:ok, _transport} = HTTP.send_async(request, transport)
      assert_receive {:async_post_task, _monitor, task, 8}

      assert_receive {:http_post_auth_challenge, ^task, ref, %{status: 401, token: nil}},
                     2_000

      send(task, {:http_post_auth_result, ref, {:error, :no_credentials}})

      assert_receive {:async_post_result,
                      {:error, {:auth_refused, {:unauthorized, 401, "", _challenge}}},
                      %{request_id: 8}},
                     2_000
    end
  end

  test "a notification sent before a request reaches the server first" do
    client = start_bypass_client()

    :ok = Client.notify(client, "notifications/example", %{"n" => 1})
    assert {:ok, _} = Client.call_tool(client, "quick", %{}, timeout: 5_000)

    # The first of the two to arrive, whichever it is.
    assert_receive {:posted, first}
    assert first == "notifications/example"
    assert_receive {:posted, "tools/call"}
    refute_received {:posted, _method}
  end

  # This test process stands in for the POST task.
  defp client_state(transport_state) do
    transport_state =
      if is_binary(transport_state.access_token) and transport_state.credential_generation == 0 do
        HTTP.put_oauth_token(
          transport_state,
          %{access_token: transport_state.access_token},
          transport_state.granted_scopes
        )
      else
        transport_state
      end

    %Client{
      transport_mod: HTTP,
      transport_state: transport_state,
      pending_requests: %{1 => {{self(), make_ref()}, :single, "tools/call"}},
      pending_batches: %{},
      cancelled_requests: MapSet.new(),
      async_post_tasks: %{make_ref() => {self(), 1}}
    }
  end

  # Each OAuth flow that starts sends {:oauth_flow_started, ref} here.
  defp count_oauth_flows do
    ref = make_ref()
    test_pid = self()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:arbor_mcp, :auth, :flow, :started],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, {:oauth_flow_started, ref})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp receive_holding do
    assert_receive {:holding, label, handler, request_id}, 3_000
    {label, {handler, request_id}}
  end

  defp text!({:ok, %{content: [%{text: text}]}}), do: text
  defp text!({:ok, %{content: [%{"text" => text}]}}), do: text

  # A real modern server: the Runtime mounted in HttpPlug.
  defp start_client do
    port = free_port()
    ranch_ref = {__MODULE__, System.unique_integer([:positive])}

    runtime =
      start_supervised!(
        {Runtime,
         handler: ServerHandler, handler_args: [test_pid: self()], transport: :mounted_http}
      )

    {:ok, _pid} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [
          runtime: runtime,
          handler_opts: fn _conn -> %{socket: self()} end,
          path: "/mcp",
          protocol_mode: :modern_only,
          mrtr: true,
          request_state: [
            active_key_id: "nonblocking",
            keys: %{"nonblocking" => :binary.copy(<<7>>, 32)}
          ],
          allowed_origins: ["http://127.0.0.1:#{port}"]
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        protocol_version: @version,
        capabilities: %{"elicitation" => %{"form" => %{}}},
        handler: {ClientHandler, [test_pid: self()]},
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> stop(client) end)
    client
  end

  # A scripted modern server, for responses the Runtime doesn't give.
  defp start_bypass_client(opts \\ []) do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      if is_map_key(message, "method"), do: send(test_pid, {:posted, message["method"]})
      respond(conn, message, test_pid)
    end)

    {:ok, client} =
      Client.start_link(
        [
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          protocol_mode: :modern_only,
          protocol_version: @version,
          health_check_interval: nil,
          reconnect: false
        ] ++ opts
      )

    # Establishment's probe is not part of what the tests look at.
    assert_receive {:posted, "server/discover"}
    on_exit(fn -> stop(client) end)
    client
  end

  defp respond(conn, %{"method" => "server/discover", "id" => id}, _test_pid) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "supportedVersions" => [@version],
        "capabilities" => %{"tools" => %{}},
        "ttlMs" => 0,
        "cacheScope" => "private",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{"name" => "scripted", "version" => "1"}
        }
      }
    })
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, _test_pid) do
    case params["name"] do
      "quick" ->
        json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => complete()})

      "protected" ->
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh"],
          do: json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => complete()}),
          else: challenge(conn, ~s(Bearer realm="mcp"))

      "basic" ->
        challenge(conn, ~s(Basic realm="mcp"))

      "bearer" ->
        challenge(conn, "Bearer")
    end
  end

  defp respond(conn, %{"method" => _notification}, _test_pid), do: Plug.Conn.resp(conn, 202, "")

  defp challenge(conn, www_authenticate) do
    conn
    |> Plug.Conn.put_resp_header("www-authenticate", www_authenticate)
    |> Plug.Conn.resp(401, "")
  end

  defp complete, do: %{"resultType" => "complete", "content" => []}

  defp encoded_call(id) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "protected", "arguments" => %{}}
    })
  end

  defp modern_transport(port \\ 1) do
    {:ok, transport} =
      HTTP.connect(url: "http://127.0.0.1:#{port}/mcp", protocol_version: @version)

    HTTP.settle_protocol_era(transport, :modern, @version)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp stop(client) do
    if Process.alive?(client) do
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
