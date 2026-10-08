defmodule Arbor.MCP.Client.ToolCallingSamplingTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.RequestHandler

  defmodule MockTransport do
    @behaviour Arbor.MCP.Transport

    defstruct [:test_pid]

    @impl true
    def connect(opts) do
      {:ok, %__MODULE__{test_pid: Keyword.get(opts, :test_pid)}}
    end

    @impl true
    def send_message(message, %__MODULE__{test_pid: test_pid} = state) do
      send(test_pid, {:sent_message, message})
      {:ok, state}
    end

    @impl true
    def receive_message(%__MODULE__{} = state) do
      receive do
        {:mock_message, msg} -> {:ok, msg, state}
      after
        5000 -> {:error, :timeout}
      end
    end

    @impl true
    def close(_state), do: :ok

    @impl true
    def connected?(_state), do: true
  end

  defmodule TestSamplingHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(params, state) do
      # Echo back the params so the test can verify they were received
      tools = Map.get(params, "tools", [])
      tool_choice = Map.get(params, "toolChoice")

      result = %{
        "role" => "assistant",
        "content" => %{
          "type" => "text",
          "text" => "Response with #{length(tools)} tools available"
        },
        "model" => "test-model",
        "_received_tools" => tools,
        "_received_toolChoice" => tool_choice
      }

      {:ok, result, state}
    end
  end

  defmodule ErrorSamplingHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state) do
      {:error, "Sampling request denied by user", state}
    end
  end

  defmodule NoSamplingHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state) do
      {:error, "Not implemented", state}
    end
  end

  defmodule ElicitationHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state) do
      {:error, "Not implemented", state}
    end

    @impl true
    def handle_elicitation_create(message, requested_schema, state) do
      {:ok,
       %{
         "action" => "accept",
         "content" => %{"message" => message, "schema_keys" => Map.keys(requested_schema)}
       }, state}
    end
  end

  defmodule BothElicitationHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "Not implemented", state}

    @impl true
    def handle_elicitation_create(message, schema, state) do
      send(state.test_pid, {:form_elicitation, message, schema})
      {:ok, %{"action" => "accept"}, state}
    end

    @impl true
    def handle_url_elicitation(message, url, state) do
      send(state.test_pid, {:url_elicitation, message, url})
      {:ok, %{"action" => "accept"}, state}
    end
  end

  defmodule UrlOnlyElicitationHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "Not implemented", state}

    @impl true
    def handle_url_elicitation(message, url, state) do
      send(state.test_pid, {:url_only_elicitation, message, url})
      {:ok, %{"action" => "accept"}, state}
    end
  end

  defmodule FormOnlyFallbackHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "Not implemented", state}

    @impl true
    def handle_elicitation_create(message, payload, state) do
      send(state.test_pid, {:fallback_elicitation, message, payload})
      {:ok, %{"action" => "accept"}, state}
    end
  end

  setup do
    transport_state = %MockTransport{test_pid: self()}

    base_state = %{
      transport_mod: MockTransport,
      transport_state: transport_state,
      transport_opts: [],
      pending_requests: %{},
      client_handler: nil,
      server_request_tasks: %{}
    }

    {:ok, base_state: base_state}
  end

  # Slow handler callbacks (sampling/elicitation/custom) now run in a
  # monitored task; the client process receives {:server_request_result, ...}
  # and completes the request. These tests call the RequestHandler directly,
  # so the test process plays the client loop's role here.
  defp complete_async(state) do
    assert_receive {:server_request_result, task_pid, outcome}, 1_000
    RequestHandler.handle_server_request_completion(task_pid, outcome, state)
  end

  describe "sampling/createMessage dispatch in request handler" do
    test "dispatches to handler's handle_create_message with tools and toolChoice", %{
      base_state: base_state
    } do
      state = %{
        base_state
        | transport_opts: [handler: TestSamplingHandler, handler_state: []]
      }

      params = %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}],
        "maxTokens" => 100,
        "tools" => [
          %{
            "name" => "get_weather",
            "description" => "Get weather for a city",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{"city" => %{"type" => "string"}}
            }
          }
        ],
        "toolChoice" => %{"type" => "auto"}
      }

      request_id = 42

      {:noreply, new_state} =
        RequestHandler.handle_server_request("sampling/createMessage", params, request_id, state)

      {:noreply, _final_state} = complete_async(new_state)

      # Verify the response was sent via transport
      assert_receive {:sent_message, encoded_response}
      {:ok, response} = Jason.decode(encoded_response)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 42
      assert response["result"]["role"] == "assistant"
      assert response["result"]["model"] == "test-model"
      # Verify tools were passed through
      assert response["result"]["_received_tools"] == params["tools"]
      assert response["result"]["_received_toolChoice"] == params["toolChoice"]
    end

    test "dispatches sampling/createMessage without tools (basic sampling)", %{
      base_state: base_state
    } do
      state = %{
        base_state
        | transport_opts: [handler: TestSamplingHandler, handler_state: []]
      }

      params = %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}],
        "maxTokens" => 50
      }

      request_id = 43

      {:noreply, new_state} =
        RequestHandler.handle_server_request("sampling/createMessage", params, request_id, state)

      {:noreply, _final_state} = complete_async(new_state)

      assert_receive {:sent_message, encoded_response}
      {:ok, response} = Jason.decode(encoded_response)

      assert response["id"] == 43
      assert response["result"]["_received_tools"] == []
      assert response["result"]["_received_toolChoice"] == nil
    end

    test "returns error when handler denies sampling request", %{base_state: base_state} do
      state = %{
        base_state
        | transport_opts: [handler: ErrorSamplingHandler, handler_state: []]
      }

      params = %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}],
        "maxTokens" => 100
      }

      request_id = 44

      {:noreply, new_state} =
        RequestHandler.handle_server_request("sampling/createMessage", params, request_id, state)

      {:noreply, _final_state} = complete_async(new_state)

      assert_receive {:sent_message, encoded_response}
      {:ok, response} = Jason.decode(encoded_response)

      assert response["id"] == 44
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "Sampling request denied by user"
    end

    test "returns method not found when no handler configured", %{base_state: base_state} do
      state = %{base_state | transport_opts: []}

      params = %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}]
      }

      request_id = 45

      {:noreply, _new_state} =
        RequestHandler.handle_server_request("sampling/createMessage", params, request_id, state)

      assert_receive {:sent_message, encoded_response}
      {:ok, response} = Jason.decode(encoded_response)

      assert response["id"] == 45
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "Method not found"
    end
  end

  describe "elicitation/create dispatch in request handler" do
    test "dispatches to handler's handle_elicitation_create", %{base_state: base_state} do
      state = %{
        base_state
        | transport_opts: [handler: ElicitationHandler, handler_state: []]
      }

      params = %{
        "message" => "Please provide your API key",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "api_key" => %{"type" => "string"}
          }
        }
      }

      request_id = 50

      {:noreply, new_state} =
        RequestHandler.handle_server_request("elicitation/create", params, request_id, state)

      {:noreply, _final_state} = complete_async(new_state)

      assert_receive {:sent_message, encoded_response}
      {:ok, response} = Jason.decode(encoded_response)

      assert response["id"] == 50
      assert response["result"]["action"] == "accept"
      assert response["result"]["content"]["message"] == "Please provide your API key"
    end

    test "returns method not found when handler doesn't implement elicitation", %{
      base_state: base_state
    } do
      # TestSamplingHandler doesn't implement handle_elicitation_create
      state = %{
        base_state
        | transport_opts: [handler: TestSamplingHandler, handler_state: []]
      }

      params = %{
        "message" => "Please provide info",
        "requestedSchema" => %{}
      }

      request_id = 51

      {:noreply, _new_state} =
        RequestHandler.handle_server_request("elicitation/create", params, request_id, state)

      assert_receive {:sent_message, encoded_response}
      {:ok, response} = Jason.decode(encoded_response)

      assert response["id"] == 51
      assert response["error"]["code"] == -32601
    end

    test "form mode still dispatches to the form callback when both callbacks exist", %{
      base_state: base_state
    } do
      state = %{
        base_state
        | transport_opts: [handler: BothElicitationHandler, handler_state: [test_pid: self()]]
      }

      params = %{
        "message" => "Choose a project",
        "requestedSchema" => %{"type" => "object"}
      }

      {:noreply, state} =
        RequestHandler.handle_server_request("elicitation/create", params, 52, state)

      {:noreply, _state} = complete_async(state)

      assert_receive {:form_elicitation, "Choose a project", %{"type" => "object"}}
      refute_receive {:url_elicitation, _, _}
    end

    test "URL mode prefers handle_url_elicitation when both callbacks exist", %{
      base_state: base_state
    } do
      state = %{
        base_state
        | transport_opts: [handler: BothElicitationHandler, handler_state: [test_pid: self()]]
      }

      params = %{
        "mode" => "url",
        "message" => "Authorize access",
        "url" => "https://example.com/authorize",
        "elicitationId" => "elicit-1"
      }

      {:noreply, state} =
        RequestHandler.handle_server_request("elicitation/create", params, 53, state)

      {:noreply, _state} = complete_async(state)

      assert_receive {:url_elicitation, "Authorize access", "https://example.com/authorize"}
      refute_receive {:form_elicitation, _, _}
    end

    test "URL-only handlers receive URL-mode requests", %{base_state: base_state} do
      state = %{
        base_state
        | transport_opts: [handler: UrlOnlyElicitationHandler, handler_state: [test_pid: self()]]
      }

      params = %{
        "mode" => "url",
        "message" => "Authorize access",
        "url" => "https://example.com/authorize",
        "elicitationId" => "elicit-2"
      }

      {:noreply, state} =
        RequestHandler.handle_server_request("elicitation/create", params, 54, state)

      {:noreply, _state} = complete_async(state)

      assert_receive {:url_only_elicitation, "Authorize access", "https://example.com/authorize"}
    end

    test "form-only handlers retain URL fallback with the complete URL payload and one warning",
         %{
           base_state: base_state
         } do
      state = %{
        base_state
        | transport_opts: [handler: FormOnlyFallbackHandler, handler_state: [test_pid: self()]]
      }

      params = %{
        "mode" => "url",
        "message" => "Authorize access",
        "url" => "https://example.com/authorize",
        "elicitationId" => "elicit-3"
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:noreply, state} =
            RequestHandler.handle_server_request("elicitation/create", params, 55, state)

          {:noreply, state} = complete_async(state)

          {:noreply, state} =
            RequestHandler.handle_server_request("elicitation/create", params, 56, state)

          {:noreply, _state} = complete_async(state)
        end)

      expected_payload = %{
        "mode" => "url",
        "url" => "https://example.com/authorize",
        "elicitationId" => "elicit-3"
      }

      assert_receive {:fallback_elicitation, "Authorize access", ^expected_payload}
      assert_receive {:fallback_elicitation, "Authorize access", ^expected_payload}

      assert length(Regex.scan(~r/does not implement handle_url_elicitation\/3/, log)) == 1
    end
  end

  describe "parse_transport_message routes server requests" do
    test "routes sampling/createMessage to handler via parse_transport_message", %{
      base_state: base_state
    } do
      state = %{
        base_state
        | transport_opts: [handler: TestSamplingHandler, handler_state: []]
      }

      message =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "sampling/createMessage",
          "params" => %{
            "messages" => [
              %{"role" => "user", "content" => %{"type" => "text", "text" => "Test"}}
            ],
            "maxTokens" => 100,
            "tools" => [%{"name" => "calc", "description" => "Calculator", "inputSchema" => %{}}]
          },
          "id" => 99
        })

      {:noreply, new_state} = RequestHandler.parse_transport_message(message, state)
      {:noreply, _final_state} = complete_async(new_state)

      assert_receive {:sent_message, encoded_response}
      {:ok, response} = Jason.decode(encoded_response)

      assert response["id"] == 99
      assert response["result"]["role"] == "assistant"
    end
  end
end
