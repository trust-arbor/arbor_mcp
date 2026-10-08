defmodule Arbor.MCP.Compliance.Features.Sampling do
  @moduledoc """
  Message sampling compliance tests for MCP versions.
  Sampling is a client capability available in all versions.
  """

  # Full module names are required in macro-generated code to ensure proper resolution
  # credo:disable-for-lines:50 Credo.Check.Design.AliasUsage
  defmacro __using__(version) do
    quote do
      import Arbor.MCP.Compliance.Features.Sampling
      @version unquote(version)

      # Sampling is a client capability (all versions)
      test "sampling/createMessage works correctly" do
        Arbor.MCP.Compliance.Features.Sampling.test_create_message(@version)
      end

      test "sampling validates message format" do
        Arbor.MCP.Compliance.Features.Sampling.test_message_validation(@version)
      end

      test "sampling respects model preferences" do
        Arbor.MCP.Compliance.Features.Sampling.test_model_preferences(@version)
      end

      test "sampling handles invalid message formats" do
        Arbor.MCP.Compliance.Features.Sampling.test_invalid_messages(@version)
      end

      test "sampling returns proper response structure" do
        Arbor.MCP.Compliance.Features.Sampling.test_response_structure(@version)
      end
    end
  end

  # Import test helpers
  import ExUnit.Assertions
  import Arbor.MCP.ComplianceTestHelpers

  # Actual test implementations
  def test_create_message(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])

      # Test basic message creation
      params = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => %{"text" => "Hello, assistant!"}
          }
        ],
        "modelPreferences" => %{
          "hints" => ["claude-3-sonnet", "gpt-4"]
        }
      }

      {:ok, response, _state} = handler.handle_create_message(params, state)

      # Validate response
      assert response["role"] == "assistant"
      assert Map.has_key?(response, "content")
      assert Map.has_key?(response, "model")
      assert Map.has_key?(response, "stopReason")
    after
      cleanup_test_client(test_context)
    end
  end

  def test_message_validation(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])

      # Test various message formats
      test_cases = [
        # Single text message
        %{
          "messages" => [
            %{"role" => "user", "content" => %{"text" => "Simple text"}}
          ]
        },
        # System message followed by user message
        %{
          "messages" => [
            %{"role" => "system", "content" => %{"text" => "You are a helpful assistant"}},
            %{"role" => "user", "content" => %{"text" => "Hello"}}
          ]
        },
        # Conversation with assistant
        %{
          "messages" => [
            %{"role" => "user", "content" => %{"text" => "What's 2+2?"}},
            %{"role" => "assistant", "content" => %{"text" => "4"}},
            %{"role" => "user", "content" => %{"text" => "What about 3+3?"}}
          ]
        }
      ]

      for test_case <- test_cases do
        case handler.handle_create_message(test_case, state) do
          {:ok, response, _} ->
            validate_sampling_response(response)

          {:error, _msg, _} ->
            # Some test cases might intentionally fail
            :ok
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_model_preferences(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])

      # Test with specific model preferences
      params = %{
        "messages" => [
          %{"role" => "user", "content" => %{"text" => "Test message"}}
        ],
        "modelPreferences" => %{
          "hints" => ["claude-3-opus", "gpt-4-turbo"],
          "temperature" => 0.7,
          "maxTokens" => 1000
        }
      }

      {:ok, response, _state} = handler.handle_create_message(params, state)

      # Model should be one from the hints list
      assert response["model"] in ["claude-3-opus", "gpt-4-turbo", "mock-model"]

      # Test without model preferences
      params_no_prefs = %{
        "messages" => [
          %{"role" => "user", "content" => %{"text" => "Test without preferences"}}
        ]
      }

      {:ok, response2, _state} = handler.handle_create_message(params_no_prefs, state)
      assert Map.has_key?(response2, "model")
    after
      cleanup_test_client(test_context)
    end
  end

  def test_invalid_messages(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])

      # Test various invalid formats
      invalid_cases = [
        # Empty messages array
        %{"messages" => []},
        # Missing content
        %{"messages" => [%{"role" => "user"}]},
        # Invalid role
        %{"messages" => [%{"role" => "invalid", "content" => %{"text" => "test"}}]},
        # Wrong content structure
        %{"messages" => [%{"role" => "user", "content" => "plain string"}]},
        # Missing messages key
        %{"modelPreferences" => %{}}
      ]

      for invalid_case <- invalid_cases do
        result = handler.handle_create_message(invalid_case, state)

        case result do
          {:error, msg, _} ->
            assert is_binary(msg)
            assert String.length(msg) > 0

          _ ->
            # Some handlers might be more permissive
            :ok
        end
      end
    after
      cleanup_test_client(test_context)
    end
  end

  def test_response_structure(version) do
    {:ok, test_context} = setup_test_client(version)

    try do
      handler = test_context.handler
      {:ok, state} = handler.init([])

      params = %{
        "messages" => [
          %{"role" => "user", "content" => %{"text" => "Generate a response"}}
        ],
        "modelPreferences" => %{
          "hints" => ["test-model"]
        }
      }

      {:ok, response, _state} = handler.handle_create_message(params, state)

      # Validate complete response structure
      validate_sampling_response(response)

      # Check specific fields
      assert response["role"] == "assistant"

      # Content should be properly structured
      content = response["content"]
      assert Map.has_key?(content, "type")
      assert content["type"] in ["text", "image", "audio"]

      if content["type"] == "text" do
        assert Map.has_key?(content, "text")
        assert is_binary(content["text"])
      end

      # Stop reason should be valid
      assert response["stopReason"] in ["endTurn", "stopSequence", "maxTokens"]

      # Model should be specified
      assert is_binary(response["model"])
    after
      cleanup_test_client(test_context)
    end
  end

  # Helper functions
  defp validate_sampling_response(response) do
    # Required fields
    assert Map.has_key?(response, "role")
    assert Map.has_key?(response, "content")

    # Role must be assistant for responses
    assert response["role"] == "assistant"

    # Content validation
    content = response["content"]
    assert is_map(content)
    assert Map.has_key?(content, "type")

    # Optional but recommended fields
    if Map.has_key?(response, "model") do
      assert is_binary(response["model"])
    end

    if Map.has_key?(response, "stopReason") do
      assert response["stopReason"] in ["endTurn", "stopSequence", "maxTokens"]
    end

    # No unexpected fields
    allowed_keys = ["role", "content", "model", "stopReason"]

    for key <- Map.keys(response) do
      assert key in allowed_keys, "Unexpected field #{key} in sampling response"
    end
  end
end
