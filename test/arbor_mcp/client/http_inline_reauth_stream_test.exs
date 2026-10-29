defmodule Arbor.MCP.Client.HTTPInlineReauthStreamTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbor.MCP.Client
  alias Arbor.MCP.TestHelpers
  alias Arbor.MCP.Transport.HTTP

  defmodule Handler do
    @moduledoc false
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :owner)}
    @impl true
    def handle_ping(owner), do: {:ok, %{}, owner}
    @impl true
    def handle_list_roots(owner), do: {:ok, [], owner}
    @impl true
    def handle_create_message(_params, owner), do: {:error, "unused", owner}

    @impl true
    def handle_progress(id, params, owner) do
      send(owner, {:progress, id, params})
      {:ok, owner}
    end

    @impl true
    def handle_log_message(id, params, owner) do
      send(owner, {:log, id, params})
      {:ok, owner}
    end
  end

  defmodule HealthProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider
    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner), token: nil}}
    @impl true
    def get_token(state), do: {:ok, state.token, state}
    @impl true
    def handle_unauthorized(_www, _scopes, state) do
      send(state.owner, :health_provider_authenticated)
      {:ok, "token-1", %{state | token: "token-1"}}
    end

    @impl true
    def handle_forbidden(www, scopes, state), do: handle_unauthorized(www, scopes, state)
  end

  for kind <- [:notification, :reply] do
    @tag :reauth_round8
    test "a synchronous #{kind} retains credential retirement before the next request" do
      kind = unquote(kind)
      {client, counter} = start_client(&finish/2, era: :modern, synchronous_refusal: kind)
      assert {:ok, _} = Task.await(call(client))
      before = :sys.get_state(client).transport_state

      if kind == :notification do
        assert :ok = Client.notify(client, "notifications/protected", %{})
      else
        request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => "server-ping", "method" => "ping"})
        send(client, {:transport_message, request})
      end

      assert_receive {:synchronous_refusal, ^kind}, 2_000
      after_refusal = :sys.get_state(client).transport_state
      assert after_refusal.access_token == nil
      assert after_refusal.rejected_generation == before.credential_generation
      assert {:ok, _} = Task.await(call(client))
      assert Agent.get(counter, & &1.tokens) == 2
      assert :sys.get_state(client).transport_state.access_token == "token-2"
    end
  end

  @tag :reauth_round8
  test "cached static credentials fail definitively through client retries and subscription opening" do
    {client, counter} =
      start_client(&finish/2,
        era: :modern,
        auth_provider: {Arbor.MCP.Authorization.Provider.Static, token: "token-1"},
        reject_static: true
      )

    assert {:error, %{reason: {:authentication_failed, :unauthorized}}} =
             Client.call_tool(client, "protected", %{"reject_static" => true}, format: :map)

    retired = :sys.get_state(client).transport_state
    assert retired.access_token == nil

    assert {:error, %{reason: {:authentication_failed, :rejected_credential}}} =
             Client.call_tool(client, "protected", %{},
               format: :map,
               retry_policy: [max_attempts: 3, initial_delay: 0, should_retry?: fn _ -> true end]
             )

    assert {:error,
            {:stream_error, {:auth_refused, {:authentication_failed, :rejected_credential}}}} =
             Client.listen(client, %{"toolsListChanged" => true})

    assert :sys.get_state(client).transport_state.credential_generation ==
             retired.credential_generation

    assert [[[_bearer]]] = Agent.get(counter, &Map.values(&1.posts))
    assert Agent.get(counter, & &1.tokens) == 0
  end

  for kind <- [:post, :request] do
    @tag :reauth_round8
    test "an oversized 403 still performs the required scope step-up for #{kind}" do
      {client, counter} =
        start_client(&finish/2, era: :modern, oversized_auth: :length, oversized_status: 403)

      assert {:ok, _} = Task.await(call(client))

      :sys.replace_state(client, fn state ->
        %{state | transport_state: %{state.transport_state | max_response_bytes: 512}}
      end)

      opts = if unquote(kind) == :request, do: [progress_token: "oversized-403"], else: []
      assert {:ok, _} = Client.call_tool(client, "protected", %{"oversized" => true}, opts)
      assert Agent.get(counter, & &1.tokens) == 2
      assert :sys.get_state(client).transport_state.access_token == "token-2"
    end
  end

  for {era, kind} <- [
        {:legacy, :post},
        {:modern, :post},
        {:modern, :request},
        {:modern, :subscription}
      ],
      framing <- [:length, :chunked] do
    @tag :reauth_round8
    test "oversized 401 retires credentials on #{era} #{kind} with #{framing} framing" do
      {client, counter} =
        start_client(&finish/2, era: unquote(era), oversized_auth: unquote(framing))

      assert {:ok, _} = Task.await(call(client))
      before = :sys.get_state(client).transport_state

      :sys.replace_state(client, fn state ->
        %{state | transport_state: %{state.transport_state | max_response_bytes: 512}}
      end)

      result =
        case unquote(kind) do
          :subscription ->
            Client.listen(client, %{"toolsListChanged" => true}, timeout: 2_000)

          kind ->
            opts = if kind == :request, do: [progress_token: "oversized-auth"], else: []

            Client.call_tool(
              client,
              "protected",
              %{"oversized" => true},
              Keyword.merge([format: :map, timeout: 2_000], opts)
            )
        end

      if unquote(kind) == :subscription do
        assert {:error, {:stream_error, {:auth_refused, {:unauthorized, 401, _, "Basic"}}}} =
                 result
      else
        assert {:error, %{reason: {:unauthorized, 401, _, "Basic"}}} = result
      end

      after_refusal = :sys.get_state(client).transport_state
      assert after_refusal.access_token == nil
      assert after_refusal.rejected_generation == before.credential_generation
      state = Agent.get(counter, & &1)
      assert state.tokens == 1

      assert Enum.sort(Map.values(state.posts)) ==
               Enum.sort([[[], ["Bearer token-1"]], [["Bearer token-1"]]])

      refute_received {:ex_mcp_subscription_resync, _, :started}
    end
  end

  for {era, stream?} <- [{:legacy, false}, {:modern, false}, {:modern, true}] do
    @tag :reauth_round7
    test "the exhausted 401 retires B before a new #{era} request (stream: #{stream?})" do
      {client, counter} =
        start_client(&finish/2, era: unquote(era), step_up: true, reject_final: true)

      opts = if unquote(stream?), do: [progress_token: "terminal-401"], else: []
      task = call(client, opts)
      assert_receive {:terminal_401, server, id}, 2_000
      on_exit(fn -> send(server, :reject) end)
      b = :sys.get_state(client).transport_state
      assert b.access_token == "token-2"
      send(server, :reject)
      assert {:error, %{reason: {:unauthorized, 401, "", _}}} = Task.await(task)
      assert :sys.get_state(client).transport_state.access_token == nil
      assert :sys.get_state(client).transport_state.granted_scopes == []
      assert {:ok, _} = Task.await(call(client, opts))
      state = Agent.get(counter, & &1)
      assert state.tokens == 3
      assert state.posts[id] == [[], ["Bearer token-1"], ["Bearer token-2"]]
      assert [next] = state.posts |> Map.delete(id) |> Map.values()
      assert next == [[], ["Bearer token-3"]]
    end
  end

  @tag :reauth_round7
  test "synchronous inline auth retires the final 401 credential" do
    {client, counter} = start_client(&finish/2, step_up: true, reject_final: true)
    transport = :sys.get_state(client).transport_state
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => "sync", "method" => "tools/call"})
    task = Task.async(fn -> HTTP.send_authenticated(request, transport) end)
    assert_receive {:terminal_401, server, "sync"}, 2_000
    on_exit(fn -> send(server, :reject) end)
    send(server, :reject)
    assert {:error, {:unauthorized, 401, "", _}, retired} = Task.await(task)
    assert retired.access_token == nil
    assert retired.granted_scopes == []
    assert retired.credential_generation == retired.rejected_generation
    assert retired.rejected_generation > 0
    assert Agent.get(counter, & &1.tokens) == 2
    assert Agent.get(counter, & &1.posts["sync"]) == [[], ["Bearer token-1"], ["Bearer token-2"]]
  end

  @tag :reauth_round5
  test "a 401 joining a step-up retires the shared token before the partial grant arrives" do
    {client, counter} =
      start_client(&finish/2,
        scoped_step_up: true,
        base_scopes: ["read", "write"],
        partial_grant: ["read"],
        reject_read_token: true,
        hold_step_up_metadata: true
      )

    assert {:ok, _} = Client.call_tool(client, "protected", %{"need" => "write"})

    admin = scoped_call(client, "admin")
    assert_receive {:scope_challenge, "admin", server, _id}, 2_000
    send(server, :challenge)
    assert_receive {:metadata_stalled, metadata}, 2_000
    on_exit(fn -> send(metadata, :release) end)

    read = scoped_call(client, "read")
    TestHelpers.wait_until(fn -> map_size(:sys.get_state(client).http_auth.waiters) == 2 end)
    rejected_transport = :sys.get_state(client).transport_state
    later = scoped_call(client, "read")
    TestHelpers.wait_until(fn -> map_size(:sys.get_state(client).http_auth.waiters) == 3 end)
    send(metadata, :release)

    assert {:error, %{reason: {:oauth_failed, :insufficient_scope}}} = Task.await(admin)
    assert {:ok, _} = Task.await(read)
    assert {:ok, _} = Task.await(later)
    assert rejected_transport.access_token == nil

    refute Enum.any?(rejected_transport.headers, fn {key, _} ->
             String.downcase(key) == "authorization"
           end)

    transport = :sys.get_state(client).transport_state
    assert transport.access_token == "token-2"
    assert transport.granted_scopes == ["read"]
    assert {:ok, _} = Client.call_tool(client, "protected", %{"need" => "read"})
    state = Agent.get(counter, & &1)
    assert state.tokens == 2
    assert Enum.count(Map.values(state.posts), &(&1 == [[], ["Bearer token-2"]])) == 1
    assert Enum.count(Map.values(state.posts), &(&1 == [["Bearer token-2"]])) == 1
    refute_received {:metadata_stalled, _}
  end

  @tag :reauth_round5
  test "a delayed 401 for an already replaced token keeps the newer shared credentials" do
    {client, counter} =
      start_client(&finish/2,
        scoped_step_up: true,
        base_scopes: ["read", "write"],
        reject_read_token: true,
        hold_read_401: true
      )

    assert {:ok, _} = Client.call_tool(client, "protected", %{"need" => "write"})
    read = scoped_call(client, "read")
    assert_receive {:read_401_held, server}, 2_000
    on_exit(fn -> send(server, :challenge) end)
    assert {:ok, _} = Client.call_tool(client, "protected", %{"need" => "admin"})
    assert :sys.get_state(client).transport_state.access_token == "token-2"
    send(server, :challenge)
    assert {:ok, _} = Task.await(read)
    transport = :sys.get_state(client).transport_state
    assert transport.access_token == "token-2"
    assert Enum.sort(transport.granted_scopes) == ["admin", "read", "write"]
    assert Agent.get(counter, & &1.tokens) == 2
  end

  @tag :reauth_round5
  test "a provider-less subscription reports a Basic refusal after one POST" do
    {client, counter} =
      start_client(&finish/2, era: :modern, seed: false, challenge: ~s(Basic realm="closed"))

    assert {:error,
            {:stream_error, {:auth_refused, {:unauthorized, 401, "", ~s(Basic realm="closed")}}}} =
             Client.listen(client, %{"toolsListChanged" => true}, timeout: 1_000)

    assert [posts] = Agent.get(counter, &Map.values(&1.posts))
    assert posts == [[]]
    assert :sys.get_state(client).subscriptions == %{}
    refute_received {:ex_mcp_subscription_resync, _, :started}
  end

  @tag :reauth_round5
  test "an insufficient subscription grant reports refusal without reopening or another flow" do
    {client, counter} =
      start_client(&finish/2,
        era: :modern,
        scoped_step_up: true,
        narrow_step_up: true,
        subscription_scope: "admin"
      )

    assert {:error, {:stream_error, {:auth_refused, {:oauth_failed, :insufficient_scope}}}} =
             Client.listen(client, %{"toolsListChanged" => true}, timeout: 1_000)

    assert [posts] = Agent.get(counter, &Map.values(&1.posts))
    assert posts == [[], ["Bearer token-1"]]
    assert Agent.get(counter, & &1.tokens) == 2
    assert :sys.get_state(client).subscriptions == %{}
    refute_received {:ex_mcp_subscription_resync, _, :started}
  end

  @tag :reauth_round3
  test "overlapping 403 step-ups each get their own scope before their last POST retry" do
    {client, counter} =
      start_client(&finish/2, barrier: true, scoped_step_up: true, hold_step_up_metadata: true)

    tasks =
      for scope <- ["alpha", "beta"],
          do:
            Task.async(fn ->
              Client.call_tool(client, "protected", %{"need" => scope},
                timeout: 10_000,
                format: :map
              )
            end)

    Enum.each(for(_ <- 1..2, do: receive_challenge()), &send(&1, :challenge))

    challenges =
      for _ <- 1..2, into: %{} do
        assert_receive {:scope_challenge, scope, server, id}, 2_000
        {scope, {server, id}}
      end

    {alpha, alpha_id} = challenges["alpha"]
    {beta, beta_id} = challenges["beta"]
    send(alpha, :challenge)
    assert_receive {:metadata_stalled, first}, 2_000
    on_exit(fn -> send(first, :release) end)
    send(beta, :challenge)
    TestHelpers.wait_until(fn -> map_size(:sys.get_state(client).http_auth.waiters) == 2 end)
    send(first, :release)
    assert_receive {:metadata_stalled, second}, 2_000
    send(second, :release)

    assert [{:ok, _}, {:ok, _}] = Task.await_many(tasks)
    state = Agent.get(counter, & &1)
    assert state.tokens == 3
    assert state.posts[alpha_id] == [[], ["Bearer token-1"], ["Bearer token-2"]]
    assert state.posts[beta_id] == [[], ["Bearer token-1"], ["Bearer token-3"]]
    assert "alpha" in state.grants["token-2"]
    assert "beta" in state.grants["token-3"]
    refute_received {:wrong_scope_retry, _, _}
  end

  @tag :reauth_round3
  test "an incompatible step-up expires in the queue without starting another flow" do
    {client, counter} =
      start_client(&finish/2, barrier: true, scoped_step_up: true, hold_step_up_metadata: true)

    alpha =
      Task.async(fn ->
        Client.call_tool(client, "protected", %{"need" => "alpha"}, timeout: 5_000)
      end)

    beta =
      Task.async(fn ->
        Client.call_tool(client, "protected", %{"need" => "beta"}, timeout: 1_000)
      end)

    Enum.each(for(_ <- 1..2, do: receive_challenge()), &send(&1, :challenge))

    challenges =
      for _ <- 1..2, into: %{} do
        assert_receive {:scope_challenge, scope, server, id}, 2_000
        {scope, {server, id}}
      end

    {first, _} = challenges["alpha"]
    {second, beta_id} = challenges["beta"]
    send(first, :challenge)
    assert_receive {:metadata_stalled, metadata}, 2_000
    on_exit(fn -> send(metadata, :release) end)
    send(second, :challenge)
    TestHelpers.wait_until(fn -> map_size(:sys.get_state(client).http_auth.waiters) == 2 end)

    {_ref, {post, ^beta_id}} =
      Enum.find(:sys.get_state(client).async_post_tasks, fn {_ref, {_pid, id}} ->
        id == beta_id
      end)

    monitor = Process.monitor(post)
    worker = :sys.get_state(client).http_auth.worker.pid
    assert {:error, :timeout} = Task.await(beta, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^post, _}, 2_000
    assert Process.alive?(worker)
    send(metadata, :release)
    assert {:ok, _} = Task.await(alpha, 2_000)
    assert Agent.get(counter, & &1.tokens) == 2
    assert Agent.get(counter, & &1.posts[beta_id]) == [[], ["Bearer token-1"]]
    refute_received {:metadata_stalled, _}
  end

  @tag :reauth_round3
  @tag :reauth_round4
  test "an insufficient grant fails definitively without consuming the last POST retry" do
    {client, counter} = start_client(&finish/2, scoped_step_up: true, narrow_step_up: true)

    assert {:error, %{reason: {:oauth_failed, :insufficient_scope}}} =
             Client.call_tool(client, "protected", %{"need" => "alpha"},
               timeout: 1_000,
               format: :map
             )

    state = Agent.get(counter, & &1)
    assert state.tokens == 2
    assert state.grants["token-2"] == ["tools.call"]
    assert [headers] = Map.values(state.posts)
    assert headers == [[], ["Bearer token-1"]]
    assert :sys.get_state(client).http_auth.worker == nil
    assert :sys.get_state(client).http_auth.waiters == %{}
    refute_received {:wrong_scope_retry, _, _}
  end

  @tag :reauth_round4
  test "a narrower step-up grant preserves shared write credentials and does not loop flows" do
    {client, counter} =
      start_client(&finish/2,
        scoped_step_up: true,
        base_scopes: ["read", "write"],
        partial_grant: ["read"],
        hold_step_up_metadata: true
      )

    admin =
      Task.async(fn ->
        Client.call_tool(client, "protected", %{"need" => "admin"}, timeout: 1_000, format: :map)
      end)

    assert_receive {:scope_challenge, "admin", server, admin_id}, 2_000
    send(server, :challenge)
    assert_receive {:metadata_stalled, metadata}, 2_000
    on_exit(fn -> send(metadata, :release) end)
    state = :sys.get_state(client)
    assert state.transport_state.access_token == "token-1"
    assert state.transport_state.granted_scopes == ["read", "write"]
    monitor = Process.monitor(state.http_auth.worker.pid)
    send(metadata, :release)
    assert_receive {:DOWN, ^monitor, :process, _worker, _}, 2_000

    state = :sys.get_state(client)
    assert state.transport_state.access_token == "token-1"
    assert state.transport_state.granted_scopes == ["read", "write"]

    assert {:ok, _} =
             Client.call_tool(client, "protected", %{"need" => "write"},
               timeout: 1_000,
               format: :map
             )

    assert {:error, %{reason: {:oauth_failed, :insufficient_scope}}} = Task.await(admin, 1_500)
    state = Agent.get(counter, & &1)
    assert state.tokens == 2
    assert state.grants["token-2"] == ["read"]
    assert state.posts[admin_id] == [[], ["Bearer token-1"]]
    assert [write_headers] = state.posts |> Map.delete(admin_id) |> Map.values()
    assert write_headers == [["Bearer token-1"]]
    assert :sys.get_state(client).http_auth.worker == nil
    assert :sys.get_state(client).http_auth.waiters == %{}
    refute_received {:metadata_stalled, _}
    refute_received {:wrong_scope_retry, _, _}
  end

  @tag :reauth_round4
  test "a superset step-up grant replaces shared credentials and their granted scopes" do
    {client, counter} =
      start_client(&finish/2, scoped_step_up: true, base_scopes: ["read", "write"])

    assert {:ok, _} = Client.call_tool(client, "protected", %{"need" => "admin"}, format: :map)
    state = :sys.get_state(client)
    assert state.transport_state.access_token == "token-2"
    assert state.transport_state.granted_scopes == ["read", "write", "admin"]
    assert Agent.get(counter, & &1.tokens) == 2
    refute_received {:wrong_scope_retry, _, _}
  end

  @tag :reauth_round4
  test "a 401 flow may replace rejected credentials with a narrower valid token" do
    {client, counter} =
      start_client(&finish/2,
        scoped_step_up: true,
        base_scopes: ["read", "write"],
        reject_read_token: true
      )

    assert {:ok, _} = Client.call_tool(client, "protected", %{"need" => "write"}, format: :map)
    assert :sys.get_state(client).transport_state.granted_scopes == ["read", "write"]
    assert {:ok, _} = Client.call_tool(client, "protected", %{"need" => "read"}, format: :map)
    state = :sys.get_state(client)
    assert state.transport_state.access_token == "token-2"
    assert state.transport_state.granted_scopes == ["read"]
    assert Agent.get(counter, & &1.tokens) == 2
  end

  for provider <- [:inline, :provider] do
    @health_provider provider
    @tag :reauth_round3
    test "a retained HTTP health ping authenticates through #{@health_provider} without reconnecting" do
      opts =
        if @health_provider == :inline,
          do: [hold_metadata: true],
          else: [seed: false, auth_provider: {HealthProvider, owner: self()}]

      {client, _counter} =
        start_client(&finish/2, Keyword.merge(opts, retained: true, reconnect: true))

      assert_receive {:retained_stream, stream}, 2_000
      on_exit(fn -> send(stream, :release) end)
      owner = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        handler,
        [[:arbor_mcp, :client, :disconnected], [:arbor_mcp, :client, :reconnect, :attempt]],
        fn event, _, _, _ -> if self() == client, do: send(owner, {:health_lifecycle, event}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :sys.replace_state(client, &%{&1 | health_check_interval: 5_000})
      send(client, :health_check)

      if @health_provider == :inline do
        assert_receive {:metadata_stalled, metadata}, 2_000
        on_exit(fn -> send(metadata, :release) end)
        state = :sys.get_state(client)
        assert state.pending_requests == %{}
        assert [waiter] = Map.values(state.http_auth.waiters)
        assert waiter.request_id == state.health_check_id
        assert (waiter.deadline - System.monotonic_time(:millisecond)) in 1..5_000
        send(metadata, :release)
      else
        assert_receive :health_provider_authenticated, 2_000
      end

      assert_receive {:healthy_ping, first}, 2_000
      TestHelpers.wait_until(fn -> :sys.get_state(client).health_check_id == nil end)
      send(client, :health_check)
      assert_receive {:healthy_ping, second}, 2_000
      assert second != first
      TestHelpers.wait_until(fn -> :sys.get_state(client).health_check_id == nil end)
      assert Client.get_pending_requests(client) == []
      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
      refute_received {:health_lifecycle, _}
    end
  end

  test "a legacy POST reauthenticated by inline OAuth answers a ping before its result" do
    ping = %{"jsonrpc" => "2.0", "id" => "server-ping", "method" => "ping", "params" => %{}}
    {client, counter} = start_client(hold_after([ping]))

    task = call(client)
    assert_receive {:holding, server}, 2_000
    assert_oauth_worker(client)
    assert_receive {:client_answered, "server-ping", %{"result" => %{}}}, 2_000
    send(server, :release)

    assert {:ok, %{"content" => []}} = Task.await(task)
    assert_one_flow(counter, client)
  end

  test "progress and logs on a reauthenticated legacy POST arrive before its result" do
    notifications = [
      notification("notifications/progress", %{"progressToken" => "progress", "progress" => 1}),
      notification("notifications/message", %{"level" => "info", "data" => "working"})
    ]

    {client, counter} = start_client(hold_after(notifications))
    task = call(client, progress_token: "progress")

    assert_receive {:holding, server}, 2_000
    assert_receive {:progress, id, %{"progressToken" => "progress", "progress" => 1}}, 2_000
    assert is_integer(id)
    # Legacy log notifications carry no request id on the wire.
    assert_receive {:log, nil, %{"data" => "working"}}, 2_000
    send(server, :release)

    assert {:ok, %{"content" => []}} = Task.await(task)
    assert_one_flow(counter, client)
  end

  test "two concurrent legacy 401s run one inline OAuth flow and reuse its token" do
    {client, counter} = start_client(&finish/2, barrier: true)
    tasks = for _ <- 1..2, do: call(client)

    # Both requests were sent without a token before either challenge is answered.
    servers = for _ <- 1..2, do: receive_challenge()
    Enum.each(servers, &send(&1, :challenge))

    assert [{:ok, _}, {:ok, _}] = Task.await_many(tasks)
    assert_oauth_worker(client)
    refute_received {:oauth_started, _}
    assert_one_flow(counter, client)

    posts = Agent.get(counter, & &1.posts)
    assert map_size(posts) == 2
    assert Enum.all?(posts, fn {_id, headers} -> headers == [[], ["Bearer token-1"]] end)
  end

  test "a legacy request cancelled before its challenge is not authenticated or re-sent" do
    {client, counter} = start_client(&finish/2, barrier: true)
    task = call(client)
    server = receive_challenge()
    [id] = Client.get_pending_requests(client)

    {_ref, {post_task, ^id}} =
      Enum.find(:sys.get_state(client).async_post_tasks, fn {_ref, {_pid, request_id}} ->
        request_id == id
      end)

    monitor = Process.monitor(post_task)
    assert :ok = Client.send_cancelled(client, id, "test cancellation")
    assert {:error, :cancelled} = Task.await(task)
    send(server, :challenge)
    assert_receive {:DOWN, ^monitor, :process, ^post_task, :normal}, 2_000
    assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

    assert Agent.get(counter, & &1.tokens) == 0
    assert Agent.get(counter, & &1.posts) == %{id => [[]]}
    refute_received {:oauth_started, _}
  end

  for opt <- [
        [progress_token: "progress"],
        [meta: %{"io.modelcontextprotocol/logLevel" => "info"}]
      ] do
    @stream_opt opt
    test "a provider-less modern request stream authenticates with #{inspect(opt)}" do
      message =
        if @stream_opt[:progress_token],
          do:
            notification("notifications/progress", %{
              "progressToken" => "progress",
              "progress" => 1
            }),
          else: notification("notifications/message", %{"level" => "info", "data" => "working"})

      {client, counter} = start_client(hold_after([message]), era: :modern)
      task = call(client, @stream_opt)

      assert_oauth_worker(client)
      assert_receive {:holding, server}, 2_000

      if @stream_opt[:progress_token] do
        assert_receive {:progress, id, %{"progress" => 1}}, 2_000
        assert is_integer(id)
      else
        assert_receive {:log, id, %{"data" => "working"}}, 2_000
        assert is_integer(id)
      end

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
      send(server, :release)

      assert {:ok, %{"resultType" => "complete", "content" => []}} = Task.await(task)
      assert_one_flow(counter, client)
    end
  end

  test "a legacy inline flow can step up once on a retried POST" do
    {client, counter} = start_client(&finish/2, step_up: true)
    assert {:ok, %{"content" => []}} = Task.await(call(client))
    assert Agent.get(counter, & &1.tokens) == 2
    assert :sys.get_state(client).transport_state.granted_scopes == ["tools.call", "admin"]
    assert :sys.get_state(client).transport_state.access_token == "token-2"
  end

  test "a legacy POST stops after an initial challenge and one scope step-up" do
    {client, counter} = start_client(&finish/2, step_up: true, reject_retries: true)

    assert {:error, %{type: :transport_error, transport: :http, reason: {:http_error, 403, ""}}} =
             Task.await(call(client))

    assert Agent.get(counter, & &1.tokens) == 2
    assert [headers] = Agent.get(counter, &Map.values(&1.posts))
    assert headers == [[], ["Bearer token-1"], ["Bearer token-2"]]
  end

  test "a provider-less legacy POST waits for authentication only until its deadline" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      challenge(conn, 401, "Bearer")
    end)

    {:ok, transport} = HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)
    transport = HTTP.settle_protocol_era(transport, :legacy, "2025-11-25")
    transport = HTTP.put_deadline(transport, System.monotonic_time(:millisecond) + 1_000)
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call"})

    assert {:ok, _} = HTTP.send_async(request, transport)
    assert_receive {:async_post_task, monitor, task, 7}, 2_000
    assert_receive {:http_post_auth_challenge, ^task, ref, %{token: nil}}, 2_000

    assert_receive {:async_post_result, {:error, {:auth_refused, :timeout}}, %{request_id: 7}},
                   2_000

    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, 2_000

    send(task, {:http_post_auth_result, ref, {:ok, "too-late"}})
  end

  for stream_opts <- [
        [],
        [progress_token: "stalled"],
        [meta: %{"io.modelcontextprotocol/logLevel" => "info"}]
      ] do
    @stalled_opts stream_opts
    @tag :reauth_round2
    test "stalled inline metadata leaves the client responsive with #{inspect(stream_opts)}" do
      {client, counter} = start_client(&finish/2, era: :modern, hold_metadata: true)
      task = call(client, Keyword.merge(@stalled_opts, timeout: 1_000))
      assert_receive {:metadata_stalled, metadata}, 2_000
      on_exit(fn -> send(metadata, :release) end)
      assert_receive {:oauth_started, worker}, 2_000
      assert worker != client
      monitor = Process.monitor(worker)

      status = Task.async(fn -> Client.get_status(client) end)
      assert {:ok, %{connection_status: :ready}} = Task.await(status, 500)
      assert {:ok, _} = Client.ping(client, timeout: 500)
      assert {:error, :timeout} = Task.await(task, 2_000)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)
      assert Agent.get(counter, & &1.tokens) == 0
    end
  end

  @tag :reauth_round2
  test "concurrent challenges share a stalled worker but retain their own deadlines" do
    {client, counter} = start_client(&finish/2, era: :modern, hold_metadata: true, barrier: true)
    short = call(client, timeout: 1_500)
    long = call(client, timeout: 4_000, progress_token: "long")
    servers = for _ <- 1..2, do: receive_challenge()
    Enum.each(servers, &send(&1, :challenge))
    assert_receive {:metadata_stalled, metadata}, 2_000
    on_exit(fn -> send(metadata, :release) end)
    assert_receive {:oauth_started, worker}, 2_000

    TestHelpers.wait_until(fn -> map_size(:sys.get_state(client).http_auth.waiters) == 2 end)

    short_waiter =
      :sys.get_state(client).http_auth.waiters |> Map.values() |> Enum.find(&(&1.kind == :post))

    short_monitor = Process.monitor(short_waiter.pid)
    assert {:ok, _} = Client.ping(client, timeout: 500)
    assert {:error, :timeout} = Task.await(short, 2_000)
    assert_receive {:DOWN, ^short_monitor, :process, _post, _reason}, 2_000
    assert Process.alive?(worker)
    assert {:ok, %{pending_requests: 1}} = Client.get_status(client)
    send(metadata, :release)

    assert {:ok, _} = Task.await(long, 3_000)
    assert Agent.get(counter, & &1.tokens) == 1
    refute_received {:oauth_started, _}

    assert Agent.get(counter, &Map.values(&1.posts)) |> Enum.sort() ==
             Enum.sort([[[]], [[], ["Bearer token-1"]]])
  end

  @tag :reauth_round2
  test "a failed shared inline flow fails every queued challenger without replay" do
    {client, counter} =
      start_client(&finish/2, era: :modern, hold_metadata: true, barrier: true, token_error: true)

    tasks = [
      call(client, format: :struct),
      call(client, progress_token: "failed", format: :struct)
    ]

    servers = for _ <- 1..2, do: receive_challenge()
    Enum.each(servers, &send(&1, :challenge))
    assert_receive {:metadata_stalled, metadata}, 2_000
    on_exit(fn -> send(metadata, :release) end)
    assert_oauth_worker(client)
    TestHelpers.wait_until(fn -> map_size(:sys.get_state(client).http_auth.waiters) == 2 end)
    send(metadata, :release)

    for result <- Task.await_many(tasks) do
      assert {:error, %Arbor.MCP.Error.TransportError{reason: {:oauth_failed, _}}} = result
    end

    assert Agent.get(counter, & &1.tokens) == 1
    assert Agent.get(counter, &Map.values(&1.posts)) == [[[]], [[]]]
    assert :sys.get_state(client).http_auth.waiters == %{}
    refute_received {:oauth_started, _}
  end

  @tag :reauth_round2
  test "cancelling the last challenged request kills the stalled inline worker" do
    {client, counter} = start_client(&finish/2, era: :modern, hold_metadata: true)
    task = call(client, progress_token: "cancel-flow")
    assert_receive {:metadata_stalled, metadata}, 2_000
    on_exit(fn -> send(metadata, :release) end)
    assert_receive {:oauth_started, worker}, 2_000
    monitor = Process.monitor(worker)
    [id] = Client.get_pending_requests(client)
    assert :ok = Client.send_cancelled(client, id, "cancel stalled authorization")
    assert {:error, :cancelled} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
    assert Agent.get(counter, & &1.tokens) == 0
    assert :sys.get_state(client).http_auth.worker == nil
    assert :sys.get_state(client).http_auth.waiters == %{}
  end

  @tag :reauth_round2
  test "reconnecting kills the inline worker and retires its waiters and results" do
    {client, counter} =
      start_client(&finish/2, era: :modern, hold_metadata: true, reconnect: true)

    task = call(client, progress_token: "reconnect")
    assert_receive {:metadata_stalled, metadata}, 2_000
    on_exit(fn -> send(metadata, :release) end)
    assert_receive {:oauth_started, worker}, 2_000
    monitor = Process.monitor(worker)
    auth_worker = :sys.get_state(client).http_auth.worker
    send(client, {:transport_closed, :test_reconnect})

    assert {:error, _} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000

    TestHelpers.wait_until(fn ->
      match?({:ok, %{connection_status: :ready}}, Client.get_status(client))
    end)

    send(metadata, :release)

    send(
      client,
      {:http_inline_auth_result, worker, auth_worker.id, {:ok, "stale-token", ["admin"]}}
    )

    assert {:ok, _} = Client.ping(client, timeout: 500)
    state = :sys.get_state(client)
    assert state.transport_state.access_token == nil
    assert state.http_auth.worker == nil
    assert state.http_auth.waiters == %{}
    assert Agent.get(counter, & &1.tokens) == 0
  end

  @tag :reauth_round2
  test "a legacy challenge retries with the current session and connection headers" do
    bypass = Bypass.open()
    owner = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      cond do
        request["method"] == "ping" ->
          conn |> Plug.Conn.put_resp_header("mcp-session-id", "rotated") |> json(response(8, %{}))

        Plug.Conn.get_req_header(conn, "authorization") == [] ->
          challenge(conn, 401, "Bearer")

        true ->
          send(
            owner,
            {:retried_headers, Plug.Conn.get_req_header(conn, "mcp-session-id"),
             Plug.Conn.get_req_header(conn, "x-current")}
          )

          json(conn, response(7, %{"content" => []}))
      end
    end)

    {:ok, transport} = HTTP.connect(url: "http://127.0.0.1:#{bypass.port}/mcp", use_sse: false)
    transport = HTTP.settle_protocol_era(transport, :legacy, "2025-11-25")
    transport = %{transport | session_id: "original"}
    request = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call"})
    assert {:ok, _} = HTTP.send_async(request, transport)
    assert_receive {:async_post_task, monitor, task, 7}, 2_000
    assert_receive {:http_post_auth_challenge, ^task, _ref, _challenge} = message, 2_000
    rotate = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 8, "method" => "ping"})
    assert {:ok, current, _} = HTTP.send_message(rotate, transport)
    assert current.session_id == "rotated"
    current = HTTP.put_oauth_token(current, %{access_token: "fresh"}, [])
    current = %{current | headers: [{"X-Current", "fresh"}]}

    state = %Client{
      transport_mod: HTTP,
      transport_state: current,
      pending_requests: %{7 => {{self(), make_ref()}, :single, "tools/call"}},
      async_post_tasks: %{monitor => {task, 7}}
    }

    assert {:noreply, _} = Client.handle_info(message, state)
    assert_receive {:async_post_result, {:ok, _, _}, %{request_id: 7}}, 2_000
    assert_received {:retried_headers, ["rotated"], ["fresh"]}
  end

  for {www_auth, status, reason} <- [
        {~s(Basic realm="mcp"), 401, :unauthorized},
        {~s(Basic realm="mcp"), 403, :http_error},
        {"Bearer", 401, :oauth_failed}
      ] do
    @refusal_header www_auth
    @refusal_status status
    @refusal_reason reason
    @tag :reauth_round2
    test "a no-config request stream treats #{@refusal_reason} as a definitive refusal" do
      {client, counter} =
        start_client(&finish/2,
          era: :modern,
          seed: false,
          challenge: @refusal_header,
          challenge_status: @refusal_status
        )

      assert {:error, %Arbor.MCP.Error.TransportError{reason: reason}} =
               Task.await(call(client, progress_token: "refused", format: :struct))

      case @refusal_reason do
        :unauthorized -> assert reason == {:unauthorized, 401, "", @refusal_header}
        :http_error -> assert reason == {:http_error, 403, ""}
        :oauth_failed -> assert {:oauth_failed, _} = reason
      end

      assert [headers] = Agent.get(counter, &Map.values(&1.posts))
      assert headers == [[]]
    end
  end

  defp receive_challenge do
    assert_receive {:unauthenticated, server}, 2_000
    server
  end

  defp assert_one_flow(counter, client) do
    assert Agent.get(counter, & &1.tokens) == 1
    transport = :sys.get_state(client).transport_state
    assert transport.auth_provider == nil
    assert transport.access_token == "token-1"
    assert :sys.get_state(client).http_auth.worker == nil
    assert :sys.get_state(client).http_auth.waiters == %{}
  end

  defp assert_oauth_worker(client) do
    assert_receive {:oauth_started, worker}, 2_000
    assert is_pid(worker)
    assert worker != client
  end

  defp call(client, opts \\ []) do
    Task.async(fn ->
      Client.call_tool(
        client,
        "protected",
        %{},
        Keyword.merge([timeout: 5_000, format: :map], opts)
      )
    end)
  end

  defp scoped_call(client, scope) do
    Task.async(fn ->
      Client.call_tool(client, "protected", %{"need" => scope}, timeout: 5_000, format: :map)
    end)
  end

  defp start_client(answer_call, opts \\ []) do
    bypass = Bypass.open()
    origin = "http://127.0.0.1:#{bypass.port}"
    era = Keyword.get(opts, :era, :legacy)
    version = if era == :legacy, do: "2025-11-25", else: "2026-07-28"
    owner = self()

    counter =
      start_supervised!({Agent, fn -> %{posts: %{}, codes: %{}, tokens: 0, grants: %{}} end})

    oauth_server(bypass, origin, counter, opts)

    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      if opts[:retained] do
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, "event: priming\ndata: \n\n")
        send(owner, {:retained_stream, self()})
        monitor = Process.monitor(owner)

        receive do
          :release -> :ok
          {:DOWN, ^monitor, :process, ^owner, _} -> :ok
        after
          30_000 -> :ok
        end

        Process.demonitor(monitor, [:flush])
        conn
      else
        Plug.Conn.resp(conn, 405, "")
      end
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 200, ""))

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"method" => method, "id" => id} when method in ["initialize", "server/discover"] ->
          conn =
            if opts[:retained],
              do: Plug.Conn.put_resp_header(conn, "mcp-session-id", "retained"),
              else: conn

          json(conn, response(id, establishment(era, version)))

        %{"method" => "ping"} = request ->
          protected_call(
            conn,
            request,
            counter,
            origin,
            owner,
            fn request, conn ->
              send(owner, {:healthy_ping, request["id"]})
              json(conn, response(request["id"], %{}))
            end,
            opts
          )

        %{"method" => method} = request when method in ["tools/call", "subscriptions/listen"] ->
          protected_call(conn, request, counter, origin, owner, answer_call, opts)

        %{"id" => id} = reply when not is_map_key(reply, "method") ->
          send(owner, {:client_answered, id, reply})
          synchronous_response(conn, :reply, owner, opts)

        _notification ->
          synchronous_response(conn, :notification, owner, opts)
      end
    end)

    client =
      start_supervised!(
        {Client,
         transport: :http,
         url: origin <> "/mcp",
         protocol_mode: if(era == :legacy, do: :legacy_only, else: :modern_only),
         protocol_version: version,
         handler: {Handler, owner: owner},
         use_sse: Keyword.get(opts, :retained, false),
         auth_provider: Keyword.get(opts, :auth_provider),
         health_check_interval: nil,
         reconnect: Keyword.get(opts, :reconnect, false),
         reconnect_backoff: [initial: 10, max: 10, multiplier: 1]}
      )

    # An :auth map auto-creates a provider. Seed only the inline flow's config
    # after establishment to exercise real authorization-code OAuth without one.
    # The no-config handoff itself is covered separately above: registration
    # requires explicit configuration and must not acquire insecure defaults.
    if Keyword.get(opts, :seed, true),
      do:
        :sys.replace_state(client, fn state ->
          config = %{
            client_id: "inline-client",
            client_secret: "inline-secret",
            credential_issuer: origin,
            metadata_fetch: [allow_insecure_loopback: true]
          }

          %{state | transport_state: %{state.transport_state | auth_config: config}}
        end)

    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:arbor_mcp, :auth, :flow, :started],
      fn _, _, _, _ ->
        send(owner, {:oauth_started, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {client, counter}
  end

  defp synchronous_response(conn, kind, owner, opts) do
    if opts[:synchronous_refusal] == kind do
      send(owner, {:synchronous_refusal, kind})
      challenge(conn, 401, "Basic")
    else
      Plug.Conn.resp(conn, 202, "")
    end
  end

  defp protected_call(conn, %{"id" => id} = request, counter, origin, owner, answer, opts) do
    authorization = Plug.Conn.get_req_header(conn, "authorization")

    attempt =
      Agent.get_and_update(counter, fn state ->
        posts = Map.update(state.posts, id, [authorization], &(&1 ++ [authorization]))
        {length(posts[id]), %{state | posts: posts}}
      end)

    case authorization do
      [] ->
        if opts[:barrier] && attempt == 1 do
          send(owner, {:unauthenticated, self()})

          receive do
            :challenge -> :ok
          after
            10_000 -> flunk("test did not release the challenge")
          end
        end

        challenge(
          conn,
          Keyword.get(opts, :challenge_status, 401),
          opts[:challenge] ||
            ~s(Bearer resource_metadata="#{origin}/prm", scope="#{base_scopes(opts)}")
        )

      ["Bearer " <> token] ->
        authenticated_call(conn, request, token, counter, origin, owner, answer, opts)
    end
  end

  defp authenticated_call(conn, request, token, counter, origin, owner, answer, opts) do
    cond do
      static_refusal?(request, opts) ->
        challenge(conn, 401, "Basic")

      oversized_request?(request, token, opts) ->
        oversized_auth_response(conn, origin, opts)

      opts[:reject_final] && token == "token-2" ->
        send(owner, {:terminal_401, self(), request["id"]})
        receive do: (:reject -> :ok)
        challenge(conn, 401, ~s(Bearer error="invalid_token"))

      opts[:reject_read_token] && token == "token-1" &&
          request["params"]["arguments"]["need"] == "read" ->
        if opts[:hold_read_401] do
          send(owner, {:read_401_held, self()})
          receive do: (:challenge -> :ok)
        end

        challenge(
          conn,
          401,
          ~s(Bearer error="insufficient_scope", resource_metadata="#{origin}/prm", scope="read")
        )

      opts[:scoped_step_up] ->
        scoped_step_up(conn, request, token, counter, origin, owner, answer, opts)

      true ->
        ordinary_authenticated_call(conn, request, token, origin, answer, opts)
    end
  end

  defp static_refusal?(request, opts),
    do: opts[:reject_static] && request["params"]["arguments"]["reject_static"]

  defp oversized_request?(request, token, opts),
    do:
      opts[:oversized_auth] && token == "token-1" &&
        (request["method"] == "subscriptions/listen" ||
           request["params"]["arguments"]["oversized"])

  defp oversized_auth_response(conn, origin, opts) do
    status = Keyword.get(opts, :oversized_status, 401)

    www =
      if status == 403,
        do:
          ~s(Bearer error="insufficient_scope", resource_metadata="#{origin}/prm", scope="tools.call admin"),
        else: "Basic"

    conn = Plug.Conn.put_resp_header(conn, "www-authenticate", www)
    body = String.duplicate("refused", 1_000)

    if opts[:oversized_auth] == :chunked do
      conn = Plug.Conn.send_chunked(conn, status)

      case Plug.Conn.chunk(conn, body) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    else
      Plug.Conn.resp(conn, status, body)
    end
  end

  defp ordinary_authenticated_call(conn, request, token, origin, answer, opts) do
    if opts[:reject_retries] || (opts[:step_up] && token == "token-1") do
      challenge(
        conn,
        403,
        ~s(Bearer error="insufficient_scope", resource_metadata="#{origin}/prm", scope="tools.call admin")
      )
    else
      allowed =
        if opts[:reject_final],
          do: ["token-1", "token-2", "token-3"],
          else: ["token-1", "token-2"]

      assert token in allowed
      answer.(request, conn)
    end
  end

  defp scoped_step_up(conn, request, token, counter, origin, owner, answer, opts) do
    scope = opts[:subscription_scope] || request["params"]["arguments"]["need"]

    if scope in Agent.get(counter, &Map.get(&1.grants, token, [])) do
      answer.(request, conn)
    else
      if token == "token-1" and opts[:hold_step_up_metadata] do
        send(owner, {:scope_challenge, scope, self(), request["id"]})
        receive do: (:challenge -> :ok)
      end

      if token != "token-1", do: send(owner, {:wrong_scope_retry, scope, token})

      challenge(
        conn,
        403,
        ~s(Bearer error="insufficient_scope", resource_metadata="#{origin}/prm", scope="#{base_scopes(opts)} #{scope}")
      )
    end
  end

  defp oauth_server(bypass, origin, counter, opts) do
    owner = self()

    Bypass.stub(bypass, "GET", "/prm", fn conn ->
      if opts[:hold_metadata] ||
           (opts[:hold_step_up_metadata] && Agent.get(counter, & &1.tokens) > 0) do
        send(owner, {:metadata_stalled, self()})
        monitor = Process.monitor(owner)

        receive do
          :release -> :ok
          {:DOWN, ^monitor, :process, ^owner, _} -> :ok
        after
          10_000 -> flunk("metadata was not released")
        end

        Process.demonitor(monitor, [:flush])
      end

      json(conn, %{"resource" => origin <> "/mcp", "authorization_servers" => [origin]})
    end)

    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      json(conn, %{
        "issuer" => origin,
        "authorization_endpoint" => origin <> "/authorize",
        "token_endpoint" => origin <> "/token",
        "grant_types_supported" => ["authorization_code"],
        "token_endpoint_auth_methods_supported" => ["client_secret_post"]
      })
    end)

    Bypass.stub(bypass, "GET", "/authorize", fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["code_challenge_method"] == "S256"

      code =
        Agent.get_and_update(counter, fn state ->
          code = "code-#{map_size(state.codes) + 1}"
          {code, %{state | codes: Map.put(state.codes, code, params)}}
        end)

      callback =
        params["redirect_uri"] <>
          "?" <> URI.encode_query(%{"code" => code, "state" => params["state"]})

      conn |> Plug.Conn.put_resp_header("location", callback) |> Plug.Conn.resp(302, "")
    end)

    Bypass.stub(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["grant_type"] == "authorization_code"
      assert params["client_id"] == "inline-client"
      assert params["client_secret"] == "inline-secret"
      authorization = Agent.get(counter, &Map.fetch!(&1.codes, params["code"]))

      challenge =
        :crypto.hash(:sha256, params["code_verifier"]) |> Base.url_encode64(padding: false)

      assert challenge == authorization["code_challenge"]
      assert params["redirect_uri"] == authorization["redirect_uri"]
      assert params["resource"] == origin <> "/mcp"
      n = Agent.get_and_update(counter, &{&1.tokens + 1, %{&1 | tokens: &1.tokens + 1}})

      granted =
        cond do
          opts[:partial_grant] && n >= 2 -> Enum.join(opts[:partial_grant], " ")
          opts[:narrow_step_up] && n == 2 -> "tools.call"
          true -> authorization["scope"]
        end

      Agent.update(
        counter,
        &%{
          &1
          | grants: Map.put(&1.grants, "token-#{n}", String.split(granted || "", " ", trim: true))
        }
      )

      if opts[:token_error] do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      else
        json(conn, %{
          "access_token" => "token-#{n}",
          "token_type" => "Bearer",
          "scope" => granted
        })
      end
    end)
  end

  defp base_scopes(opts), do: opts |> Keyword.get(:base_scopes, ["tools.call"]) |> Enum.join(" ")

  defp establishment(:legacy, version) do
    %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "inline", "version" => "1"}
    }
  end

  defp establishment(:modern, version) do
    %{
      "resultType" => "complete",
      "supportedVersions" => [version],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    }
  end

  defp hold_after(messages) do
    owner = self()

    fn request, conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, Enum.map_join(messages, &event/1))
      send(owner, {:holding, self()})

      receive do
        :release -> :ok
      after
        10_000 -> flunk("test did not release the response stream")
      end

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          event(response(request["id"], %{"resultType" => "complete", "content" => []}))
        )

      conn
    end
  end

  defp finish(request, conn),
    do: json(conn, response(request["id"], %{"resultType" => "complete", "content" => []}))

  defp notification(method, params),
    do: %{"jsonrpc" => "2.0", "method" => method, "params" => params}

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  defp event(message), do: "data: #{Jason.encode!(message)}\n\n"

  defp challenge(conn, status, www_auth),
    do:
      conn
      |> Plug.Conn.put_resp_header("www-authenticate", www_auth)
      |> Plug.Conn.resp(status, "")

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
end
