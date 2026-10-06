defmodule Arbor.MCP.Client.HTTPStreamRetryTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error

  defmodule FakeClient do
    use GenServer

    def start_link(responses, opts \\ []) do
      GenServer.start_link(__MODULE__, {responses, opts})
    end

    @impl true
    def init({responses, opts}) do
      {:ok,
       %{
         responses: responses,
         calls: [],
         default_timeout: Keyword.get(opts, :default_timeout, 1_000),
         conformance_mode: Keyword.get(opts, :conformance_mode, false)
       }}
    end

    @impl true
    def handle_call({:request, method, params, _meta}, _from, state) do
      [response | responses] = state.responses
      response = resolve_response(response)
      calls = state.calls ++ [{method, params}]
      {:reply, response, %{state | responses: responses, calls: calls}}
    end

    def handle_call(:get_default_retry_policy, _from, state), do: {:reply, {:ok, []}, state}

    def handle_call(:get_default_timeout, _from, state),
      do: {:reply, {:ok, state.default_timeout}, state}

    def handle_call(:conformance_mode?, _from, state),
      do: {:reply, state.conformance_mode, state}

    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

    @impl true
    def handle_cast({:cancel_mrtr_scope, _scope_ref}, state), do: {:noreply, state}

    defp resolve_response({:sleep, milliseconds, response}) do
      Process.sleep(milliseconds)
      response
    end

    defp resolve_response(response), do: response
  end

  test "the default retries one ambiguous stream break" do
    {:ok, client} = FakeClient.start_link([broken(:closed), {:ok, %{"resultType" => "complete"}}])

    assert {:ok, %{"resultType" => "complete"}} =
             request(client, "tools/call", http_stream_retry_delay: 0)

    assert length(GenServer.call(client, :calls)) == 2
  end

  test "safe-only returns outcome_unknown for a side-effecting request" do
    {:ok, client} = FakeClient.start_link([broken(:closed)])

    assert {:error,
            %Error.TransportError{
              reason: :outcome_unknown,
              details: %{attempts: 1, retry_mode: :safe_only}
            }} = request(client, "tools/call", http_stream_retry: :safe_only)

    assert length(GenServer.call(client, :calls)) == 1
  end

  test "safe-only retries intrinsically safe methods and caller-attested tools" do
    {:ok, read_client} = FakeClient.start_link([broken(:closed), {:ok, %{}}])

    assert {:ok, %{}} =
             request(read_client, "resources/read",
               http_stream_retry: :safe_only,
               http_stream_retry_delay: 0
             )

    assert length(GenServer.call(read_client, :calls)) == 2

    {:ok, tool_client} = FakeClient.start_link([broken(:closed), {:ok, %{}}])

    assert {:ok, %{}} =
             request(tool_client, "tools/call",
               http_stream_retry: :safe_only,
               retry_safe: true,
               http_stream_retry_delay: 0
             )

    assert length(GenServer.call(tool_client, :calls)) == 2
  end

  test "a second broken response reports outcome_unknown without a third attempt" do
    {:ok, client} = FakeClient.start_link([broken(:closed), broken(:reset)])

    assert {:error,
            %Error.TransportError{
              reason: :outcome_unknown,
              details: %{attempts: 2, retry_mode: :at_least_once}
            }} = request(client, "tools/call", http_stream_retry_delay: 0)

    assert length(GenServer.call(client, :calls)) == 2
  end

  test "retry backoff cannot exceed the original deadline" do
    {:ok, client} = FakeClient.start_link([{:sleep, 15, broken(:closed)}, {:ok, %{}}])

    assert {:error, :timeout} =
             request(client, "tools/call", timeout: 20, http_stream_retry_delay: 10)

    assert length(GenServer.call(client, :calls)) == 1
  end

  test "invalid streams, protocol errors, and cancellation are not retried" do
    invalid =
      {:error,
       Error.transport_error(:http, :response_stream_invalid, %{
         cause: :response_id_mismatch,
         delivery: :not_retryable
       })}

    for response <- [
          invalid,
          {:error, %{"code" => -32603, "message" => "failed"}},
          {:error, :cancelled}
        ] do
      {:ok, client} = FakeClient.start_link([response])
      assert {:error, _reason} = request(client, "tools/call")
      assert length(GenServer.call(client, :calls)) == 1
    end
  end

  test "safe-only is rejected before dispatch in conformance mode" do
    {:ok, client} = FakeClient.start_link([], conformance_mode: true)

    assert {:error,
            %Error.ValidationError{
              field: :http_stream_retry,
              value: :safe_only
            }} = request(client, "resources/read", http_stream_retry: :safe_only)

    assert GenServer.call(client, :calls) == []
  end

  test "application idempotency keys are injected once and remain stable across retry" do
    {:ok, client} = FakeClient.start_link([broken(:closed), {:ok, %{}}])

    assert {:ok, %{}} =
             Client.call_tool(client, "charge", %{"amount" => 100},
               idempotency_key: "order-123",
               idempotency_key_path: ["request", "idempotencyKey"],
               progress_token: "charge-progress",
               http_stream_retry_delay: 0,
               format: :map
             )

    assert [first, second] = GenServer.call(client, :calls)
    assert first == second

    assert {"tools/call",
            %{
              "arguments" => %{
                "amount" => 100,
                "request" => %{"idempotencyKey" => "order-123"}
              }
            }} = first
  end

  test "idempotency-key conflicts fail before dispatch" do
    {:ok, client} = FakeClient.start_link([])

    assert {:error,
            %Error.ValidationError{
              field: :idempotency_key,
              reason: "conflicts with the existing value at the configured path"
            }} =
             Client.call_tool(client, "charge", %{"idempotencyKey" => "existing"},
               idempotency_key: "different"
             )

    assert GenServer.call(client, :calls) == []
  end

  defp request(client, method, opts \\ []) do
    opts = Keyword.put_new(opts, :format, :map)
    Client.make_request(client, method, %{}, opts, 1_000)
  end

  defp broken(cause) do
    {:error,
     Error.transport_error(:http, :response_stream_broken, %{
       cause: cause,
       delivery: :ambiguous
     })}
  end
end
