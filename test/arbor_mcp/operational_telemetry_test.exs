defmodule Arbor.MCP.OperationalTelemetryTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client.Internal.Request, as: ClientRequest

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{EraCache, Subscription}
  alias Arbor.MCP.Server.{MRTR, ReplayCache, RequestContext, RequestState, Subscriptions}

  @events [
    [:arbor_mcp, :client, :era, :settled],
    [:arbor_mcp, :client, :era, :fallback],
    [:arbor_mcp, :client, :era, :downgrade_attempt],
    [:arbor_mcp, :client, :http, :request, :retry],
    [:arbor_mcp, :client, :mrtr, :round],
    [:arbor_mcp, :client, :mrtr, :failure],
    [:arbor_mcp, :client, :subscription, :reconnect],
    [:arbor_mcp, :server, :mrtr, :failure],
    [:arbor_mcp, :server, :subscription, :queue_pressure]
  ]

  @old_key :binary.copy(<<21>>, 32)
  @new_key :binary.copy(<<22>>, 32)

  defmodule LegacyTransport do
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def send_message(encoded, state) do
      request = Jason.decode!(encoded)

      response =
        case request do
          %{"method" => "server/discover", "id" => id} ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "error" => %{"code" => -32601, "message" => "legacy only"}
            }

          %{"method" => "initialize", "id" => id} ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => "2025-11-25",
                "capabilities" => %{},
                "serverInfo" => %{"name" => "legacy", "version" => "1"}
              }
            }

          _notification ->
            nil
        end

      send(state.owner, {:operational_transport_request, request["method"]})

      if response,
        do: {:ok, state, Jason.encode!(response)},
        else: {:ok, state}
    end

    @impl true
    def connected?(_state), do: true

    @impl true
    def receive_message(_state), do: {:error, :closed}

    @impl true
    def close(_state), do: :ok
  end

  defmodule ReconnectClient do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, %{owner: owner, id: 0}}

    @impl true
    def handle_call({:open_subscription, subscription, filter}, _from, state) do
      id = state.id + 1

      send(
        subscription,
        {:client_subscription_acknowledged, id,
         %{
           "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id},
           "notifications" => filter
         }}
      )

      {:reply, {:ok, id}, %{state | id: id}}
    end

    @impl true
    def handle_cast({:close_subscription, _subscription, _request_id, _reason}, state),
      do: {:noreply, state}
  end

  defmodule MRTRHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def handle_elicitation_create(_message, _schema, state) do
      {:ok, %{"action" => "decline"}, state}
    end
  end

  defmodule MRTRTransport do
    def send_message(encoded, state) do
      request = Jason.decode!(encoded)

      result =
        if state.round == 0 do
          %{
            "resultType" => "input_required",
            "inputRequests" => %{
              "confirm" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "message" => "Confirm",
                  "requestedSchema" => %{"type" => "object"}
                }
              }
            },
            "requestState" => "opaque"
          }
        else
          %{"resultType" => "complete", "content" => []}
        end

      response = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
      {:ok, %{state | round: state.round + 1}, Jason.encode!(response)}
    end
  end

  defmodule RetryClient do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_opts), do: {:ok, 0}

    @impl true
    def handle_call({:request, _method, _params, _meta}, _from, 0) do
      error =
        Arbor.MCP.Error.transport_error(:http, :response_stream_broken, %{
          cause: :closed,
          delivery: :ambiguous
        })

      {:reply, {:error, error}, 1}
    end

    def handle_call({:request, _method, _params, _meta}, _from, count),
      do: {:reply, {:ok, %{"resultType" => "complete"}}, count + 1}

    def handle_call(:get_default_retry_policy, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call(:get_default_timeout, _from, state), do: {:reply, {:ok, 1_000}, state}
    def handle_call(:conformance_mode?, _from, state), do: {:reply, false, state}

    @impl true
    def handle_cast({:cancel_mrtr_scope, _scope_ref}, state), do: {:noreply, state}
  end

  setup do
    owner = self()
    handler_id = "operational-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.handle_telemetry/4,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  def handle_telemetry(event, measurements, metadata, owner) do
    send(owner, {:operational_telemetry, event, measurements, metadata})
  end

  test "era settlement, fallback, and downgrade metadata are bounded" do
    {:ok, client} =
      Client.start_link(
        transport: LegacyTransport,
        test_pid: self(),
        protocol_mode: :prefer_modern,
        health_check_interval: nil
      )

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :era, :settled], %{}, settled}
    assert settled == %{era: :legacy, protocol_version: "2025-11-25"}

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :era, :fallback], %{}, fallback}
    assert fallback == %{from: :modern, to: :legacy, reason: :json_rpc_error}

    identity = EraCache.identity(__MODULE__, nil, era_cache_key: make_ref())
    assert :ok = EraCache.observe(identity, :modern, "2026-07-28")
    assert :ok = EraCache.observe(identity, :legacy, "untrusted-version-value")

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :era, :downgrade_attempt],
                    %{count: 1}, downgrade}

    assert downgrade == %{from: :modern, to: :legacy, observed_version: :unknown}
    :ok = Client.disconnect(client)
  end

  test "MRTR failures classify unknown keys and replay without exposing sealed state" do
    context = request_context()
    params = %{"name" => "collect", "arguments" => %{}}
    old_opts = request_state_opts("old", %{"old" => @old_key})

    assert {:ok, binding} = RequestState.binding(context, params, [], 1, old_opts)
    assert {:ok, token} = RequestState.seal(%{"secret" => "must-not-leak"}, binding, old_opts)

    resume = %{
      context
      | input_responses: %{},
        sealed_request_state: token
    }

    new_opts = request_state_opts("new", %{"new" => @new_key})
    assert {:error, _error} = MRTR.prepare_context(resume, params, new_opts)

    assert_receive {:operational_telemetry, [:arbor_mcp, :server, :mrtr, :failure], %{count: 1},
                    unknown_key}

    assert unknown_key == %{
             stage: :resume,
             reason: :request_state_key_unknown,
             method: "tools/call"
           }

    replay_cache = start_supervised!({ReplayCache.ETS, name: nil}, id: make_ref())
    replay_opts = Keyword.put(old_opts, :replay_cache, {ReplayCache.ETS, server: replay_cache})

    assert {:ok, _verified} = MRTR.prepare_context(resume, params, replay_opts)
    assert {:error, _replayed} = MRTR.prepare_context(resume, params, replay_opts)

    assert_receive {:operational_telemetry, [:arbor_mcp, :server, :mrtr, :failure], %{count: 1},
                    replay}

    assert replay == %{stage: :replay, reason: :replay_rejected, method: :unknown}

    refute inspect(unknown_key) =~ token
    refute inspect(replay) =~ "must-not-leak"
  end

  test "client MRTR and ambiguous reissue telemetry uses bounded operation classes" do
    {:ok, client} =
      start_supervised(
        {Client,
         _skip_connect: true,
         handler: {MRTRHandler, []},
         capabilities: %{"elicitation" => %{"form" => %{}}},
         health_check_interval: nil},
        id: make_ref()
      )

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: MRTRTransport,
          transport_state: %{round: 0},
          protocol_version: "2026-07-28",
          connection_status: :ready,
          initialized: true
      }
    end)

    assert {:ok, %{"resultType" => "complete"}} =
             Client.call_tool(client, "collect", %{}, format: :map)

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :mrtr, :round],
                    %{round: 1, input_requests: 1}, %{method: "tools/call"}}

    :sys.replace_state(client, fn state ->
      %{state | transport_state: %{round: 0}}
    end)

    assert {:error, _limit} =
             Client.call_tool(client, "collect", %{}, format: :map, max_mrtr_rounds: 0)

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :mrtr, :failure], %{round: 0},
                    %{method: "tools/call", reason: :round_limit}}

    retry_client = start_supervised!({RetryClient, []}, id: make_ref())

    assert {:ok, %{"resultType" => "complete"}} =
             ClientRequest.make_request(
               retry_client,
               "resources/read",
               %{"uri" => "secret://resource"},
               [format: :map, http_stream_retry_delay: 0],
               1_000
             )

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :http, :request, :retry],
                    %{attempt: 2}, retry}

    assert retry == %{
             method: "resources/read",
             mode: :at_least_once,
             delivery: :at_least_once
           }

    refute inspect(retry) =~ "secret://resource"
  end

  test "subscription pressure and reconnect events omit filters and subscription IDs" do
    registry =
      start_supervised!(
        Supervisor.child_spec({Subscriptions, name: nil, max_queue: 1}, id: make_ref())
      )

    assert {:ok, _entry} =
             Subscriptions.listen(
               "sensitive-subscription-id",
               %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["secret://tenant/resource"]
               },
               self(),
               registry: registry
             )

    assert_receive {:ex_mcp_subscription_message, listener, :acknowledged, _ack}

    assert %{enqueued: 1} =
             Subscriptions.publish("notifications/tools/list_changed", %{}, registry: registry)

    assert %{coalesced: 1} =
             Subscriptions.publish("notifications/tools/list_changed", %{}, registry: registry)

    assert %{closed: 1} =
             Subscriptions.publish(
               "notifications/resources/updated",
               %{"uri" => "secret://tenant/resource"},
               registry: registry
             )

    assert_receive {:operational_telemetry, [:arbor_mcp, :server, :subscription, :queue_pressure],
                    %{count: 1}, %{action: :coalesced} = coalesced}

    assert_receive {:operational_telemetry, [:arbor_mcp, :server, :subscription, :queue_pressure],
                    %{count: 1}, %{action: :closed} = closed}

    refute inspect({coalesced, closed}) =~ "secret"

    reconnect_client = start_supervised!({ReconnectClient, self()}, id: make_ref())
    assert {:ok, subscription} = Subscription.open(reconnect_client, %{}, timeout: 1_000)
    send(subscription.pid, {:client_subscription_disconnected, :secret_transport_reason})

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :subscription, :reconnect],
                    %{attempt: 1}, %{phase: :scheduled}}

    send(subscription.pid, :client_subscription_reconnect)

    assert_receive {:operational_telemetry, [:arbor_mcp, :client, :subscription, :reconnect],
                    %{attempt: 1}, %{phase: :complete}}

    :ok = Subscription.cancel(subscription)
    Subscriptions.delivered(listener)
  end

  defp request_context do
    %RequestContext{
      method: "tools/call",
      request_id: 1,
      request?: true,
      era: :modern,
      protocol_version: "2026-07-28",
      client_capabilities: %{},
      endpoint: "https://mcp.example",
      principal_id: "principal",
      tenant_id: "tenant"
    }
  end

  defp request_state_opts(active, keys) do
    [
      request_state: [
        active_key_id: active,
        keys: keys,
        ttl_seconds: 60,
        max_ttl_seconds: 60,
        clock_skew_seconds: 0
      ],
      request_state_now: System.system_time(:second)
    ]
  end
end
