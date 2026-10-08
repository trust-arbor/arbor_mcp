defmodule Arbor.MCP.Client.MRTRTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.MRTR

  defmodule Handler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def handle_elicitation_create(message, schema, state) do
      send(state.owner, {:elicitation, message, schema})
      {:ok, %{"action" => "accept", "content" => %{"name" => "Grace"}}, state}
    end
  end

  defmodule RoundTripTransport do
    def send_message(encoded, state) do
      request = Jason.decode!(encoded)
      send(state.owner, {:mrtr_wire_request, state.round, request})

      result =
        case state.round do
          0 ->
            %{
              "resultType" => "input_required",
              "inputRequests" => %{
                "profile" => %{
                  "method" => "elicitation/create",
                  "params" => %{
                    "message" => "Display name",
                    "requestedSchema" => %{"type" => "object"}
                  }
                }
              },
              "requestState" => "opaque.server.token"
            }

          1 ->
            %{
              "resultType" => "complete",
              "content" => [%{"type" => "text", "text" => "done"}]
            }
        end

      response = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
      {:ok, %{state | round: state.round + 1}, Jason.encode!(response)}
    end
  end

  defmodule RepeatedMRTRTransport do
    def send_message(encoded, state) do
      request = Jason.decode!(encoded)
      send(state.owner, {:repeated_mrtr_wire_request, state.round, request})

      result =
        if rem(state.round, 2) == 0 do
          operation = div(state.round, 2) + 1

          %{
            "resultType" => "input_required",
            "inputRequests" => %{
              "confirm" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "message" => "Confirm operation #{operation}",
                  "requestedSchema" => %{"type" => "object"}
                }
              }
            },
            "requestState" => "opaque.operation.#{operation}"
          }
        else
          %{
            "resultType" => "complete",
            "content" => [%{"type" => "text", "text" => "done"}]
          }
        end

      response = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
      {:ok, %{state | round: state.round + 1}, Jason.encode!(response)}
    end
  end

  defmodule SlowHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def handle_elicitation_create(_message, _schema, state) do
      send(state.owner, {:slow_mrtr_started, self()})

      receive do
        :finish_slow_mrtr ->
          send(state.owner, :slow_mrtr_finished)
          {:ok, %{"action" => "decline"}, state}
      end
    end
  end

  defmodule ConcurrentHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def mrtr_input_concurrency, do: 2

    @impl true
    def handle_elicitation_create(message, _schema, state) do
      send(state.owner, {:parallel_mrtr_started, message, self()})

      receive do
        :release_parallel_mrtr ->
          {:ok, %{"action" => "accept", "content" => %{"message" => message}}, state}
      end
    end
  end

  defmodule MutatingConcurrentHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def mrtr_input_concurrency, do: 2

    @impl true
    def handle_elicitation_create(_message, _schema, state) do
      {:ok, %{"action" => "decline"}, Map.put(state, :changed, true)}
    end
  end

  test "fulfils input requests and retries the immutable operation with a fresh id" do
    owner = self()

    {:ok, client} =
      start_supervised(
        {Client,
         _skip_connect: true,
         handler: {Handler, [owner: self()]},
         capabilities: %{"elicitation" => %{"form" => %{}}},
         health_check_interval: nil}
      )

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: RoundTripTransport,
          transport_state: %{owner: owner, round: 0},
          protocol_version: "2026-07-28",
          connection_status: :ready,
          initialized: true
      }
    end)

    assert {:ok, result} =
             Client.call_tool(client, "collect", %{"scope" => "same"},
               format: :map,
               timeout: 2_000
             )

    assert result["resultType"] == "complete"
    assert_receive {:elicitation, "Display name", %{"type" => "object"}}
    assert_receive {:mrtr_wire_request, 0, first}
    assert_receive {:mrtr_wire_request, 1, second}

    refute first["id"] == second["id"]
    assert first["params"]["name"] == second["params"]["name"]
    assert first["params"]["arguments"] == second["params"]["arguments"]
    assert second["params"]["requestState"] == "opaque.server.token"

    assert second["params"]["inputResponses"] == %{
             "profile" => %{
               "action" => "accept",
               "content" => %{"name" => "Grace"}
             }
           }
  end

  test "a later operation never reuses an earlier MRTR requestState" do
    owner = self()

    {:ok, client} =
      start_supervised(
        {Client,
         _skip_connect: true,
         handler: {Handler, [owner: self()]},
         capabilities: %{"elicitation" => %{"form" => %{}}},
         health_check_interval: nil}
      )

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: RepeatedMRTRTransport,
          transport_state: %{owner: owner, round: 0},
          protocol_version: "2026-07-28",
          connection_status: :ready,
          initialized: true
      }
    end)

    assert {:ok, _first} = Client.call_tool(client, "collect", %{}, format: :map)
    assert {:ok, _second} = Client.call_tool(client, "collect", %{}, format: :map)

    assert_receive {:repeated_mrtr_wire_request, 0, first_initial}
    assert_receive {:repeated_mrtr_wire_request, 1, first_retry}
    assert_receive {:repeated_mrtr_wire_request, 2, second_initial}
    assert_receive {:repeated_mrtr_wire_request, 3, second_retry}

    refute Map.has_key?(first_initial["params"], "requestState")
    assert first_retry["params"]["requestState"] == "opaque.operation.1"
    refute Map.has_key?(second_initial["params"], "requestState")
    refute Map.has_key?(second_initial["params"], "inputResponses")
    assert second_retry["params"]["requestState"] == "opaque.operation.2"
  end

  test "rejects input methods the client did not declare" do
    result = %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{"method" => "sampling/createMessage", "params" => %{}}
      },
      "requestState" => "opaque"
    }

    assert {:ok, requests, _state} = MRTR.validate_result("tools/call", result)

    assert {:error, error, _handler_state} =
             MRTR.fulfill(
               requests,
               Handler,
               %{owner: self()},
               %{"elicitation" => %{}},
               []
             )

    assert error.code == -32021
    assert error.data == %{"requiredCapabilities" => %{"sampling" => %{}}}
  end

  test "dispatches sequential inputs in deterministic request-id order by default" do
    requests = %{
      "z-last" => elicitation_request("last"),
      "a-first" => elicitation_request("first")
    }

    assert {:ok, responses, _state} =
             MRTR.fulfill(
               requests,
               Handler,
               %{owner: self()},
               %{"elicitation" => %{"form" => %{}}}
             )

    assert_receive {:elicitation, "first", %{}}
    assert_receive {:elicitation, "last", %{}}
    assert Map.keys(responses) |> Enum.sort() == ["a-first", "z-last"]
  end

  test "runs input callbacks concurrently only when the handler opts in" do
    owner = self()

    task =
      Task.async(fn ->
        MRTR.fulfill(
          %{"a" => elicitation_request("a"), "b" => elicitation_request("b")},
          ConcurrentHandler,
          %{owner: owner},
          %{"elicitation" => %{"form" => %{}}}
        )
      end)

    started =
      for _index <- 1..2 do
        assert_receive {:parallel_mrtr_started, message, callback_pid}
        {message, callback_pid}
      end

    assert started |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["a", "b"]

    Enum.each(started, fn {_message, callback_pid} ->
      send(callback_pid, :release_parallel_mrtr)
    end)

    assert {:ok, %{"a" => _, "b" => _}, %{owner: ^owner}} = Task.await(task)
  end

  test "rejects handler-state updates from parallel input callbacks" do
    assert {:error, error, %{owner: owner}} =
             MRTR.fulfill(
               %{"a" => elicitation_request("a"), "b" => elicitation_request("b")},
               MutatingConcurrentHandler,
               %{owner: self()},
               %{"elicitation" => %{"form" => %{}}}
             )

    assert owner == self()
    assert error.code == -32602
    assert error.message == "Parallel MRTR input callbacks must not update handler state"
    assert error.data["inputRequestId"] in ["a", "b"]
  end

  test "an overall timeout cancels the in-flight input callback scope" do
    owner = self()

    {:ok, client} =
      start_supervised(
        {Client,
         _skip_connect: true,
         handler: {SlowHandler, [owner: owner]},
         capabilities: %{"elicitation" => %{"form" => %{}}},
         health_check_interval: nil}
      )

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: RoundTripTransport,
          transport_state: %{owner: owner, round: 0},
          protocol_version: "2026-07-28",
          connection_status: :ready,
          initialized: true
      }
    end)

    call =
      Task.async(fn ->
        Client.call_tool(client, "collect", %{}, format: :map, timeout: 2_000)
      end)

    assert_receive {:slow_mrtr_started, callback_pid}, 1_000
    callback_ref = Process.monitor(callback_pid)

    assert {:error, :timeout} = Task.await(call, 3_000)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback_pid, :killed}, 1_000
    refute_receive :slow_mrtr_finished
    assert map_size(:sys.get_state(client).mrtr_tasks) == 0
  end

  defp elicitation_request(message) do
    %{
      "method" => "elicitation/create",
      "params" => %{"message" => message, "requestedSchema" => %{}}
    }
  end
end
