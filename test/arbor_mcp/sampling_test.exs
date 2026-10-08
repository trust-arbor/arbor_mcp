defmodule Arbor.MCP.SamplingTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Protocol

  describe "sampling protocol encoding" do
    test "encodes create_message request correctly" do
      params = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => %{
              "type" => "text",
              "text" => "Hello, how are you?"
            }
          }
        ],
        "modelPreferences" => %{
          "hints" => ["gpt-4"],
          "costPriority" => 0.5,
          "speedPriority" => 0.7,
          "intelligencePriority" => 0.8
        },
        "maxTokens" => 150,
        "temperature" => 0.7
      }

      request = Protocol.encode_create_message(params)

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "sampling/createMessage"
      assert request["params"] == params
      assert is_integer(request["id"])
    end

    test "handles all model preference fields" do
      params = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Test"}}
        ],
        "modelPreferences" => %{
          "hints" => ["gpt-4", "claude-3"],
          "costPriority" => 0.3,
          "speedPriority" => 0.6,
          "intelligencePriority" => 0.9
        }
      }

      request = Protocol.encode_create_message(params)
      prefs = request["params"]["modelPreferences"]

      assert prefs["hints"] == ["gpt-4", "claude-3"]
      assert prefs["costPriority"] == 0.3
      assert prefs["speedPriority"] == 0.6
      assert prefs["intelligencePriority"] == 0.9
    end

    test "encodes response correctly" do
      response_data = %{
        "role" => "assistant",
        "content" => %{
          "type" => "text",
          "text" => "Hello! How can I help you today?"
        },
        "model" => "gpt-4"
      }

      response = Protocol.encode_response(response_data, "test-123")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "test-123"
      assert response["result"] == response_data
    end

    test "encodes error response correctly" do
      response =
        Protocol.encode_error(-32603, "Sampling approval denied by user", nil, "test-456")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "test-456"
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "Sampling approval denied by user"
    end
  end

  describe "approval handler behaviour" do
    defmodule TestApprovalHandler do
      @behaviour Arbor.MCP.Approval

      @impl true
      def request_approval(_type, data, opts) do
        case Keyword.get(opts, :action, :approve) do
          :approve -> {:approved, data}
          :deny -> {:denied, "Request denied by test"}
          :modify -> {:modified, Map.put(data, "modified", true)}
        end
      end
    end

    test "approval handler can approve requests" do
      params = %{"messages" => [], "modelPreferences" => %{}}

      result = TestApprovalHandler.request_approval(:sampling, params, action: :approve)

      assert {:approved, ^params} = result
    end

    test "approval handler can deny requests" do
      params = %{"messages" => [], "modelPreferences" => %{}}

      result = TestApprovalHandler.request_approval(:sampling, params, action: :deny)

      assert {:denied, "Request denied by test"} = result
    end

    test "approval handler can modify requests" do
      params = %{"messages" => [], "modelPreferences" => %{}}

      result = TestApprovalHandler.request_approval(:sampling, params, action: :modify)

      assert {:modified, modified_params} = result
      assert modified_params["modified"] == true
    end
  end

  describe "sampling message validation" do
    test "validates required message fields" do
      # Valid message
      valid_message = %{
        "role" => "user",
        "content" => %{
          "type" => "text",
          "text" => "Hello"
        }
      }

      assert valid_message?(valid_message)

      # Missing role
      invalid_message = %{
        "content" => %{"type" => "text", "text" => "Hello"}
      }

      refute valid_message?(invalid_message)

      # Missing content
      invalid_message2 = %{
        "role" => "user"
      }

      refute valid_message?(invalid_message2)
    end

    test "validates model preferences structure" do
      # Valid preferences
      valid_prefs = %{
        "hints" => ["gpt-4"],
        "costPriority" => 0.5,
        "speedPriority" => 0.7,
        "intelligencePriority" => 0.8
      }

      assert valid_model_preferences?(valid_prefs)

      # Invalid priority value (> 1.0)
      invalid_prefs = %{
        "costPriority" => 1.5
      }

      refute valid_model_preferences?(invalid_prefs)

      # Invalid priority value (< 0.0)
      invalid_prefs2 = %{
        "speedPriority" => -0.1
      }

      refute valid_model_preferences?(invalid_prefs2)
    end

    test "validates sampling parameters" do
      # Valid params
      valid_params = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hi"}}
        ],
        "modelPreferences" => %{"hints" => ["gpt-4"]},
        "maxTokens" => 100,
        "temperature" => 0.7
      }

      assert valid_sampling_params?(valid_params)

      # Missing messages
      invalid_params = %{
        "modelPreferences" => %{}
      }

      refute valid_sampling_params?(invalid_params)

      # Invalid temperature
      invalid_params2 = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Hi"}}
        ],
        # Too high
        "temperature" => 3.0
      }

      refute valid_sampling_params?(invalid_params2)
    end
  end

  describe "human-in-the-loop simulation" do
    test "sampling flow with approval" do
      # Simulate the sampling flow:
      # 1. Server requests sampling
      # 2. Client requests approval
      # 3. User approves
      # 4. Client generates response
      # 5. Client requests approval for response
      # 6. User approves response
      # 7. Client returns response to server

      # Step 1: Server creates sampling request
      sampling_request = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "What is AI?"}}
        ],
        "modelPreferences" => %{"hints" => ["gpt-4"], "intelligencePriority" => 0.8}
      }

      # Step 2: Client requests approval (simulate approved)
      approval_result =
        __MODULE__.TestApprovalHandler.request_approval(
          :sampling,
          sampling_request,
          action: :approve
        )

      assert {:approved, approved_request} = approval_result
      assert approved_request == sampling_request

      # Step 3: Generate mock LLM response
      mock_response = %{
        "role" => "assistant",
        "content" => %{
          "type" => "text",
          "text" => "AI stands for Artificial Intelligence, a field of computer science."
        },
        "model" => "gpt-4"
      }

      # Step 4: Request approval for response (simulate approved)
      response_approval =
        __MODULE__.TestApprovalHandler.request_approval(
          :response,
          mock_response,
          action: :approve
        )

      assert {:approved, approved_response} = response_approval
      assert approved_response == mock_response
    end

    test "sampling flow with denial" do
      sampling_request = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Inappropriate request"}}
        ]
      }

      # User denies the sampling request
      approval_result =
        __MODULE__.TestApprovalHandler.request_approval(
          :sampling,
          sampling_request,
          action: :deny
        )

      assert {:denied, "Request denied by test"} = approval_result
    end

    test "sampling flow with modification" do
      original_request = %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Original message"}}
        ],
        "modelPreferences" => %{"hints" => ["gpt-3.5"]}
      }

      # User modifies the request
      approval_result =
        __MODULE__.TestApprovalHandler.request_approval(
          :sampling,
          original_request,
          action: :modify
        )

      assert {:modified, modified_request} = approval_result
      assert modified_request["modified"] == true
      assert modified_request["messages"] == original_request["messages"]
    end
  end

  # Helper functions for validation
  defp valid_message?(%{"role" => role, "content" => content})
       when role in ["user", "assistant", "system"] and is_map(content) do
    Map.has_key?(content, "type") and Map.has_key?(content, "text")
  end

  defp valid_message?(_), do: false

  defp valid_model_preferences?(prefs) when is_map(prefs) do
    Enum.all?(prefs, fn
      {"hints", hints} when is_list(hints) -> true
      {"costPriority", p} when is_number(p) and p >= 0.0 and p <= 1.0 -> true
      {"speedPriority", p} when is_number(p) and p >= 0.0 and p <= 1.0 -> true
      {"intelligencePriority", p} when is_number(p) and p >= 0.0 and p <= 1.0 -> true
      _ -> false
    end)
  end

  defp valid_model_preferences?(_), do: false

  defp valid_sampling_params?(%{"messages" => messages} = params)
       when is_list(messages) and length(messages) > 0 do
    valid_messages?(messages) and
      valid_model_preferences_param?(params) and
      valid_temperature_param?(params) and
      valid_max_tokens_param?(params)
  end

  defp valid_sampling_params?(_), do: false

  defp valid_messages?(messages) do
    Enum.all?(messages, &valid_message?/1)
  end

  defp valid_model_preferences_param?(params) do
    case Map.get(params, "modelPreferences") do
      nil -> true
      prefs -> valid_model_preferences?(prefs)
    end
  end

  defp valid_temperature_param?(params) do
    case Map.get(params, "temperature") do
      nil -> true
      temp when is_number(temp) and temp >= 0.0 and temp <= 2.0 -> true
      _ -> false
    end
  end

  defp valid_max_tokens_param?(params) do
    case Map.get(params, "maxTokens") do
      nil -> true
      tokens when is_integer(tokens) and tokens > 0 -> true
      _ -> false
    end
  end
end
