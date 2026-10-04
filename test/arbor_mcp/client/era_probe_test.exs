defmodule Arbor.MCP.Client.EraProbeTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer

  defmodule LegacyTransport do
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), opts: opts}}

    @impl true
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.test_pid, {:legacy_transport_request, request["method"]})
      queue_response(request, state)
      {:ok, state}
    end

    defp queue_response(%{"method" => "server/discover", "id" => id}, state) do
      error = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => Keyword.get(state.opts, :probe_error_code, -32601),
          "message" => "Legacy server does not support discovery"
        }
      }

      send(self(), {:legacy_transport_response, Jason.encode!(error)})
    end

    defp queue_response(%{"method" => "initialize", "id" => id}, _state) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "legacy", "version" => "1"}
        }
      }

      send(self(), {:legacy_transport_response, Jason.encode!(response)})
    end

    defp queue_response(_notification, _state), do: :ok

    @impl true
    def receive_message(state) do
      receive do
        {:legacy_transport_response, response} -> {:ok, response, state}
      end
    end

    def receive_message(state, timeout) do
      receive do
        {:legacy_transport_response, response} -> {:ok, response, state}
      after
        timeout -> {:error, {:timeout_error, :receive_timeout}}
      end
    end

    @impl true
    def connected?(_state), do: true

    @impl true
    def close(_state), do: :ok
  end

  defmodule HTTPProbeTransport do
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), opts: opts}}

    @impl true
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.test_pid, {:http_probe_transport_request, request["method"]})
      respond(request, state)
    end

    defp respond(%{"method" => "server/discover", "id" => id}, state) do
      status = Keyword.fetch!(state.opts, :probe_status)

      body =
        Keyword.get_lazy(state.opts, :probe_body, fn ->
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{"code" => -32601, "message" => "Method not found"}
          })
        end)

      {:error, {:http_error, status, body}}
    end

    defp respond(%{"method" => "initialize", "id" => id}, state) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "serverInfo" => %{"name" => "legacy-http", "version" => "1"}
        }
      }

      {:ok, state, Jason.encode!(response)}
    end

    defp respond(_notification, state), do: {:ok, state}

    @impl true
    def receive_message(state) do
      receive do
        {:http_probe_response, response} -> {:ok, response, state}
      end
    end

    @impl true
    def connected?(_state), do: true

    @impl true
    def close(_state), do: :ok
  end

  defmodule SwitchableTransport do
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         mode_agent: Keyword.fetch!(opts, :mode_agent)
       }}
    end

    @impl true
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.test_pid, {:switchable_transport_request, request["method"]})

      case request do
        %{"method" => "server/discover", "id" => id} ->
          discover_response(id, Agent.get(state.mode_agent, & &1), state)

        %{"method" => "initialize", "id" => id} ->
          initialize_response(id, state)

        _notification ->
          {:ok, state}
      end
    end

    defp discover_response(id, :modern, state) do
      result = %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{"tools" => %{}},
        "ttlMs" => 60_000,
        "cacheScope" => "private",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{
            "name" => "switchable",
            "version" => "1"
          }
        }
      }

      response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      {:ok, state, Jason.encode!(response)}
    end

    defp discover_response(id, :legacy, state) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "Method not found"}
      }

      {:ok, state, Jason.encode!(response)}
    end

    defp initialize_response(id, state) do
      response = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "serverInfo" => %{"name" => "switchable-legacy", "version" => "1"}
        }
      }

      {:ok, state, Jason.encode!(response)}
    end

    @impl true
    def receive_message(state) do
      receive do
        {:switchable_response, response} -> {:ok, response, state}
      end
    end

    @impl true
    def connected?(_state), do: true

    @impl true
    def close(_state), do: :ok
  end

  defmodule ModernServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "modern-test-server", version: "1.0.0"

    tool "echo", "Echo text" do
      param(:text, :string, required: true)

      run(fn %{"text" => text}, state ->
        {:ok, %{content: [%{type: "text", text: text}]}, state}
      end)
    end
  end

  test "modern-only connection discovers and invokes tools without initialize" do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ModernServer,
        transport: :test,
        protocol_mode: :modern_only
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :modern_only,
        capabilities: %{},
        health_check_interval: nil
      )

    assert {:ok, "2026-07-28"} = Client.negotiated_version(client)

    assert {:ok, %{"name" => "modern-test-server", "version" => "1.0.0"}} =
             Client.server_info(client)

    assert {:ok, %{"tools" => %{}}} = Client.server_capabilities(client)

    assert {:ok, %{"resultType" => "complete", "tools" => [tool]}} =
             Client.list_tools(client, format: :map)

    assert tool["name"] == "echo"

    assert {:ok, result} = Client.call_tool(client, "echo", %{"text" => "hello"}, format: :map)
    assert result["content"] == [%{"type" => "text", "text" => "hello"}]
    assert result["resultType"] == "complete"

    assert {:ok, health_result} = Client.ping(client)
    assert health_result["supportedVersions"] == ["2026-07-28"]

    server_state = :sys.get_state(protocol_edge(server))

    # HandlerServer only sets protocol_version while processing initialize;
    # the independent era pin proves this process settled on modern instead.
    assert server_state.protocol_version == nil
    assert server_state.connection_era == :modern

    :ok = Client.disconnect(client)
    GenServer.stop(server)
  end

  test "default client and server prefer the modern era" do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ModernServer,
        transport: :test
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        capabilities: %{},
        health_check_interval: nil
      )

    assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
    assert :sys.get_state(protocol_edge(server)).connection_era == :modern

    :ok = Client.disconnect(client)
    GenServer.stop(server)
  end

  test "default client falls back to a legacy initialize handshake" do
    {:ok, client} =
      Client.start_link(
        transport: LegacyTransport,
        test_pid: self(),
        health_check_interval: nil
      )

    assert_receive {:legacy_transport_request, "server/discover"}
    assert_receive {:legacy_transport_request, "initialize"}
    assert_receive {:legacy_transport_request, "notifications/initialized"}
    assert {:ok, "2025-11-25"} = Client.negotiated_version(client)

    :ok = Client.disconnect(client)
  end

  test "modern-only servers reject requests without modern metadata" do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ModernServer,
        transport: :test,
        protocol_mode: :modern_only
      )

    Process.flag(:trap_exit, true)

    assert {:error, {:initialize_error, error}} =
             Client.start_link(
               transport: :test,
               server: server,
               protocol_mode: :legacy_only,
               health_check_interval: nil
             )

    assert error["code"] == -32022
    assert error["message"] == "Unsupported protocol version"
    assert error["data"]["supported"] == ["2026-07-28"]
    GenServer.stop(server)
  end

  test "prefer-modern tentatively initializes after non-modern probe errors" do
    for error_code <- [-32601, -32602] do
      {:ok, client} =
        Client.start_link(
          transport: LegacyTransport,
          test_pid: self(),
          probe_error_code: error_code,
          protocol_mode: :prefer_modern,
          health_check_interval: nil
        )

      assert_receive {:legacy_transport_request, "server/discover"}
      assert_receive {:legacy_transport_request, "initialize"}
      assert_receive {:legacy_transport_request, "notifications/initialized"}
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      :ok = Client.disconnect(client)
    end
  end

  test "prefer-legacy falls forward when a live modern server rejects initialize" do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ModernServer,
        transport: :test,
        protocol_mode: :modern_only
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :prefer_legacy,
        health_check_interval: nil
      )

    assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
    assert :sys.get_state(protocol_edge(server)).connection_era == :modern
    :ok = Client.disconnect(client)
    GenServer.stop(server)
  end

  test "HTTP 400 probe bodies may provide legacy fallback evidence" do
    {:ok, client} =
      Client.start_link(
        transport: HTTPProbeTransport,
        test_pid: self(),
        probe_status: 400,
        protocol_mode: :prefer_modern,
        health_check_interval: nil
      )

    assert_receive {:http_probe_transport_request, "server/discover"}
    assert_receive {:http_probe_transport_request, "initialize"}
    assert_receive {:http_probe_transport_request, "notifications/initialized"}
    assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
    :ok = Client.disconnect(client)
  end

  # MCP's backwards-compatibility guidance: a server that predates the
  # method answers the probe POST with 400, 404 or 405.
  for status <- [404, 405], body <- [:json_rpc, :plain_text] do
    test "HTTP #{status} to the probe (#{body} body) is legacy fallback evidence" do
      {:ok, client} =
        Client.start_link(
          [
            transport: HTTPProbeTransport,
            test_pid: self(),
            probe_status: unquote(status),
            protocol_mode: :prefer_modern,
            health_check_interval: nil
          ] ++ probe_body(unquote(body))
        )

      assert_receive {:http_probe_transport_request, "server/discover"}
      assert_receive {:http_probe_transport_request, "initialize"}
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      :ok = Client.disconnect(client)
    end

    test "HTTP #{status} to the probe (#{body} body) never downgrades modern_only" do
      Process.flag(:trap_exit, true)

      assert {:error, _reason} =
               Client.start_link(
                 [
                   transport: HTTPProbeTransport,
                   test_pid: self(),
                   probe_status: unquote(status),
                   protocol_mode: :modern_only,
                   health_check_interval: nil
                 ] ++ probe_body(unquote(body))
               )

      assert_receive {:http_probe_transport_request, "server/discover"}
      refute_receive {:http_probe_transport_request, "initialize"}
    end
  end

  for status <- [403, 500] do
    test "HTTP #{status} to the probe is not downgrade evidence" do
      Process.flag(:trap_exit, true)

      assert {:error, _reason} =
               Client.start_link(
                 transport: HTTPProbeTransport,
                 test_pid: self(),
                 probe_status: unquote(status),
                 probe_body: "nope",
                 protocol_mode: :prefer_modern,
                 health_check_interval: nil
               )

      assert_receive {:http_probe_transport_request, "server/discover"}
      refute_receive {:http_probe_transport_request, "initialize"}
    end
  end

  defp probe_body(:json_rpc), do: []
  defp probe_body(:plain_text), do: [probe_body: "Not Found"]

  test "HTTP authentication failures are not downgrade evidence" do
    Process.flag(:trap_exit, true)

    assert {:error, _reason} =
             Client.start_link(
               transport: HTTPProbeTransport,
               test_pid: self(),
               probe_status: 401,
               protocol_mode: :prefer_modern,
               health_check_interval: nil
             )

    assert_receive {:http_probe_transport_request, "server/discover"}
    refute_receive {:http_probe_transport_request, "initialize"}
  end

  test "a successful legacy fallback is reused until its observation expires" do
    cache_key = make_ref()

    opts = [
      transport: LegacyTransport,
      test_pid: self(),
      protocol_mode: :prefer_modern,
      era_cache_key: cache_key,
      health_check_interval: nil
    ]

    {:ok, first_client} = Client.start_link(opts)
    assert_receive {:legacy_transport_request, "server/discover"}
    assert_receive {:legacy_transport_request, "initialize"}
    assert_receive {:legacy_transport_request, "notifications/initialized"}
    :ok = Client.disconnect(first_client)

    {:ok, second_client} = Client.start_link(opts)
    assert_receive {:legacy_transport_request, "initialize"}
    assert_receive {:legacy_transport_request, "notifications/initialized"}
    refute_receive {:legacy_transport_request, "server/discover"}
    :ok = Client.disconnect(second_client)
  end

  test "a modern observation blocks automatic downgrade until explicitly reset" do
    cache_key = make_ref()
    {:ok, mode_agent} = Agent.start_link(fn -> :modern end)

    opts = [
      transport: SwitchableTransport,
      test_pid: self(),
      mode_agent: mode_agent,
      protocol_mode: :prefer_modern,
      era_cache_key: cache_key,
      health_check_interval: nil
    ]

    {:ok, modern_client} = Client.start_link(opts)
    assert_receive {:switchable_transport_request, "server/discover"}
    :ok = Client.disconnect(modern_client)

    Agent.update(mode_agent, fn _ -> :legacy end)
    Process.flag(:trap_exit, true)

    assert {:error, _reason} = Client.start_link(opts)
    assert_receive {:switchable_transport_request, "server/discover"}
    refute_receive {:switchable_transport_request, "initialize"}

    {:ok, legacy_client} = Client.start_link(Keyword.put(opts, :reset_era_cache, true))
    assert_receive {:switchable_transport_request, "server/discover"}
    assert_receive {:switchable_transport_request, "initialize"}
    assert_receive {:switchable_transport_request, "notifications/initialized"}
    assert {:ok, "2025-11-25"} = Client.negotiated_version(legacy_client)
    :ok = Client.disconnect(legacy_client)
  end

  describe "seven-row era compatibility matrix" do
    test "modern client with modern server works" do
      {:ok, server} = modern_server(:modern_only)
      {:ok, client} = start_test_client(server, :modern_only)

      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      :ok = Client.disconnect(client)
      GenServer.stop(server)
    end

    test "modern client with legacy server fails without initializing" do
      Process.flag(:trap_exit, true)

      assert {:error, _reason} =
               Client.start_link(
                 transport: LegacyTransport,
                 test_pid: self(),
                 protocol_mode: :modern_only,
                 health_check_interval: nil
               )

      assert_receive {:legacy_transport_request, "server/discover"}
      refute_receive {:legacy_transport_request, "initialize"}
    end

    test "dual-era client with modern server stays modern" do
      {:ok, server} = modern_server(:modern_only)
      {:ok, client} = start_test_client(server, :prefer_modern)

      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      :ok = Client.disconnect(client)
      GenServer.stop(server)
    end

    test "dual-era client with legacy server falls back" do
      {:ok, client} =
        Client.start_link(
          transport: LegacyTransport,
          test_pid: self(),
          protocol_mode: :prefer_modern,
          health_check_interval: nil
        )

      assert_receive {:legacy_transport_request, "server/discover"}
      assert_receive {:legacy_transport_request, "initialize"}
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      :ok = Client.disconnect(client)
    end

    test "legacy client with modern server fails with supported versions" do
      {:ok, server} = modern_server(:modern_only)
      Process.flag(:trap_exit, true)

      assert {:error, {:initialize_error, error}} = start_test_client(server, :legacy_only)
      assert error["code"] == -32022
      assert error["data"]["supported"] == ["2026-07-28"]
      GenServer.stop(server)
    end

    test "legacy client with dual-era server works in legacy mode" do
      {:ok, server} = modern_server(:prefer_modern)
      {:ok, client} = start_test_client(server, :legacy_only)

      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      assert :sys.get_state(protocol_edge(server)).connection_era == :legacy
      :ok = Client.disconnect(client)
      GenServer.stop(server)
    end

    test "legacy client with legacy server works" do
      {:ok, client} =
        Client.start_link(
          transport: LegacyTransport,
          test_pid: self(),
          protocol_mode: :legacy_only,
          health_check_interval: nil
        )

      assert_receive {:legacy_transport_request, "initialize"}
      assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      :ok = Client.disconnect(client)
    end
  end

  defp modern_server(protocol_mode) do
    HandlerServer.start_link(
      handler: ModernServer,
      transport: :test,
      protocol_mode: protocol_mode
    )
  end

  defp start_test_client(server, protocol_mode) do
    Client.start_link(
      transport: :test,
      server: server,
      protocol_mode: protocol_mode,
      health_check_interval: nil
    )
  end

  defp protocol_edge(server) do
    {:ok, edge} = Arbor.MCP.Server.Runtime.edge(server)
    edge
  end
end
