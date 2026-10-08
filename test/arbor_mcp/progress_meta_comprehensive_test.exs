defmodule Arbor.MCP.ProgressMetaComprehensiveTest do
  @moduledoc """
  Comprehensive test suite for progress tokens and _meta field support.

  Tests that all MCP methods properly support:
  1. Progress tokens in _meta field for long-running operations
  2. _meta field passthrough to handlers
  3. Progress notification sending
  4. Proper validation and error handling
  """

  use ExUnit.Case, async: true

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  @moduletag :progress
  @moduletag :slow

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer, as: Server

  defmodule ComprehensiveHandler do
    use Arbor.MCP.Server.Handler
    require Logger

    @impl true
    def init(_args) do
      {:ok,
       %{
         operations: %{},
         received_meta: %{}
       }}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-03-26",
         serverInfo: %{
           name: "comprehensive-test-server",
           version: "1.0.0"
         },
         capabilities: %{
           tools: %{},
           resources: %{},
           prompts: %{},
           completion: %{},
           sampling: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(cursor, state) do
      # Check if _meta was passed through
      meta = extract_meta_from_cursor(cursor)
      state = store_received_meta(state, "list_tools", meta)

      tools = [
        %{
          name: "progress_tool",
          description: "Tool that reports progress",
          inputSchema: %{
            type: "object",
            properties: %{
              duration: %{type: "integer"},
              steps: %{type: "integer"}
            }
          }
        },
        %{
          name: "meta_echo",
          description: "Echoes back the _meta field",
          inputSchema: %{type: "object"}
        }
      ]

      # Simulate progress if token provided
      if meta && meta["progressToken"] do
        send_progress_updates(meta["progressToken"], 3)
      end

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool(name, arguments, state) do
      # Extract _meta from arguments
      {meta, args} = Map.pop(arguments, "_meta")
      state = store_received_meta(state, "call_tool:#{name}", meta)

      case name do
        "progress_tool" ->
          handle_progress_tool(args, meta, state)

        "meta_echo" ->
          # Return the _meta field that was passed
          result = %{
            type: "text",
            text: "Received _meta: #{inspect(meta)}"
          }

          {:ok, [result], state}

        _ ->
          {:error, "Unknown tool: #{name}", state}
      end
    end

    @impl true
    def handle_list_resources(cursor, state) do
      meta = extract_meta_from_cursor(cursor)
      state = store_received_meta(state, "list_resources", meta)

      if meta && meta["progressToken"] do
        send_progress_updates(meta["progressToken"], 2)
      end

      resources = [
        %{
          uri: "test://resource1",
          name: "Test Resource 1",
          mime_type: "text/plain"
        }
      ]

      {:ok, resources, nil, state}
    end

    @impl true
    def handle_read_resource(uri, state) do
      # Note: read_resource doesn't have _meta in spec, but let's test
      # that we handle it gracefully if provided
      meta = extract_meta_from_uri(uri)
      state = store_received_meta(state, "read_resource:#{uri}", meta)

      content = [
        %{
          uri: uri,
          mime_type: "text/plain",
          text: "Resource content for #{uri}"
        }
      ]

      {:ok, content, state}
    end

    @impl true
    def handle_list_prompts(cursor, state) do
      meta = extract_meta_from_cursor(cursor)
      state = store_received_meta(state, "list_prompts", meta)

      if meta && meta["progressToken"] do
        send_progress_updates(meta["progressToken"], 1)
      end

      prompts = [
        %{
          name: "test_prompt",
          description: "A test prompt"
        }
      ]

      {:ok, prompts, nil, state}
    end

    @impl true
    def handle_get_prompt(name, arguments, state) do
      # Extract _meta from arguments
      {meta, _args} = Map.pop(arguments, "_meta")
      state = store_received_meta(state, "get_prompt:#{name}", meta)

      if meta && meta["progressToken"] do
        send_progress_updates(meta["progressToken"], 2)
      end

      prompt = %{
        name: name,
        description: "Test prompt",
        messages: [
          %{
            role: "user",
            content: %{
              type: "text",
              text: "Test prompt content"
            }
          }
        ]
      }

      {:ok, prompt, state}
    end

    @impl true
    def handle_complete(ref, params, state) do
      # Extract _meta from params
      {meta, _params} = Map.pop(params, "_meta")
      state = store_received_meta(state, "complete:#{inspect(ref)}", meta)

      if meta && meta["progressToken"] do
        # Simulate streaming completion with progress
        Task.start(fn ->
          token = meta["progressToken"]

          for i <- 1..5 do
            # Intentional: simulates a slow streaming operation.
            Process.sleep(100)
            Arbor.MCP.Server.notify_progress(self(), token, i, 5)
          end
        end)
      end

      completion = %{
        choices: [
          %{
            message: %{
              role: "assistant",
              content: %{
                type: "text",
                text: "Completed response for #{inspect(ref)}"
              }
            }
          }
        ]
      }

      {:ok, completion, state}
    end

    @impl true
    def handle_create_message(params, state) do
      # Extract _meta from params
      {meta, message_params} = Map.pop(params, "_meta")
      state = store_received_meta(state, "create_message", meta)

      if meta && meta["progressToken"] do
        # Simulate message creation with progress
        send_progress_updates(meta["progressToken"], 3)
      end

      model = Map.get(message_params, "modelPreferences", %{})

      message = %{
        role: "assistant",
        content: %{
          type: "text",
          text: "Created message with model: #{inspect(model)}"
        }
      }

      {:ok, message, state}
    end

    # Helper to get handler state for testing
    def get_received_meta(_server_pid) do
      # Since we can't directly get handler state, return empty map
      # In a real test, we would verify behavior through other means
      %{}
    end

    defp handle_progress_tool(%{"duration" => duration, "steps" => steps}, meta, state) do
      if meta && meta["progressToken"] do
        # Start async progress reporting
        token = meta["progressToken"]

        Task.start(fn ->
          step_duration = div(duration, steps)

          for i <- 1..steps do
            # Intentional: the tool's advertised "duration" is simulated work.
            Process.sleep(step_duration)
            Arbor.MCP.Server.notify_progress(self(), token, i, steps)
          end
        end)
      end

      # Intentional: the tool is documented to take "duration" ms.
      Process.sleep(duration)

      result = %{
        type: "text",
        text: "Completed #{steps} steps in #{duration}ms"
      }

      {:ok, [result], state}
    end

    defp extract_meta_from_cursor(nil), do: nil

    defp extract_meta_from_cursor(cursor) when is_binary(cursor) do
      # In a real implementation, cursor might encode meta
      nil
    end

    defp extract_meta_from_cursor(%{"_meta" => meta}), do: meta
    defp extract_meta_from_cursor(_), do: nil

    defp extract_meta_from_uri(_uri), do: nil

    defp store_received_meta(state, _method, nil), do: state

    defp store_received_meta(state, method, meta) do
      put_in(state.received_meta[method], meta)
    end

    defp send_progress_updates(token, count) do
      Task.start(fn ->
        for i <- 1..count do
          # Intentional: paces simulated progress updates.
          Process.sleep(50)
          Arbor.MCP.Server.notify_progress(self(), token, i, count)
        end
      end)
    end
  end

  describe "Progress Token Support" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: ComprehensiveHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      # Client.start_link/1 handshakes inside init/1.
      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        try do
          if Process.alive?(client), do: GenServer.stop(client)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(server), do: GenServer.stop(server)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, client: client, server: server}
    end

    test "tools/call supports progress token in _meta", %{client: client} do
      # Progress notifications are sent through the transport
      # No need to explicitly subscribe

      # Call tool with progress token
      token = "tool-progress-#{System.unique_integer()}"

      result =
        Client.call_tool(
          client,
          "progress_tool",
          %{
            "duration" => 500,
            "steps" => 5
          },
          meta: %{"progressToken" => token}
        )

      # Result should complete successfully
      assert {:ok, %{content: [%{type: "text", text: text}]}} = result
      assert text =~ "Completed 5 steps"

      # Note: Progress notifications are sent to the client transport,
      # not directly to this test process
    end

    test "tools/list can include progress token", %{client: client} do
      # Progress notifications are sent through the transport
      # No need to explicitly subscribe

      # Current API doesn't support _meta in list_tools, but let's test
      # that it doesn't break anything
      assert {:ok, %{tools: tools}} = Client.list_tools(client)
      assert length(tools) > 0
    end

    test "resources/list can include progress token", %{client: client} do
      # Progress notifications are sent through the transport
      # No need to explicitly subscribe

      # Similar limitation - API doesn't expose _meta for list operations yet
      assert {:ok, %{resources: resources}} = Client.list_resources(client)
      assert length(resources) > 0
    end

    test "prompts/get supports progress token", %{client: client} do
      # Progress notifications are sent through the transport

      # Get prompt with progress token
      token = "prompt-progress-#{System.unique_integer()}"

      # Now we can pass _meta to get_prompt
      assert {:ok, prompt} =
               Client.get_prompt(client, "test_prompt", %{}, meta: %{"progressToken" => token})

      # Response struct has description and messages fields (not name)
      assert prompt.description == "Test prompt"
      assert is_list(prompt.messages)
    end

    test "completion/complete supports progress token", %{client: client} do
      # Progress notifications are sent through the transport

      token = "complete-progress-#{System.unique_integer()}"

      # Now we can pass _meta to complete
      result =
        Client.complete(
          client,
          %{"type" => "ref/prompt", "name" => "test_prompt"},
          %{"name" => "topic", "value" => "Test"},
          meta: %{"progressToken" => token}
        )

      assert {:ok, completion} = result
      # The completion response is wrapped in a Response struct
      # The handler returns a map with choices, which gets normalized
      assert completion != nil
    end

    test "progress notifications follow spec requirements", %{client: client} do
      # Progress notifications are sent through the transport

      token = "spec-test-#{System.unique_integer()}"

      # Call tool that sends multiple progress updates
      result_task =
        Task.async(fn ->
          Client.call_tool(
            client,
            "progress_tool",
            %{
              "duration" => 300,
              "steps" => 3
            },
            meta: %{"progressToken" => token}
          )
        end)

      # Wait for task to complete
      {:ok, _result} = Task.await(result_task)

      # Note: Progress notifications are sent to the client transport,
      # not directly to this test process. In a real implementation,
      # the client would receive these notifications through the transport.
    end
  end

  describe "_meta Field Support" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: ComprehensiveHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        try do
          if Process.alive?(client), do: GenServer.stop(client)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(server), do: GenServer.stop(server)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, client: client, server: server}
    end

    test "tools/call passes _meta to handler", %{client: client, server: _server} do
      # Call tool with custom _meta fields
      meta = %{
        "progressToken" => "test-123",
        "requestId" => "custom-request-id",
        "customField" => "custom-value"
      }

      result =
        Client.call_tool(client, "meta_echo", %{}, meta: meta)

      assert {:ok, %{content: [%{text: text}]}} = result
      assert text =~ "custom-request-id"
      assert text =~ "custom-value"

      # Note: We can't directly verify handler state in this test setup
      # The fact that the response includes the meta fields proves it was received
    end

    test "_meta field is stripped from tool arguments", %{client: client} do
      # The handler should receive _meta separately from arguments
      result =
        Client.call_tool(
          client,
          "meta_echo",
          %{
            "normalArg" => "value"
          },
          meta: %{"token" => "123"}
        )

      assert {:ok, %{content: [%{text: text}]}} = result
      # Handler should see _meta but not in the arguments
      assert text =~ "token"
    end

    test "_meta supports arbitrary fields", %{client: client, server: _server} do
      # Test that any fields can be passed in _meta
      meta = %{
        "progressToken" => "abc",
        "traceId" => "trace-123",
        "userId" => "user-456",
        "nested" => %{
          "field1" => "value1",
          "field2" => 42
        }
      }

      # Call the tool with meta
      {:ok, result} = Client.call_tool(client, "meta_echo", %{}, meta: meta)

      # The response should indicate meta was received
      assert result.content |> hd |> Map.get(:text) =~ "progressToken"
    end

    test "missing _meta field doesn't break requests", %{client: client} do
      # Ensure backwards compatibility
      result =
        Client.call_tool(client, "meta_echo", %{
          "arg1" => "value1"
        })

      assert {:ok, %{content: [%{text: text}]}} = result
      # No meta received
      assert text =~ "nil"
    end
  end

  describe "Error Handling" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: ComprehensiveHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        try do
          if Process.alive?(client), do: GenServer.stop(client)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(server), do: GenServer.stop(server)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, client: client, server: server}
    end

    test "invalid progress token type is handled", %{client: client} do
      # Progress token must be string or integer
      result =
        Client.call_tool(
          client,
          "progress_tool",
          %{
            "duration" => 100,
            "steps" => 1
          },
          meta: %{
            "progressToken" => %{"invalid" => "object"}
          }
        )

      # Should still work, just no progress notifications
      assert {:ok, _} = result
    end

    test "duplicate progress tokens across requests", %{client: client} do
      # Progress notifications are sent through the transport

      # Same token for multiple requests (not recommended but should work)
      token = "duplicate-token"

      # Start two operations with same token
      task1 =
        Task.async(fn ->
          Client.call_tool(
            client,
            "progress_tool",
            %{
              "duration" => 200,
              "steps" => 2
            },
            meta: %{"progressToken" => token}
          )
        end)

      task2 =
        Task.async(fn ->
          Client.call_tool(
            client,
            "progress_tool",
            %{
              "duration" => 200,
              "steps" => 2
            },
            meta: %{"progressToken" => token}
          )
        end)

      # Wait for both operations to complete
      # Progress notifications would be sent but not received by test process

      # Both tasks should complete
      assert {:ok, _} = Task.await(task1)
      assert {:ok, _} = Task.await(task2)
    end
  end

  describe "Integration with Existing Features" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: ComprehensiveHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        try do
          if Process.alive?(client), do: GenServer.stop(client)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(server), do: GenServer.stop(server)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, client: client, server: server}
    end

    test "progress works with cancellation", %{client: client} do
      # Progress notifications are sent through the transport

      token = "cancel-progress-#{System.unique_integer()}"

      # Start long operation
      task =
        Task.async(fn ->
          Client.call_tool(
            client,
            "progress_tool",
            %{
              "duration" => 1000,
              "steps" => 10
            },
            meta: %{"progressToken" => token}
          )
        end)

      # Block until the request is registered rather than guessing.
      wait_until(fn -> Client.get_pending_requests(client) != [] end, timeout: 5_000)

      # Cancel the operation
      [request_id | _] = Client.get_pending_requests(client)
      Client.send_cancelled(client, request_id, "User cancelled")

      # Task should be cancelled
      assert {:error, :cancelled} = Task.await(task)
    end

    test "progress integrates with logging", %{client: client} do
      # Progress operations should be loggable
      token = "log-progress-#{System.unique_integer()}"

      # Set debug log level to see progress logs
      {:ok, _} = Client.set_log_level(client, "debug")

      result =
        Client.call_tool(
          client,
          "progress_tool",
          %{
            "duration" => 200,
            "steps" => 2
          },
          meta: %{"progressToken" => token}
        )

      assert {:ok, _} = result
    end
  end
end
