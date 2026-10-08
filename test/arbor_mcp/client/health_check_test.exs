defmodule Arbor.MCP.Client.HealthCheckTest do
  @moduledoc """
  Tests for the `Arbor.MCP.Client` idle health check: ping emission while idle,
  teardown when a ping goes unanswered, and suppression while requests are
  already in flight.
  """

  # async: false because telemetry handlers are global; the handler below
  # filters on the disconnect reason to avoid cross-test interference.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  defmodule EchoTransport do
    @moduledoc """
    Push-model test transport that reports every outbound message to the test
    process. Only the handshake is answered automatically; tests deliver any
    other response directly to the client process.
    """

    @behaviour Arbor.MCP.Transport

    defstruct [:test_pid, :pending]

    @impl true
    def connect(opts) do
      {:ok, %__MODULE__{test_pid: Keyword.fetch!(opts, :test_pid), pending: nil}}
    end

    @impl true
    def send_message(message, %__MODULE__{test_pid: test_pid} = state) do
      decoded = Jason.decode!(message)
      send(test_pid, {:sent, decoded})

      case decoded do
        %{"method" => "initialize", "id" => id} ->
          {:ok, %{state | pending: initialize_response(id)}}

        _other ->
          {:ok, state}
      end
    end

    @impl true
    def receive_message(%__MODULE__{pending: nil}), do: {:error, :closed}

    def receive_message(%__MODULE__{pending: response} = state) do
      {:ok, response, %{state | pending: nil}}
    end

    @impl true
    def close(_state), do: :ok

    @impl true
    def connected?(_state), do: true

    @impl true
    def subscribe(_pid, %__MODULE__{} = state), do: {:ok, state}

    @impl true
    def capabilities(_state), do: [:push]

    defp initialize_response(id) do
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "serverInfo" => %{"name" => "health-check-test-server", "version" => "1.0.0"}
        }
      })
    end
  end

  describe "idle health check" do
    test "pings while idle and keeps the connection when the ping is answered" do
      client = start_client(health_check_interval: 100)

      assert_receive {:sent, %{"method" => "ping", "id" => first_id}}, 1_000

      # The health-check ping is internal: it must not surface as a pending
      # user request.
      assert Client.get_pending_requests(client) == []

      send(client, {:transport_event, pong(first_id)})

      # A second ping one interval later proves the answered ping did not
      # trip the "unanswered" teardown path.
      assert_receive {:sent, %{"method" => "ping", "id" => second_id}}, 1_000
      assert second_id != first_id

      assert {:ok, status} = Client.get_status(client)
      assert status.connection_status == :ready
    end

    test "treats an unanswered ping as a closed transport" do
      test_pid = self()
      handler_id = "health-check-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:arbor_mcp, :client, :disconnected],
        fn _event, _measurements, metadata, _config ->
          # Only forward health-check teardowns so unrelated disconnects
          # cannot satisfy the assertion below.
          if Map.get(metadata, :reason) == :health_check_timeout do
            send(test_pid, {:client_disconnected, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # reconnect: false keeps the client in :disconnected so the outcome is
      # observable without racing a reconnection.
      client = start_client(health_check_interval: 50, reconnect: false)

      assert_receive {:sent, %{"method" => "ping"}}, 1_000

      # The ping is never answered, so the next tick tears the transport down.
      assert_receive {:client_disconnected, metadata}, 1_000
      assert metadata.reason == :health_check_timeout
      assert metadata.pid == client

      assert {:ok, status} = Client.get_status(client)
      assert status.connection_status == :disconnected
    end

    test "skips the ping while a request is in flight" do
      client = start_client(health_check_interval: 50)

      task = Task.async(fn -> Client.list_tools(client, timeout: 500) end)

      assert_receive {:sent, %{"method" => "tools/list"}}, 1_000

      # In-flight requests are their own liveness proof; several intervals
      # pass without a ping being emitted.
      refute_receive {:sent, %{"method" => "ping"}}, 250

      assert {:error, _reason} = Task.await(task, 2_000)
    end

    test "is disabled when the interval is nil" do
      client = start_client(health_check_interval: nil)

      refute_receive {:sent, %{"method" => "ping"}}, 200

      assert {:ok, status} = Client.get_status(client)
      assert status.connection_status == :ready
    end
  end

  defp start_client(opts) do
    {:ok, client} =
      Client.start_link(
        [transport: EchoTransport, test_pid: self(), protocol_mode: :legacy_only] ++ opts
      )

    client
  end

  defp pong(id) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end
end
