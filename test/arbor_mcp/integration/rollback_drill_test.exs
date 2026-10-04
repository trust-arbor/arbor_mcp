defmodule Arbor.MCP.Integration.RollbackDrillTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.{EraCache, Subscription}
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Context, HandlerServer, Runtime, Subscriptions}

  @moduletag :integration

  @request_state_key :binary.copy(<<82>>, 32)
  @rc5_fixture Path.expand("../../../priv/test/rollback_rc5_server.exs", __DIR__)

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      {:ok, %{ledger: Keyword.fetch!(opts, :ledger)}}
    end

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "onboard",
          description: "Complete an elicitation-backed operation",
          inputSchema: %{type: "object", properties: %{}}
        },
        %{
          name: "reconcile",
          description: "Read externally reconciled operation state",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("onboard", _arguments, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "name" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "What should we call you?",
                "requestedSchema" => %{"type" => "object"}
              }
            }
          }

          {:input_required, requests, %{"prefix" => "Welcome"}, state}

        %{"name" => %{"content" => %{"name" => name}}} ->
          Agent.update(state.ledger, fn ledger ->
            update_in(ledger.completed, &[name | &1])
          end)

          {:ok,
           %{
             content: [
               %{type: "text", text: "#{Context.request_state()["prefix"]}, #{name}"}
             ]
           }, state}
      end
    end

    def handle_call_tool("reconcile", arguments, state) do
      completed =
        case arguments do
          %{"completed" => completed} -> completed
          _other -> state.ledger |> Agent.get(&Enum.reverse(&1.completed)) |> Enum.join(",")
        end

      {:ok,
       %{
         content: [
           %{type: "text", text: "rc5-reconciled=#{completed}"}
         ]
       }, state}
    end

    def handle_call_tool(_name, _arguments, state), do: {:error, "unknown tool", state}
  end

  defmodule PausingClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not configured", state}

    @impl true
    def handle_elicitation_create(message, _schema, state) do
      send(state.owner, {:rollback_mrtr_waiting, self(), message})

      receive do
        {:complete_rollback_mrtr, name} ->
          {:ok, %{"action" => "accept", "content" => %{"name" => name}}, state}
      after
        5_000 ->
          {:error, "rollback drill timed out waiting for drain", state}
      end
    end
  end

  test "drains modern work before a legacy-only restart and requires explicit pin reset" do
    ledger = start_supervised!({Agent, fn -> %{completed: []} end})
    registry = start_subscription_registry()

    modern_server =
      start_server(
        ledger,
        protocol_mode: :modern_only,
        mrtr: true,
        request_state: [active_key_id: "rollback", keys: %{"rollback" => @request_state_key}],
        subscription_registry: registry
      )

    modern_client =
      start_client(modern_server,
        protocol_mode: :modern_only,
        capabilities: %{"elicitation" => %{"form" => %{}}},
        handler: {PausingClientHandler, [owner: self()]}
      )

    legacy_client = start_legacy_client(ledger)

    assert {:ok, subscription} =
             Client.listen(modern_client, %{"toolsListChanged" => true}, timeout: 2_000)

    assert %Subscription.Ref{} = subscription
    assert [_entry] = Subscriptions.entries(registry: registry)

    mrtr_task =
      Task.async(fn ->
        Client.call_tool(modern_client, "onboard", %{}, timeout: 5_000, format: :map)
      end)

    assert_receive {:rollback_mrtr_waiting, callback, "What should we call you?"}, 2_000

    # The legacy node is live while the modern subscription and MRTR request
    # are both active, matching the mixed-deployment portion of the drill.
    assert {:ok, %{"tools" => tools}} = Client.list_tools(legacy_client, format: :map)
    assert Enum.any?(tools, &(&1["name"] == "reconcile"))

    assert {:error, :subscriptions_require_mcp_2026_07_28} =
             Client.listen(legacy_client, %{"toolsListChanged" => true})

    :ok = Server.notify_tools_changed(modern_server)

    assert_receive {:ex_mcp_subscription, ^subscription, "notifications/tools/list_changed",
                    _params},
                   2_000

    assert :ok =
             Subscriptions.close(
               runtime_edge(modern_server),
               subscription.request_id,
               :server_shutdown,
               registry: registry
             )

    assert_receive {:ex_mcp_subscription_closed, ^subscription, {:complete, _result}}, 2_000
    assert_eventually(fn -> Subscriptions.entries(registry: registry) == [] end)

    send(callback, {:complete_rollback_mrtr, "Lin"})

    assert {:ok, modern_result} = Task.await(mrtr_task, 5_000)
    assert get_in(modern_result, ["content", Access.at(0), "text"]) == "Welcome, Lin"

    assert :ok = Client.disconnect(modern_client)
    assert :ok = Runtime.stop(modern_server)

    # Application state lives outside either protocol-era process. The
    # legacy-only node receives the reconciled state only after the modern node
    # drains. The opt-in release-gate run executes this call against rc.5.
    completed = ledger |> Agent.get(&Enum.reverse(&1.completed)) |> Enum.join(",")

    assert {:ok, legacy_result} =
             Client.call_tool(legacy_client, "reconcile", %{"completed" => completed},
               timeout: 2_000,
               format: :map
             )

    assert get_in(legacy_result, ["content", Access.at(0), "text"]) ==
             "rc5-reconciled=Lin"

    identity = EraCache.identity(__MODULE__, nil, era_cache_key: make_ref())
    assert :ok = EraCache.observe(identity, :modern, "2026-07-28")
    assert :ok = EraCache.observe(identity, :legacy, "2025-11-25")
    assert {:ok, %{era: :modern, expires_at: :infinity}} = EraCache.lookup(identity)

    assert :ok = EraCache.clear(identity)
    assert :ok = EraCache.observe(identity, :legacy, "2025-11-25")
    assert {:ok, %{era: :legacy}} = EraCache.lookup(identity)
  end

  defp start_subscription_registry do
    child_spec =
      Supervisor.child_spec(
        {Subscriptions, name: nil, max_lifetime_ms: 10_000},
        id: make_ref()
      )

    start_supervised!(child_spec)
  end

  defp start_server(ledger, opts) do
    {:ok, server} =
      HandlerServer.start_link(
        [handler: Handler, handler_args: [ledger: ledger], transport: :test] ++ opts
      )

    on_exit(fn -> stop_server(server) end)
    server
  end

  defp start_client(server, opts) do
    {:ok, client} =
      Client.start_link([transport: :test, server: server, health_check_interval: nil] ++ opts)

    on_exit(fn -> disconnect_client(client) end)
    client
  end

  defp start_legacy_client(ledger) do
    case System.get_env("EX_MCP_ROLLBACK_RC5_ROOT") do
      nil ->
        legacy_server = start_server(ledger, protocol_mode: :legacy_only)
        start_client(legacy_server, protocol_mode: :legacy_only)

      root ->
        start_rc5_client(Path.expand(root))
    end
  end

  defp start_rc5_client(root) do
    mixfile = Path.join(root, "mix.exs")
    app_file = Path.join(root, "_build/prod/lib/ex_mcp/ebin/ex_mcp.app")

    assert File.read!(mixfile) =~ ~s(@version "1.0.0-rc.5")
    assert File.regular?(app_file), "compile the rc.5 archive with MIX_ENV=prod first"

    elixir = System.find_executable("elixir") || flunk("elixir executable is required")

    {:ok, client} =
      Client.start_link(
        transport: :stdio,
        command: [elixir, @rc5_fixture],
        env: [{"ERL_LIBS", Path.join(root, "_build/prod/lib")}],
        protocol_mode: :legacy_only,
        health_check_interval: nil
      )

    on_exit(fn -> disconnect_client(client) end)

    assert {:ok, "2025-11-25"} = Client.negotiated_version(client)

    assert {:ok, %{"name" => "rc5-rollback-target", "version" => "1.0.0-rc.5"}} =
             Client.server_info(client)

    client
  end

  defp disconnect_client(client) do
    if Process.alive?(client) do
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp stop_server(server) do
    Runtime.stop(server)
  end

  defp runtime_edge(server) do
    {:ok, edge} = Runtime.edge(server)
    edge
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        10 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
