defmodule Arbor.MCP.Client.ReconnectTest do
  @moduledoc """
  Tests for `Arbor.MCP.Client` automatic reconnection: backoff scheduling,
  telemetry, give-up after max attempts, and opt-out behavior.
  """

  # async: false because telemetry handlers are global. Reconnect telemetry
  # is additionally filtered by client pid to avoid cross-test interference.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  defmodule FlakyTransport do
    @moduledoc """
    Push-model test transport driven by an Agent.

    The Agent counts connection attempts; attempts beyond `:allowed_connects`
    fail with `:connection_refused`. Every connect reports its attempt number
    to the test process. The MCP handshake is answered synchronously, so no
    polling or sleeping is involved; tests deliver transport events (such as
    `{:transport_closed, reason}`) directly to the client process.
    """

    @behaviour Arbor.MCP.Transport

    defstruct [:agent, :pending]

    @impl true
    def connect(opts) do
      agent = Keyword.fetch!(opts, :agent)
      test_pid = Keyword.fetch!(opts, :test_pid)

      {attempt, allowed} =
        Agent.get_and_update(agent, fn state ->
          attempt = state.connects + 1
          {{attempt, state.allowed_connects}, %{state | connects: attempt}}
        end)

      send(test_pid, {:transport_connect, attempt})

      if attempt <= allowed do
        {:ok, %__MODULE__{agent: agent, pending: nil}}
      else
        {:error, :connection_refused}
      end
    end

    @impl true
    def send_message(message, %__MODULE__{} = state) do
      case Jason.decode!(message) do
        %{"method" => "initialize", "id" => id} ->
          {:ok, %{state | pending: initialize_response(id)}}

        _other ->
          {:ok, state}
      end
    end

    @impl true
    def receive_message(%__MODULE__{pending: nil}) do
      # Only the handshake response flows through this callback; everything
      # else is delivered by the tests directly to the client process.
      {:error, :closed}
    end

    def receive_message(%__MODULE__{pending: response} = state) do
      {:ok, response, %{state | pending: nil}}
    end

    @impl true
    def close(_state), do: :ok

    @impl true
    def connected?(_state), do: true

    # Push model: no receiver task is spawned, so the client mailbox is fully
    # under test control.
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
          "serverInfo" => %{"name" => "reconnect-test-server", "version" => "1.0.0"}
        }
      })
    end
  end

  setup do
    test_pid = self()
    handler_id = "reconnect-test-#{System.unique_integer([:positive])}"

    events = [
      [:arbor_mcp, :client, :reconnect, :attempt],
      [:arbor_mcp, :client, :reconnect, :success],
      [:arbor_mcp, :client, :reconnect, :error],
      [:arbor_mcp, :client, :reconnect, :timeout]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "automatic reconnection" do
    test "reconnects after transport close, emitting :attempt then :success" do
      agent = start_agent(10)
      client = start_client(agent, reconnect_backoff: [initial: 10, max: 40, multiplier: 2])

      assert_receive {:transport_connect, 1}

      send(client, {:transport_closed, :connection_lost})

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt],
                      %{attempt: 1, delay_ms: delay}, %{pid: ^client}}

      assert is_integer(delay) and delay > 0

      # The scheduled attempt re-runs the full connect + handshake
      assert_receive {:transport_connect, 2}, 1_000

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], %{attempt: 1},
                      %{pid: ^client}},
                     1_000

      assert {:ok, status} = Client.get_status(client)
      assert status.connection_status == :ready
      assert status.reconnect_attempts == 0
    end

    test "a successful new connection clears the previous generation's cleanup failure" do
      agent = start_agent(10)
      client = start_client(agent, reconnect_backoff: [initial: 10, max: 40, multiplier: 2])
      assert_receive {:transport_connect, 1}

      :sys.replace_state(client, &%{&1 | cleanup_result: {:error, :cleanup_denied}})
      send(client, {:transport_closed, :connection_lost})

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :success], %{attempt: 1},
                      %{pid: ^client}},
                     1_000

      assert :sys.get_state(client).cleanup_result == :ok
      assert :ok = Client.disconnect(client)
    end

    test "gives up after max attempts and emits :timeout" do
      # Only the initial connect succeeds; every reconnect attempt fails
      agent = start_agent(1)

      client =
        start_client(agent,
          max_reconnect_attempts: 2,
          reconnect_backoff: [initial: 5, max: 10, multiplier: 2]
        )

      assert_receive {:transport_connect, 1}

      send(client, {:transport_closed, :connection_lost})

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt], %{attempt: 1},
                      %{pid: ^client}}

      # Requests made while reconnecting fail with the existing error shape
      assert {:error, :not_connected} = Client.list_tools(client)

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :error], %{attempt: 1},
                      %{pid: ^client}},
                     1_000

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt], %{attempt: 2},
                      %{pid: ^client}},
                     1_000

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :error], %{attempt: 2},
                      %{pid: ^client}},
                     1_000

      assert_receive {:telemetry, [:arbor_mcp, :client, :reconnect, :timeout], %{attempt: 2},
                      %{max_attempts: 2, pid: ^client}},
                     1_000

      assert {:ok, status} = Client.get_status(client)
      assert status.connection_status == :disconnected

      refute_received {:telemetry, [:arbor_mcp, :client, :reconnect, :success], _,
                       %{pid: ^client}}
    end
  end

  describe "reconnect opt-out" do
    test "does not reconnect when reconnect: false" do
      agent = start_agent(10)
      client = start_client(agent, reconnect: false)

      assert_receive {:transport_connect, 1}

      send(client, {:transport_closed, :connection_lost})

      # get_status is processed after the close message, so scheduling (and
      # its :attempt telemetry) would already have happened if enabled
      assert {:ok, status} = Client.get_status(client)
      assert status.connection_status == :disconnected
      assert status.reconnect_attempts == 0

      refute_received {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt], _,
                       %{pid: ^client}}

      assert Agent.get(agent, & &1.connects) == 1
    end

    test "does not reconnect after an explicit disconnect" do
      agent = start_agent(10)
      client = start_client(agent, [])

      assert_receive {:transport_connect, 1}

      assert :ok = Client.disconnect(client)

      # A late close notification from the torn-down transport must not
      # resurrect the connection
      send(client, {:transport_closed, :normal})

      assert {:ok, status} = Client.get_status(client)
      assert status.connection_status == :disconnected

      refute_received {:telemetry, [:arbor_mcp, :client, :reconnect, :attempt], _,
                       %{pid: ^client}}

      assert Agent.get(agent, & &1.connects) == 1
    end
  end

  defp start_agent(allowed_connects) do
    initial = %{connects: 0, allowed_connects: allowed_connects}
    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp start_client(agent, opts) do
    {:ok, client} =
      Client.start_link(
        [transport: FlakyTransport, agent: agent, test_pid: self(), protocol_mode: :legacy_only] ++
          opts
      )

    client
  end
end
