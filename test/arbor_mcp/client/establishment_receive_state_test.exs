defmodule Arbor.MCP.Client.EstablishmentReceiveStateTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.EraProbe

  @moduletag :capture_log

  defmodule Provider do
    @behaviour Arbor.MCP.Authorization.Provider
    @impl true
    def init(_opts), do: {:ok, %{token: "A", refreshes: 0}}
    @impl true
    def get_token(state), do: {:ok, state.token, state}
    @impl true
    def handle_unauthorized(_www, _scopes, state),
      do: {:ok, "B", %{state | token: "B", refreshes: state.refreshes + 1}}

    @impl true
    def handle_forbidden(www, scopes, state), do: handle_unauthorized(www, scopes, state)
  end

  defmodule ReceiveTransport do
    @behaviour Arbor.MCP.Transport
    @impl true
    def connect(opts),
      do: {:ok, %{owner: opts[:test_pid], token: "A", failure: opts[:failure] || :closed}}

    @impl true
    def send_message(_message, state), do: {:ok, state}
    @impl true
    def receive_message(state), do: receive_message(state, :infinity)

    def receive_message(%{token: "A"} = state, _timeout) do
      notification = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/message"})
      {:ok, notification, %{state | token: "B"}}
    end

    def receive_message(state, _timeout), do: {:error, state.failure}
    @impl true
    def connected?(_state), do: true
    @impl true
    def close(state) do
      send(state.owner, {:closed_receive_transport, state})
      :ok
    end
  end

  defmodule BlockingReceiveTransport do
    @behaviour Arbor.MCP.Transport
    @impl true
    defdelegate connect(opts), to: ReceiveTransport
    @impl true
    defdelegate send_message(message, state), to: ReceiveTransport
    @impl true
    defdelegate connected?(state), to: ReceiveTransport
    @impl true
    defdelegate close(state), to: ReceiveTransport

    @impl true
    def receive_message(%{token: "A"} = state), do: ReceiveTransport.receive_message(state)

    def receive_message(_state) do
      receive do
        :response_that_never_arrives -> {:error, :unexpected_response}
      end
    end
  end

  for transport <- [ReceiveTransport, BlockingReceiveTransport] do
    test "probe retains notification state on #{transport} receive failure" do
      {:ok, state} = unquote(transport).connect(test_pid: self())

      assert {:error, _, latest} =
               EraProbe.probe(unquote(transport), state, era_probe_timeout: 100)

      assert latest.token == "B"
    end

    for mode <- [:modern_only, :prefer_modern, :legacy_only, :prefer_legacy] do
      test "#{mode} cleanup retains #{transport} state on receive failure" do
        assert {:error, _} =
                 Client.start_link(
                   transport: unquote(transport),
                   test_pid: self(),
                   protocol_mode: unquote(mode),
                   era_probe_timeout: 100,
                   handshake_timeout: 100,
                   reconnect: false,
                   health_check_interval: nil
                 )

        assert_receive {:closed_receive_transport, %{token: "B"}}
      end
    end
  end

  test "a transport timeout error retains the last received probe state" do
    {:ok, state} = ReceiveTransport.connect(test_pid: self(), failure: {:timeout_error, :silent})

    assert {:error, {:probe_timeout, :silent}, %{token: "B"}} =
             EraProbe.probe(ReceiveTransport, state, [])
  end

  for {mode, first_method, fallback_method} <- [
        {:prefer_modern, "server/discover", "initialize"},
        {:prefer_legacy, "initialize", "server/discover"}
      ] do
    test "#{mode} carries refreshed HTTP credentials into its fallback" do
      mode = unquote(mode)
      bypass = Bypass.open()
      {:ok, requests} = Agent.start_link(fn -> [] end)
      first_method = unquote(first_method)

      Bypass.stub(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        token = Plug.Conn.get_req_header(conn, "authorization")
        Agent.update(requests, &[{request["method"], token} | &1])

        if request["method"] == first_method and token == ["Bearer A"] do
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
          |> Plug.Conn.resp(401, "")
        else
          respond(conn, request, mode)
        end
      end)

      assert {:ok, client} =
               Client.start_link(
                 transport: :http,
                 url: "http://127.0.0.1:#{bypass.port}/mcp",
                 use_sse: true,
                 auth_provider: {Provider, []},
                 protocol_mode: mode,
                 era_probe_timeout: 500,
                 reconnect: false,
                 health_check_interval: nil
               )

      fallback_method = unquote(fallback_method)
      assert {fallback_method, ["Bearer B"]} in Agent.get(requests, & &1)
      refute {fallback_method, ["Bearer A"]} in Agent.get(requests, & &1)
      state = :sys.get_state(client)
      assert state.transport_state.auth_provider_state == %{token: "B", refreshes: 1}
      assert state.transport_state.access_token == "B"
      assert state.transport_state.rejected_generation > 0

      Client.stop(client)
    end
  end

  defp respond(conn, %{"method" => "server/discover"}, :prefer_modern),
    do: Plug.Conn.resp(conn, 202, "")

  defp respond(conn, %{"method" => "initialize", "id" => id}, :prefer_legacy),
    do: json(conn, %{"id" => id, "error" => %{"code" => -32601, "message" => "Modern only"}})

  defp respond(conn, %{"method" => "server/discover", "id" => id}, :prefer_legacy) do
    json(conn, %{
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{},
        "ttlMs" => 60_000,
        "cacheScope" => "private"
      }
    })
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, :prefer_modern) do
    json(conn, %{
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "legacy", "version" => "1"}
      }
    })
  end

  defp respond(conn, _notification, _mode), do: Plug.Conn.resp(conn, 202, "")

  defp json(conn, response) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(Map.put(response, "jsonrpc", "2.0")))
  end
end
