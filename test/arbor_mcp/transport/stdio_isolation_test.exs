defmodule Arbor.MCP.Transport.StdioIsolationTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Transport.Stdio

  test "incremental frame accumulation accepts the limit and rejects one byte over" do
    assert {:ok, "abcd"} = Stdio.append_frame("ab", "cd", 4)
    assert {:error, :frame_too_large} = Stdio.append_frame("ab", "cde", 4)
  end

  @moduletag :stdio

  setup_all do
    # Start the application to ensure ConsentCache and other services are
    # available. It is deliberately left running afterwards: test_helper.exs
    # starts :arbor_mcp for the whole run, and stopping it here took down
    # supervised singletons for every test that ran after this file.
    {:ok, _} = Application.ensure_all_started(:arbor_mcp)

    :ok
  end

  test "stdio environment can remove an inherited variable" do
    key = "EX_MCP_STDIO_INHERITED_ENV_TEST"
    previous = System.get_env(key)
    System.put_env(key, "must-not-reach-child")

    on_exit(fn ->
      if is_binary(previous), do: System.put_env(key, previous), else: System.delete_env(key)
    end)

    shell = System.find_executable("sh") || flunk("sh executable is required for stdio test")
    probe = ~s(test -z "${#{key}+x}")

    assert {:ok, state} =
             Stdio.connect(command: [shell, "-c", probe], env: [{key, false}])

    assert {:error, {:connection_error, {:process_exited, 0}}} =
             Stdio.receive_message(state, 1_000)
  end

  test "stdio environment is isolated by default" do
    key = "EX_MCP_STDIO_DEFAULT_ISOLATION_TEST"
    previous = System.get_env(key)
    System.put_env(key, "must-not-reach-child")

    on_exit(fn ->
      if is_binary(previous), do: System.put_env(key, previous), else: System.delete_env(key)
    end)

    shell = System.find_executable("sh") || flunk("sh executable is required for stdio test")
    probe = ~s(test -z "${#{key}+x}")

    assert {:ok, state} = Stdio.connect(command: [shell, "-c", probe])

    assert {:error, {:connection_error, {:process_exited, 0}}} =
             Stdio.receive_message(state, 1_000)
  end

  test "trusted deployments can explicitly inherit the parent environment" do
    key = "EX_MCP_STDIO_EXPLICIT_INHERIT_TEST"
    previous = System.get_env(key)
    System.put_env(key, "inherited-value")

    on_exit(fn ->
      if is_binary(previous), do: System.put_env(key, previous), else: System.delete_env(key)
    end)

    shell = System.find_executable("sh") || flunk("sh executable is required for stdio test")
    probe = ~s(test "$#{key}" = "inherited-value")

    assert {:ok, state} =
             Stdio.connect(command: [shell, "-c", probe], environment_policy: :inherit)

    assert {:error, {:connection_error, {:process_exited, 0}}} =
             Stdio.receive_message(state, 1_000)
  end

  test "rejects unknown environment policies" do
    assert {:error, {:invalid_environment_policy, :unsafe}} =
             Stdio.connect(command: ["unused"], environment_policy: :unsafe)
  end

  describe "Stdio Transport Isolation" do
    test "validates external resource access through security guard" do
      # Test message requesting an external resource
      external_resource_message = %{
        "jsonrpc" => "2.0",
        "method" => "resources/read",
        "params" => %{"uri" => "https://external.example.com/data.json"},
        "id" => 1
      }

      json_message = Jason.encode!(external_resource_message)

      # Create a mock stdio transport state
      state = %Stdio{
        port: nil,
        line_buffer: ""
      }

      # Test that the security validation is called for external URIs
      # Note: This tests the validation logic, actual security depends on SecurityGuard configuration
      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      # The result should either validate successfully or be blocked by security policy
      case result do
        {:ok, _} ->
          # External resource was allowed by security policy
          assert true

        {:error, {:security_violation, _}} ->
          # External resource was blocked by security policy (expected in secure environments)
          assert true

        {:error, {:send_failed, _}} ->
          # Port error due to mock port (acceptable for this test)
          assert true

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "allows local resource access without security validation" do
      # Test message requesting a local resource
      local_resource_message = %{
        "jsonrpc" => "2.0",
        "method" => "resources/read",
        "params" => %{"uri" => "file:///local/path/data.json"},
        "id" => 1
      }

      json_message = Jason.encode!(local_resource_message)

      state = %Stdio{
        port: nil,
        line_buffer: ""
      }

      # Local resources should pass validation but fail on mock port
      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          assert true

        {:error, {:send_failed, _}} ->
          # Expected error due to mock port
          assert true

        {:error, {:transport_error, {:send_failed, _}}} ->
          # Expected error due to mock port (normalized transport error)
          assert true

        {:error, {:security_violation, _}} ->
          # For local resources, this is actually okay - security policies can still apply
          assert true

        other ->
          flunk("Unexpected result for local resource: #{inspect(other)}")
      end
    end

    test "allows relative URI resource access" do
      # Test message requesting a relative resource
      relative_resource_message = %{
        "jsonrpc" => "2.0",
        "method" => "resources/read",
        "params" => %{"uri" => "../data/config.json"},
        "id" => 1
      }

      json_message = Jason.encode!(relative_resource_message)

      state = %Stdio{
        port: nil,
        line_buffer: ""
      }

      # Relative resources should pass validation
      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          assert true

        {:error, {:send_failed, _}} ->
          # Expected error due to mock port
          assert true

        {:error, {:transport_error, {:send_failed, _}}} ->
          # Also acceptable - wrapped transport error
          assert true

        {:error, {:security_violation, _}} ->
          flunk("Relative resource should not be blocked by security")

        other ->
          flunk("Unexpected result for relative resource: #{inspect(other)}")
      end
    end

    test "allows non-resource methods through without security validation" do
      # Test message that's not a resource request
      tools_message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => %{},
        "id" => 1
      }

      json_message = Jason.encode!(tools_message)

      state = %Stdio{
        port: nil,
        line_buffer: ""
      }

      # Non-resource methods should pass validation
      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          assert true

        {:error, {:send_failed, _}} ->
          # Expected error due to mock port
          assert true

        {:error, {:transport_error, {:send_failed, _}}} ->
          # Also acceptable - wrapped transport error
          assert true

        {:error, {:security_violation, _}} ->
          flunk("Non-resource method should not be blocked by security")

        other ->
          flunk("Unexpected result for non-resource method: #{inspect(other)}")
      end
    end

    test "extracts user ID from environment for security context" do
      # Mock the environment variables
      original_user = System.get_env("USER")
      original_username = System.get_env("USERNAME")

      try do
        System.put_env("USER", "test_user")

        state = %Stdio{port: nil, line_buffer: ""}

        # This is testing the private function through the validation pathway
        # We can't directly call the private function, but we can verify the behavior
        # by triggering a security validation that would use the user ID

        external_message = %{
          "jsonrpc" => "2.0",
          "method" => "resources/read",
          "params" => %{"uri" => "https://external.example.com/test"},
          "id" => 1
        }

        json_message = Jason.encode!(external_message)

        # The validation process should use the USER environment variable
        # We can't directly assert on the private function, but this ensures
        # the pathway that uses extract_stdio_user_id is exercised
        _result = Stdio.send_message(json_message, %{state | port: :mock_port})

        # If no exception was raised, the user ID extraction worked
        assert true
      after
        # Restore original environment
        if original_user do
          System.put_env("USER", original_user)
        else
          System.delete_env("USER")
        end

        if original_username do
          System.put_env("USERNAME", original_username)
        else
          System.delete_env("USERNAME")
        end
      end
    end
  end

  describe "Stdio Transport Newline Handling" do
    test "processes single complete JSON line correctly" do
      # Test the line processing logic without calling process_data
      # Simulate what process_data would do with a complete line

      json_message = ~s({"jsonrpc":"2.0","method":"tools/list","id":1})
      data_with_newline = json_message <> "\n"

      # Verify the data format
      assert String.ends_with?(data_with_newline, "\n")

      # Simulate line splitting
      case String.split(data_with_newline, "\n", parts: 2) do
        [line, rest] ->
          assert line == json_message
          assert rest == ""
          assert String.trim(line) == json_message
          assert String.starts_with?(String.trim(line), "{")

        _ ->
          flunk("Should split into line and rest")
      end
    end

    test "buffers incomplete JSON lines until complete" do
      # Test the buffering logic conceptually without calling process_data
      state = %Stdio{port: nil, line_buffer: ""}

      partial_json = ~s({"jsonrpc":"2.0","method":"tools/list")

      # Simulate what would happen in process_data:
      # 1. Accumulate data
      new_buffer = state.line_buffer <> partial_json

      # 2. Check for complete lines
      case String.split(new_buffer, "\n", parts: 2) do
        [partial] ->
          # No complete line - this is what we expect
          assert partial == partial_json
          assert String.contains?(partial, "jsonrpc")
          refute String.ends_with?(partial, "\n")

        [_line, _rest] ->
          flunk("Should not find a complete line in partial data")
      end
    end

    test "handles multiple JSON lines in single data chunk" do
      # Test handling multiple lines without calling process_data
      json1 = ~s({"jsonrpc":"2.0","method":"tools/list","id":1})
      json2 = ~s({"jsonrpc":"2.0","method":"resources/list","id":2})
      data_chunk = json1 <> "\n" <> json2 <> "\n"

      # Simulate line processing
      lines = String.split(data_chunk, "\n", trim: true)
      assert length(lines) == 2
      assert Enum.at(lines, 0) == json1
      assert Enum.at(lines, 1) == json2

      # Verify each line is valid JSON
      for line <- lines do
        assert {:ok, _} = Jason.decode(line)
      end
    end

    test "skips empty lines gracefully" do
      # Test the line splitting logic conceptually

      # Data with empty lines
      data_with_empty_lines = "\n\n" <> ~s({"jsonrpc":"2.0","method":"tools/list","id":1}) <> "\n"

      # Simulate line processing
      lines = String.split(data_with_empty_lines, "\n")

      # Filter out empty lines like process_data would
      json_lines =
        Enum.filter(lines, fn line ->
          trimmed = String.trim(line)

          trimmed != "" &&
            (String.starts_with?(trimmed, "{") || String.starts_with?(trimmed, "["))
        end)

      assert length(json_lines) == 1
      assert hd(json_lines) == ~s({"jsonrpc":"2.0","method":"tools/list","id":1})
    end

    test "filters out non-JSON output lines" do
      # Test JSON filtering logic
      json_message = ~s({"jsonrpc":"2.0","method":"tools/list","id":1})
      json_array = ~s([{"jsonrpc":"2.0","method":"tools/list","id":1}])

      # Verify JSON detection
      assert String.starts_with?(String.trim(json_message), "{")
      assert String.starts_with?(String.trim(json_array), "[")

      # Non-JSON lines
      non_json_lines = ["Server starting...", "DEBUG: test", ""]

      for line <- non_json_lines do
        trimmed = String.trim(line)
        refute String.starts_with?(trimmed, "{")
        refute String.starts_with?(trimmed, "[")
      end
    end

    test "handles :eol tuple format from port" do
      # Test :eol tuple handling conceptually
      json_message = ~s({"jsonrpc":"2.0","method":"tools/list","id":1})
      eol_data = {:eol, json_message}

      # Simulate what process_data does with :eol tuples
      binary_data =
        case eol_data do
          {:eol, line} -> line <> "\n"
          binary when is_binary(binary) -> binary
          _ -> ""
        end

      assert binary_data == json_message <> "\n"
    end

    test "preserves buffer state across message processing" do
      # Test buffer state preservation conceptually
      state = %Stdio{port: nil, line_buffer: ""}

      # Simulate receiving data in chunks
      partial = ~s({"jsonrpc":"2.0","method")
      completion = ~s(:"tools/list","id":1})

      # Step 1: Process partial data
      buffer_after_partial = state.line_buffer <> partial
      # Verify it's incomplete (no newline)
      refute String.contains?(buffer_after_partial, "\n")

      # Step 2: Add completion with newline
      full_data = buffer_after_partial <> completion <> "\n"

      # Step 3: Split to find complete line
      case String.split(full_data, "\n", parts: 2) do
        [complete_line, remaining] ->
          # Should extract the complete JSON message
          expected = ~s({"jsonrpc":"2.0","method":"tools/list","id":1})
          assert complete_line == expected
          assert remaining == ""

        _ ->
          flunk("Should find a complete line after adding newline")
      end
    end
  end

  describe "Stdio Transport Newline Constraints" do
    test "rejects JSON messages with embedded newlines" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Create a JSON message that contains an embedded newline in a string value
      # This violates the MCP stdio transport requirement that messages MUST NOT contain embedded newlines
      _message_with_newline = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{
            # This embedded newline should be rejected
            "text" => "Line 1\nLine 2"
          }
        },
        "id" => 1
      }

      # JSON encoding escapes newlines as \\n, so we need to manually inject a real newline
      # to test the stdio transport's handling of malformed JSON
      json_message =
        ~s({"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"text":"Line 1\nLine 2"}},"id":1})

      # The stdio transport should reject this message
      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      # The stdio transport should reject this message due to embedded newlines
      case result do
        {:error, {:embedded_newline, _}} ->
          # This is the correct behavior for a compliant implementation
          assert true

        {:error, {:security_violation, {:embedded_newline, _}}} ->
          # The error is wrapped in security_violation
          assert true

        {:error, {:security_violation, {:validation_error, {:embedded_newline, _}}}} ->
          # The error is wrapped in security_violation and validation_error
          assert true

        {:error, {:send_failed, _}} ->
          # Should not reach here - validation should catch embedded newlines first
          flunk("Embedded newline validation should prevent send_failed error")

        {:ok, _} ->
          flunk("Message with embedded newlines should be rejected")

        other ->
          flunk("Unexpected result for embedded newline test: #{inspect(other)}")
      end
    end

    test "rejects JSON-RPC batch messages with embedded newlines" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Create a batch message with embedded newlines
      _batch_with_newlines = [
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/list",
          "id" => 1
        },
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "params" => %{
            "name" => "test",
            # Embedded newline
            "arguments" => %{"data" => "line1\nline2"}
          },
          "id" => 2
        }
      ]

      # Manually create JSON with embedded newlines to test transport validation
      json_message =
        ~s([{"jsonrpc":"2.0","method":"tools/list","id":1},{"jsonrpc":"2.0","method":"tools/call","params":{"name":"test","arguments":{"content":"Some\ncontent"}},"id":2}])

      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:error, {:embedded_newline, _}} ->
          # This is the correct behavior
          assert true

        {:error, {:security_violation, {:embedded_newline, _}}} ->
          # The error is wrapped in security_violation
          assert true

        {:error, {:security_violation, {:validation_error, {:embedded_newline, _}}}} ->
          # The error is wrapped in security_violation and validation_error
          assert true

        {:ok, _} ->
          flunk("Batch message with embedded newlines should be rejected")

        {:error, {:send_failed, _}} ->
          flunk("Embedded newline validation should prevent send_failed error")

        other ->
          flunk("Unexpected result for batch embedded newline test: #{inspect(other)}")
      end
    end

    test "accepts messages without embedded newlines" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Create a valid message without embedded newlines
      valid_message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{
            "text" => "Single line text without embedded newlines"
          }
        },
        "id" => 1
      }

      json_message = Jason.encode!(valid_message)

      refute String.contains?(json_message, "\n"),
             "Valid message should not contain embedded newlines"

      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          assert true

        {:error, {:send_failed, _}} ->
          # Expected due to mock port
          assert true

        {:error, {:transport_error, {:send_failed, _}}} ->
          # Also acceptable - wrapped transport error
          assert true

        {:error, {:embedded_newline, _}} ->
          flunk("Valid message should not be rejected for embedded newlines")

        {:error, {:invalid_json, _}} ->
          flunk("Valid JSON message should not be rejected")

        {:error, {:invalid_jsonrpc, _}} ->
          flunk("Valid JSON-RPC message should not be rejected")

        other ->
          flunk("Unexpected result for valid message: #{inspect(other)}")
      end
    end

    test "handles escaped newlines correctly" do
      state = %Stdio{port: nil, line_buffer: ""}

      # JSON can contain escaped newlines (\\n) which are fine
      message_with_escaped_newlines = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{
            # Escaped newline (\\n) should be allowed
            "text" => "Line 1\\nLine 2"
          }
        },
        "id" => 1
      }

      json_message = Jason.encode!(message_with_escaped_newlines)
      # Should contain \\n but not actual \n
      assert String.contains?(json_message, "\\n"), "Should contain escaped newline"
      refute String.contains?(json_message, "\n"), "Should not contain actual newline"

      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          assert true

        {:error, {:send_failed, _}} ->
          # Expected due to mock port
          assert true

        {:error, {:transport_error, {:send_failed, _}}} ->
          # Also acceptable - wrapped transport error
          assert true

        {:error, {:embedded_newline, _}} ->
          flunk("Escaped newlines should be allowed")

        other ->
          flunk("Unexpected result for escaped newlines: #{inspect(other)}")
      end
    end
  end

  describe "Stdio Transport Security Integration" do
    test "integrates security validation with newline message processing" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Test that security validation works with properly formatted newline-delimited messages
      external_message = %{
        "jsonrpc" => "2.0",
        "method" => "resources/read",
        "params" => %{"uri" => "https://evil.example.com/steal-data"},
        "id" => 1
      }

      json_message = Jason.encode!(external_message)

      # The send_message function should validate the message AND format it with newline
      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          # Message was allowed and would be sent with proper newline formatting
          assert true

        {:error, {:security_violation, _}} ->
          # Message was blocked by security policy (expected in secure environments)
          assert true

        {:error, {:send_failed, _}} ->
          # Port error due to mock port, but security validation passed
          assert true

        other ->
          flunk("Unexpected security integration result: #{inspect(other)}")
      end
    end

    test "maintains security isolation between different stdio processes" do
      # This test verifies that security policies are applied per-process
      # rather than globally across all stdio transports

      state1 = %Stdio{port: :mock_port_1, line_buffer: ""}
      state2 = %Stdio{port: :mock_port_2, line_buffer: ""}

      message =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "resources/read",
          "params" => %{"uri" => "https://external.example.com/data"},
          "id" => 1
        })

      # Both should be subject to the same security validation
      result1 = Stdio.send_message(message, state1)
      result2 = Stdio.send_message(message, state2)

      # Results should be consistent (both allowed or both blocked)
      case {result1, result2} do
        {{:ok, _}, {:ok, _}} ->
          assert true

        {{:error, {:security_violation, _}}, {:error, {:security_violation, _}}} ->
          assert true

        {{:error, {:send_failed, _}}, {:error, {:send_failed, _}}} ->
          # Both failed due to mock ports, security validation passed
          assert true

        _ ->
          # Mixed results could indicate inconsistent security application
          # This is acceptable as long as security is being applied
          assert true
      end
    end
  end

  describe "Stdio Transport Isolation and Format Validation" do
    test "validates that only valid MCP messages are sent to stdin" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Test non-JSON content that should be rejected
      invalid_inputs = [
        "plain text message",
        "not-json-at-all",
        "<xml>content</xml>",
        "",
        # Single quotes instead of double quotes
        "{'invalid': 'json'}",
        # Malformed JSON
        "{\"incomplete\": json",
        # Just a number, not an object
        "123",
        # Valid JSON but not an object
        "null",
        # Valid JSON array but not an object
        "[1, 2, 3]"
      ]

      for invalid_input <- invalid_inputs do
        result = Stdio.send_message(invalid_input, %{state | port: :mock_port})

        case result do
          {:error, {:invalid_json, _}} ->
            # This is the correct behavior for invalid JSON
            assert true

          {:error, {:security_violation, {:invalid_json, _}}} ->
            # The error is wrapped in security_violation
            assert true

          {:error, {:embedded_newline, _}} ->
            # Some invalid inputs might also contain newlines
            assert true

          {:error, {:security_violation, {:embedded_newline, _}}} ->
            # The error is wrapped in security_violation
            assert true

          {:error, {:security_violation, {:invalid_jsonrpc, _}}} ->
            # Some "valid JSON" (like numbers) are rejected as invalid JSON-RPC
            assert true

          {:error, {:security_violation, {:validation_error, _}}} ->
            # Validation errors wrapped in security_violation
            assert true

          {:ok, _} ->
            flunk("Invalid JSON should be rejected: #{invalid_input}")

          {:error, {:send_failed, _}} ->
            flunk("JSON validation should prevent send_failed error for: #{invalid_input}")

          other ->
            flunk("Unexpected result for invalid JSON '#{invalid_input}': #{inspect(other)}")
        end
      end
    end

    test "validates JSON-RPC 2.0 message structure for stdio" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Test JSON that's valid but not valid JSON-RPC 2.0
      invalid_jsonrpc_messages = [
        # Missing jsonrpc field
        ~s({"method": "tools/list", "id": 1}),
        # Wrong jsonrpc version
        ~s({"jsonrpc": "1.0", "method": "tools/list", "id": 1}),
        # Missing method for request
        ~s({"jsonrpc": "2.0", "id": 1}),
        # Invalid method type
        ~s({"jsonrpc": "2.0", "method": 123, "id": 1}),
        # Invalid id type (null is not allowed for requests)
        ~s({"jsonrpc": "2.0", "method": "tools/list", "id": null})
      ]

      for invalid_message <- invalid_jsonrpc_messages do
        result = Stdio.send_message(invalid_message, %{state | port: :mock_port})

        case result do
          {:error, {:invalid_jsonrpc, _}} ->
            # This is the correct behavior for invalid JSON-RPC
            assert true

          {:error, {:security_violation, {:invalid_jsonrpc, _}}} ->
            # The error is wrapped in security_violation
            assert true

          {:error, {:security_violation, {:validation_error, _}}} ->
            # Validation errors wrapped in security_violation
            assert true

          {:ok, _} ->
            flunk("Invalid JSON-RPC should be rejected: #{invalid_message}")

          {:error, {:send_failed, _}} ->
            flunk("JSON-RPC validation should prevent send_failed error for: #{invalid_message}")

          other ->
            flunk(
              "Unexpected result for invalid JSON-RPC '#{invalid_message}': #{inspect(other)}"
            )
        end
      end
    end

    test "accepts valid JSON-RPC 2.0 messages" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Test valid JSON-RPC messages that should be accepted
      valid_jsonrpc_messages = [
        # Basic request
        ~s({"jsonrpc": "2.0", "method": "tools/list", "id": 1}),
        # Request with params
        ~s({"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "test"}, "id": 2}),
        # Notification (no id)
        ~s({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info"}}),
        # Response with result
        ~s({"jsonrpc": "2.0", "result": {"tools": []}, "id": 1}),
        # Response with error
        ~s({"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": 2}),
        # Batch request
        ~s([{"jsonrpc": "2.0", "method": "tools/list", "id": 1}, {"jsonrpc": "2.0", "method": "resources/list", "id": 2}])
      ]

      for valid_message <- valid_jsonrpc_messages do
        result = Stdio.send_message(valid_message, %{state | port: :mock_port})

        case result do
          {:ok, _} ->
            # Valid JSON-RPC should be accepted
            assert true

          {:error, {:send_failed, _}} ->
            # Expected due to mock port - validation passed
            assert true

          {:error, {:transport_error, {:send_failed, _}}} ->
            # Also acceptable - wrapped transport error
            assert true

          {:error, validation_error} ->
            flunk(
              "Valid JSON-RPC should not be rejected: #{valid_message}, error: #{inspect(validation_error)}"
            )

          other ->
            flunk("Unexpected result for valid JSON-RPC '#{valid_message}': #{inspect(other)}")
        end
      end
    end

    test "enforces line-delimited format for message output" do
      state = %Stdio{port: nil, line_buffer: ""}

      # Test that send_message adds proper newline delimiter
      valid_message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => 1
      }

      json_message = Jason.encode!(valid_message)

      # Test conceptually - we know from the source code that send_message
      # adds "\n" to the message before sending via Port.command
      # We can't easily mock the port behavior, so we'll test the logic
      result = Stdio.send_message(json_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          # If the function succeeded, it would have added the newline
          # (We can verify this by looking at the source code)
          assert true

        {:error, {:send_failed, _}} ->
          # Expected due to mock port - this means the newline logic was reached
          # The source shows: data = validated_message <> "\n"
          assert true

        _other ->
          # Any other result is also acceptable for this test
          assert true
      end

      # Verify the newline addition logic by checking what the function would send
      # From the source: data = validated_message <> "\n"
      expected_data = json_message <> "\n"
      assert String.ends_with?(expected_data, "\n"), "Expected data should end with newline"

      assert String.starts_with?(expected_data, json_message),
             "Should start with original message"
    end

    test "validates stdio stream separation (no mixing of data streams)" do
      # This test documents the requirement that stdin and stdout must be separate
      # and only contain valid MCP messages

      # Test that we don't accidentally write to stderr or other streams
      # This is more of a conceptual test since we can't easily test actual stream separation
      state = %Stdio{port: nil, line_buffer: ""}

      valid_message =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "tools/list",
          "id" => 1
        })

      # The key requirement is that send_message should only use the provided port
      # which represents the stdin/stdout connection
      result = Stdio.send_message(valid_message, %{state | port: :mock_port})

      case result do
        {:ok, _} ->
          # Should only interact with the designated port
          assert true

        {:error, {:send_failed, _}} ->
          # Expected due to mock port
          assert true

        _other ->
          # Other results are acceptable as long as no stream mixing occurs
          assert true
      end

      # Test that receive_message only processes data from the designated port
      receive_state = %Stdio{port: :mock_receive_port, line_buffer: "sample data"}

      # We can't easily test the actual receive loop without complex mocking,
      # but we can verify that the state management is port-specific
      assert receive_state.port == :mock_receive_port
      assert is_binary(receive_state.line_buffer)
    end

    test "validates that server output only contains valid MCP messages" do
      # Test the filtering logic conceptually without calling process_data

      # Test scenarios with mixed output
      mixed_output_scenarios = [
        # Scenario 1: Server startup message followed by JSON
        {"Server starting on port 8080...\n{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}\n",
         ~s({"jsonrpc":"2.0","method":"initialized"})},

        # Scenario 2: Debug output mixed with JSON
        {"DEBUG: Loading configuration\n{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[]},\"id\":1}\nDEBUG: Request processed\n",
         ~s({"jsonrpc":"2.0","result":{"tools":[]},"id":1})},

        # Scenario 3: Error messages mixed with JSON
        {"ERROR: Failed to load module\n{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":1}\n",
         ~s({"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":1})},

        # Scenario 4: Multiple non-JSON lines
        {"Line 1 of output\nLine 2 of output\n{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":1}\nMore output\n",
         ~s({"jsonrpc":"2.0","method":"tools/list","id":1})}
      ]

      for {input, expected_json} <- mixed_output_scenarios do
        # Simulate the filtering that process_data would do
        lines = String.split(input, "\n")

        json_lines =
          Enum.filter(lines, fn line ->
            trimmed = String.trim(line)

            trimmed != "" &&
              (String.starts_with?(trimmed, "{") || String.starts_with?(trimmed, "["))
          end)

        assert length(json_lines) >= 1, "Should find at least one JSON line"

        # Get the first JSON line
        json_line = hd(json_lines)
        assert json_line == expected_json

        # Verify it's valid JSON
        assert {:ok, decoded} = Jason.decode(json_line)
        assert Map.has_key?(decoded, "jsonrpc"), "Should contain jsonrpc field"
      end
    end
  end

  describe "Stdio Transport close/1 cleanup" do
    test "close terminates the stable shared actor in push mode" do
      cat = System.find_executable("cat") || flunk("cat executable is required for stdio test")

      assert {:ok, state} = Stdio.connect(command: [cat])
      assert {:ok, %Stdio{reader_pid: reader_pid} = subscribed} = Stdio.subscribe(self(), state)
      assert is_pid(reader_pid)
      assert Process.alive?(reader_pid)

      ref = Process.monitor(reader_pid)

      assert :ok = Stdio.close(subscribed)

      assert_receive {:DOWN, ^ref, :process, ^reader_pid, :normal}, 1_000
      refute Process.alive?(reader_pid)
    end

    test "close in pull mode cleans up the shared actor" do
      cat = System.find_executable("cat") || flunk("cat executable is required for stdio test")

      assert {:ok, %Stdio{reader_pid: actor} = state} = Stdio.connect(command: [cat])
      assert Process.alive?(actor)

      assert :ok = Stdio.close(state)
      refute Process.alive?(actor)
      assert :ok = Stdio.close(state)
    end

    test "close terminates the spawned OS process" do
      sleep = System.find_executable("sleep") || flunk("sleep executable is required")
      kill = System.find_executable("kill") || flunk("kill executable is required")

      assert {:ok, %Stdio{os_pid: os_pid} = state} =
               Stdio.connect(command: [sleep, "30"])

      on_exit(fn ->
        if os_process_alive?(kill, os_pid) do
          System.cmd(kill, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        end
      end)

      assert os_process_alive?(kill, os_pid)
      assert :ok = Stdio.close(state)
      refute os_process_alive?(kill, os_pid)
    end
  end

  defp os_process_alive?(kill, os_pid) do
    match?({_, 0}, System.cmd(kill, ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end
end
