defmodule ExMCP.Client.CallbackWorkTeardownTest do
  @moduledoc """
  Reverse-request handler tasks (sampling, elicitation, custom server
  requests) and MRTR fulfillment tasks belong to the connection that started
  them. When that connection ends — `disconnect/1`, transport loss, or the
  client stopping — they are stopped, a caller waiting on MRTR fulfillment is
  answered, and a late result can never answer an old server request id on
  the connection that replaced it.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Client
  alias ExMCP.Error

  defmodule BlockingHandler do
    @moduledoc false
    @behaviour ExMCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state) do
      send(state.owner, {:callback_started, self()})

      receive do
        :release ->
          {:ok,
           %{
             "role" => "assistant",
             "content" => %{"type" => "text", "text" => "late"},
             "model" => "test-model"
           }, state}
      end
    end

    @impl true
    def handle_elicitation_create(_message, _schema, state) do
      send(state.owner, {:callback_started, self()})

      receive do
        :release -> {:ok, %{"action" => "decline"}, state}
      end
    end
  end

  defmodule LegacyPushTransport do
    @moduledoc """
    Push-model legacy transport. Each connection gets the next generation
    number; the handshake is answered synchronously and every other outbound
    message is reported to the test process as `{:sent, generation, message}`.
    Server requests are delivered by the test straight to the client.
    """

    @behaviour ExMCP.Transport

    defstruct [:test_pid, :generation, :pending]

    @impl true
    def connect(opts) do
      connections = Keyword.fetch!(opts, :connections)
      :ok = :counters.add(connections, 1, 1)
      generation = :counters.get(connections, 1)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:transport_connect, generation})
      {:ok, %__MODULE__{test_pid: test_pid, generation: generation}}
    end

    @impl true
    def send_message(message, %__MODULE__{} = state) do
      case Jason.decode!(message) do
        %{"method" => "initialize", "id" => id} ->
          {:ok, %{state | pending: initialize_response(id)}}

        decoded ->
          send(state.test_pid, {:sent, state.generation, decoded})
          {:ok, state}
      end
    end

    @impl true
    def receive_message(%__MODULE__{pending: nil}), do: {:error, :closed}

    def receive_message(%__MODULE__{pending: response} = state),
      do: {:ok, response, %{state | pending: nil}}

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
          "serverInfo" => %{"name" => "callback-teardown", "version" => "1.0.0"}
        }
      })
    end
  end

  defmodule InputRequiredTransport do
    @moduledoc """
    Synchronous modern transport whose every request is answered with an
    `input_required` result asking for one form elicitation.
    """

    def send_message(encoded, state) do
      request = Jason.decode!(encoded)

      result = %{
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
        "requestState" => "opaque.request.state"
      }

      response = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
      {:ok, state, Jason.encode!(response)}
    end

    def close(_state), do: :ok
  end

  describe "reverse-request handler tasks" do
    test "disconnect stops a running handler task" do
      client = start_legacy_client(reconnect: false)
      task_pid = deliver_sampling_request(client, "srv-1")
      ref = Process.monitor(task_pid)

      assert :ok = Client.disconnect(client)

      assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000
      assert map_size(:sys.get_state(client).server_request_tasks) == 0
    end

    test "a result finishing after a reconnect never answers on the new connection" do
      client =
        start_legacy_client(reconnect_backoff: [initial: 5, max: 10, multiplier: 2])

      assert_receive {:transport_connect, 1}
      task_pid = deliver_sampling_request(client, "srv-1")
      ref = Process.monitor(task_pid)

      send(client, {:transport_closed, :connection_lost})

      # The reconnect re-runs the handshake on connection 2.
      assert_receive {:transport_connect, 2}, 1_000
      assert_receive {:sent, 2, %{"method" => "notifications/initialized"}}, 1_000

      # The connection-1 callback finishes only now, if it is still running.
      send(task_pid, :release)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, reason}, 1_000

      # Flushes the client: any result it got has been handled by now.
      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      refute_received {:sent, _generation, %{"id" => "srv-1"}}
      assert reason == :killed
      assert map_size(:sys.get_state(client).server_request_tasks) == 0
    end

    test "stopping the client stops a running handler task" do
      client = start_legacy_client(reconnect: false)
      task_pid = deliver_sampling_request(client, "srv-1")
      ref = Process.monitor(task_pid)

      assert :ok = Client.stop(client)

      assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000
    end
  end

  describe "MRTR fulfillment tasks" do
    test "disconnect answers the waiting caller and stops its task" do
      client = start_modern_client()
      {call, task_pid} = start_waiting_mrtr_call(client)
      ref = Process.monitor(task_pid)

      assert :ok = Client.disconnect(client)

      assert {:ok, {:error, %Error{code: :connection_error}}} = Task.yield(call, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000
      assert map_size(:sys.get_state(client).mrtr_tasks) == 0
    end

    test "transport loss answers the waiting caller and stops its task" do
      client = start_modern_client()
      {call, task_pid} = start_waiting_mrtr_call(client)
      ref = Process.monitor(task_pid)

      send(client, {:transport_closed, :connection_lost})

      assert {:ok, {:error, %Error{code: :connection_error}}} = Task.yield(call, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}, 1_000
      assert map_size(:sys.get_state(client).mrtr_tasks) == 0
    end
  end

  describe "concurrent server request limit" do
    test "requests beyond :max_server_requests get an error reply without a handler task" do
      client = start_legacy_client(max_server_requests: 2)
      assert_receive {:transport_connect, 1}

      task1 = deliver_sampling_request(client, 1)
      task2 = deliver_sampling_request(client, 2)

      push_sampling_request(client, 3)

      assert_receive {:sent, 1,
                      %{"id" => 3, "error" => %{"code" => -32603, "message" => message}}},
                     1_000

      assert message =~ "Too many concurrent server requests"
      refute_receive {:callback_started, _}, 200
      assert map_size(:sys.get_state(client).server_request_tasks) == 2

      # Releasing a handler frees a slot.
      send(task1, :release)
      assert_receive {:sent, 1, %{"id" => 1, "result" => _}}, 1_000
      task4 = deliver_sampling_request(client, 4)

      for task <- [task2, task4], do: send(task, :release)
      assert_receive {:sent, 1, %{"id" => 2, "result" => _}}, 1_000
      assert_receive {:sent, 1, %{"id" => 4, "result" => _}}, 1_000
    end
  end

  defp start_legacy_client(opts) do
    {:ok, client} =
      Client.start_link(
        [
          transport: LegacyPushTransport,
          test_pid: self(),
          connections: :counters.new(1, []),
          protocol_mode: :legacy_only,
          handler: {BlockingHandler, [owner: self()]},
          capabilities: %{"sampling" => %{}},
          health_check_interval: nil
        ] ++ opts
      )

    client
  end

  defp deliver_sampling_request(client, id) do
    push_sampling_request(client, id)
    assert_receive {:callback_started, task_pid}, 1_000
    task_pid
  end

  defp push_sampling_request(client, id) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}],
        "maxTokens" => 10
      }
    }

    send(client, {:transport_message, Jason.encode!(request)})
  end

  defp start_modern_client do
    owner = self()

    {:ok, client} =
      start_supervised(
        {Client,
         _skip_connect: true,
         handler: {BlockingHandler, [owner: owner]},
         capabilities: %{"elicitation" => %{"form" => %{}}},
         health_check_interval: nil,
         reconnect: false}
      )

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: InputRequiredTransport,
          transport_state: %{},
          protocol_version: "2026-07-28",
          connection_status: :ready,
          initialized: true
      }
    end)

    client
  end

  # The caller is blocked in MRTR fulfillment once the elicitation callback
  # has started inside the fulfillment task.
  defp start_waiting_mrtr_call(client) do
    call =
      Task.async(fn ->
        Client.call_tool(client, "confirm", %{}, format: :map, timeout: 30_000)
      end)

    assert_receive {:callback_started, task_pid}, 1_000
    {call, task_pid}
  end
end
