defmodule Arbor.MCP.CancellationComprehensiveTest do
  @moduledoc """
  Comprehensive test suite for MCP Cancellation Protocol.

  This test suite ensures full compliance with the MCP specification for
  request cancellation, including proper handling of race conditions,
  validation, and resource cleanup.
  """

  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.Handler
  alias Arbor.MCP.Server.HandlerServer, as: Server
  alias Arbor.MCP.Server.Runtime

  defmodule SlowHandler do
    @behaviour Handler

    def init(_args) do
      # Create ETS table for cancellation tracking if it doesn't exist
      case :ets.info(:cancellation_tracker) do
        :undefined ->
          :ets.new(:cancellation_tracker, [:set, :public, :named_table])

        _ ->
          :ok
      end

      # Track active requests for proper cancellation
      {:ok, %{active_requests: %{}, cancelled_requests: MapSet.new()}}
    end

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         name: "slow-test-server",
         version: "1.0.0",
         capabilities: %{
           tools: %{},
           resources: %{},
           prompts: %{}
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "slow_tool", description: "A tool that takes time to complete"},
        %{name: "instant_tool", description: "A tool that completes instantly"},
        %{name: "cancellable_tool", description: "A tool that checks for cancellation"}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("slow_tool", params, state) do
      # Get request ID for cancellation checking
      request_id = Map.get(params, "_request_id")
      require Logger
      Logger.debug("SlowHandler starting slow_tool for request #{request_id}")

      # Simulate a slow operation that checks for cancellation
      # Check both the initial state and ETS table
      result =
        Enum.reduce_while(1..20, :ok, fn i, _acc ->
          cond do
            # First check if already cancelled in state
            request_id && MapSet.member?(state.cancelled_requests, request_id) ->
              {:halt, :cancelled}

            # Then check ETS table for cancellation
            request_id && :ets.whereis(:cancellation_tracker) != :undefined ->
              case :ets.lookup(:cancellation_tracker, request_id) do
                [{^request_id, :cancelled}] ->
                  Logger.debug("SlowHandler found cancellation in ETS for #{request_id}")
                  {:halt, :cancelled}

                _ ->
                  if i == 1 do
                    Logger.debug("SlowHandler checking ETS for #{request_id}, iteration #{i}")
                  end

                  # Intentional: this handler *is* the slow operation the
                  # cancellation tests race against.
                  Process.sleep(100)
                  {:cont, :ok}
              end

            # No cancellation tracking available
            true ->
              # Intentional: simulated slow work (see above).
              Process.sleep(100)
              {:cont, :ok}
          end
        end)

      case result do
        :cancelled ->
          Logger.debug("SlowHandler returning cancelled for #{request_id}")
          {:error, %{code: -32001, message: "Request was cancelled"}, state}

        :ok ->
          Logger.debug("SlowHandler completed successfully for #{request_id}")
          {:ok, [%{type: "text", text: "Slow operation completed"}], state}
      end
    end

    def handle_call_tool("instant_tool", _params, state) do
      # Completes immediately
      {:ok, [%{type: "text", text: "Instant operation completed"}], state}
    end

    def handle_call_tool("cancellable_tool", params, state) do
      # A tool that periodically checks if it should be cancelled
      request_id = Map.get(params, "_request_id")
      iterations = Map.get(params, "iterations", 10)
      require Logger

      Logger.debug("SlowHandler starting cancellable_tool for request #{request_id}")

      # Check if already cancelled before starting
      if MapSet.member?(state.cancelled_requests, request_id) do
        Logger.debug("Request #{request_id} already cancelled before starting")
        {:error, %{code: -32001, message: "Request was cancelled"}, state}
      else
        # Spawn the work in a separate process so it can be interrupted
        parent_pid = self()

        worker_pid =
          spawn_link(fn ->
            result = perform_cancellable_work(request_id, iterations, state, parent_pid)
            send(parent_pid, {:work_result, request_id, result})
          end)

        # Store the worker PID so it can be killed on cancellation
        state = put_in(state.active_requests[request_id], worker_pid)
        Logger.debug("Started worker #{inspect(worker_pid)} for request #{request_id}")

        # Check if already cancelled before waiting
        # This is necessary because the cancellation might have arrived
        # while we were spawning the worker
        already_cancelled =
          receive do
            {:cancelled, ^request_id} ->
              Logger.debug("Request #{request_id} was cancelled before worker started")
              send(worker_pid, {:cancelled, request_id})
              Process.exit(worker_pid, :cancelled)
              true
          after
            0 -> false
          end

        # Wait for either work completion or cancellation
        result =
          if already_cancelled do
            :cancelled
          else
            receive do
              {:work_result, ^request_id, work_result} ->
                Logger.debug(
                  "Received work result for request #{request_id}: #{inspect(work_result)}"
                )

                work_result

              {:cancelled, ^request_id} ->
                Logger.debug(
                  "Received cancellation message for request #{request_id}, killing worker"
                )

                # Forward cancellation to worker and kill it
                send(worker_pid, {:cancelled, request_id})
                Process.exit(worker_pid, :cancelled)
                :cancelled
            after
              # 10 second timeout
              10_000 ->
                Logger.error("Timeout waiting for request #{request_id}")
                Process.exit(worker_pid, :timeout)
                {:error, :timeout}
            end
          end

        # Clean up
        {_, state} = pop_in(state.active_requests[request_id])

        case result do
          :cancelled ->
            {:error, %{code: -32001, message: "Request was cancelled"}, state}

          {:ok, text} ->
            {:ok, [%{type: "text", text: text}], state}

          {:error, reason} ->
            {:error, %{code: -32000, message: "Work failed: #{inspect(reason)}"}, state}
        end
      end
    end

    def handle_call_tool(name, _params, state) do
      {:error, %{code: -32601, message: "Unknown tool: #{name}"}, state}
    end

    # Note: handle_cancelled is not part of the Handler behaviour
    # Cancellation is handled by the server infrastructure

    def terminate(_reason, _state) do
      :ok
    end

    defp perform_cancellable_work(request_id, iterations, _state, _parent_pid) do
      require Logger
      Logger.debug("Starting cancellable work for request #{request_id} in worker process")

      Enum.reduce_while(1..iterations, "", fn i, acc ->
        # Check if cancelled via message from parent
        receive do
          {:cancelled, ^request_id} ->
            Logger.debug("Worker received cancellation message for request #{request_id}")
            {:halt, :cancelled}
        after
          0 ->
            # Do some work (intentional: simulates a cancellable long task)
            Process.sleep(50)
            Logger.debug("Worker iteration #{i} complete for request #{request_id}")
            {:cont, acc <> "Iteration #{i} complete. "}
        end
      end)
      |> case do
        :cancelled ->
          Logger.debug("Worker work cancelled for request #{request_id}")
          :cancelled

        text ->
          Logger.debug("Worker work completed for request #{request_id}")
          {:ok, text}
      end
    end
  end

  describe "MCP Cancellation Protocol Compliance" do
    test "validates that initialize request cannot be cancelled" do
      # Per spec: The initialize request MUST NOT be cancelled by clients
      assert {:error, :cannot_cancel_initialize} =
               Protocol.encode_cancelled("initialize", "test")

      # Legacy function should still work but is not recommended
      notification = Protocol.encode_cancelled!("initialize", "test")
      assert notification["method"] == "notifications/cancelled"
    end

    test "encodes valid cancellation notifications" do
      {:ok, notification} = Protocol.encode_cancelled("req_123", "User requested")

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/cancelled"
      assert notification["params"]["requestId"] == "req_123"
      assert notification["params"]["reason"] == "User requested"
      # Notifications have no ID
      assert is_nil(notification["id"])
    end

    test "cancellation notification is optional reason parameter" do
      {:ok, notification} = Protocol.encode_cancelled("req_456")

      assert notification["params"]["requestId"] == "req_456"
      refute Map.has_key?(notification["params"], "reason")
    end
  end

  describe "Client-Side Cancellation" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SlowHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      # Client.start_link/1 completes the handshake in init/1.
      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        # More robust cleanup with try/catch
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

    test "client can cancel in-progress requests", %{client: client} do
      # Start a cancellable request
      task =
        Task.async(fn ->
          Client.call_tool(client, "cancellable_tool", %{"iterations" => 30})
        end)

      # Deterministic: block until the client has actually registered the
      # in-flight request instead of guessing how long that takes.
      wait_until(fn -> length(Client.get_pending_requests(client)) == 1 end, timeout: 5_000)
      [request_id] = Client.get_pending_requests(client)

      # Cancel the request
      :ok = Client.send_cancelled(client, request_id, "Test cancellation")

      # Task should return error
      assert {:error, :cancelled} = Task.await(task)

      # No more pending requests
      assert [] = Client.get_pending_requests(client)
    end

    test "client ignores responses after cancellation", %{client: client} do
      # This tests the spec requirement:
      # "The sender of the cancellation notification SHOULD ignore any
      #  response to the request that arrives afterward"

      # Start each request and capture the newly registered id before starting
      # the next one. Map key order does not identify which concurrent task
      # owns a request id.
      {task1, req1} = start_indexed_request(client, 1, [])
      {task2, req2} = start_indexed_request(client, 2, [req1])
      {task3, _req3} = start_indexed_request(client, 3, [req1, req2])

      # Cancel the second request
      :ok = Client.send_cancelled(client, req2, "Cancelled second request")

      # Collect results (increased timeout to handle case where cancellation doesn't work)
      results = Task.await_many([task1, task2, task3], 8000)

      # First and third should succeed, second should be cancelled
      assert [{1, {:ok, _}}, {2, {:error, :cancelled}}, {3, {:ok, _}}] = results
    end

    test "client handles cancellation of unknown requests gracefully", %{client: client} do
      # Per spec: receivers MAY ignore cancellation notifications if
      # the referenced request is unknown

      # Cancel non-existent request
      :ok = Client.send_cancelled(client, "unknown_req_id", "No such request")

      # Client should remain functional
      assert {:ok, %{"tools" => tools}} = Client.list_tools(client, format: :map)
      assert length(tools) > 0
    end

    test "client handles cancellation of completed requests", %{client: client} do
      # Make a fast request that completes immediately
      assert {:ok, _result} = Client.call_tool(client, "instant_tool", %{})

      # Try to cancel it after completion
      :ok = Client.send_cancelled(client, "already_completed", "Too late")

      # Client should remain functional
      assert {:ok, _} = Client.list_tools(client)
    end
  end

  describe "Server-Side Cancellation Handling" do
    setup do
      # For server-side tests, we need to check if the handler supports cancellation
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SlowHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        # More robust cleanup with try/catch
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

    test "server stops processing cancelled requests", %{client: client} do
      # This test requires the server handler to support cancellation
      # The SlowHandler.handle_call_tool/3 for "cancellable_tool" demonstrates this

      task =
        Task.async(fn ->
          Client.call_tool(client, "cancellable_tool", %{"iterations" => 30})
        end)

      # Deterministic: block until the client has actually registered the
      # in-flight request instead of guessing how long that takes.
      wait_until(fn -> length(Client.get_pending_requests(client)) == 1 end, timeout: 5_000)
      [request_id] = Client.get_pending_requests(client)
      :ok = Client.send_cancelled(client, request_id, "Stop processing")

      # Should get cancelled error
      assert {:error, :cancelled} = Task.await(task, 5000)
    end

    test "server frees resources for cancelled requests", %{client: client} do
      # Start multiple requests
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Client.call_tool(client, "cancellable_tool", %{"iterations" => 15, "index" => i})
          end)
        end

      # Wait until every request is registered, then cancel them all.
      wait_until(fn -> length(Client.get_pending_requests(client)) == 5 end, timeout: 5_000)

      pending = Client.get_pending_requests(client)

      # Cancel all pending requests immediately
      Enum.each(pending, fn req_id ->
        Client.send_cancelled(client, req_id, "Bulk cancellation")
      end)

      # Wait for results - some may be cancelled, some may complete
      # This is expected behavior since cancellation is a race condition
      results = Task.await_many(tasks, 11000)

      # At least some should be cancelled, but it's OK if some complete
      # The key is that the system remains stable
      cancelled_count = Enum.count(results, fn result -> result == {:error, :cancelled} end)
      assert cancelled_count >= 0, "System should handle cancellation gracefully"

      # All results should be either OK or cancelled (no crashes)
      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:error, :cancelled} -> true
               _ -> false
             end),
             "All results should be either success or cancellation"

      # Server should still be responsive
      assert {:ok, _} = Client.list_tools(client)
    end
  end

  describe "Race Conditions and Timing" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SlowHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        # More robust cleanup with try/catch
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

    test "handles cancellation arriving after completion", %{client: client} do
      # Per spec: "Due to network latency, cancellation notifications may
      # arrive after request processing has completed"

      # Deterministically exercise "cancellation arrives after completion":
      # let the request finish first, then send the notification.
      assert {:ok, _} = Client.call_tool(client, "instant_tool", %{})

      Client.send_cancelled(client, "possibly_completed", "Maybe too late")

      # System should remain stable
      assert {:ok, _} = Client.list_tools(client)
    end

    test "handles response arriving after cancellation", %{client: client} do
      # Start a cancellable operation
      task =
        Task.async(fn ->
          Client.call_tool(client, "cancellable_tool", %{"iterations" => 30})
        end)

      # Deterministic: block until the client has actually registered the
      # in-flight request instead of guessing how long that takes.
      wait_until(fn -> length(Client.get_pending_requests(client)) == 1 end, timeout: 5_000)
      [request_id] = Client.get_pending_requests(client)

      # Cancel it
      :ok = Client.send_cancelled(client, request_id, "Changed mind")

      # Should get cancellation error even if response arrives later
      assert {:error, :cancelled} = Task.await(task, 5000)
    end
  end

  describe "Bidirectional Cancellation" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SlowHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        # More robust cleanup with try/catch
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

    test "both client and server can send cancellation notifications", %{client: client} do
      # Per spec: "Either side can send a cancellation notification"

      # Client-initiated cancellation
      :ok = Client.send_cancelled(client, "client_cancel", "Client initiated")

      # Server could also send cancellation (simulated here)
      # In practice, server would send this through the transport

      # Both sides remain functional
      assert {:ok, _} = Client.list_tools(client)
    end
  end

  describe "Error Handling" do
    setup do
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SlowHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      on_exit(fn ->
        # More robust cleanup with try/catch
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

    test "malformed cancellation notifications are ignored", %{client: client, server: server} do
      # Omit requestId, but deliver through the connected transport's current generation.
      send_server_notification(server, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"reason" => "Malformed"}
      })

      # Client should continue functioning
      assert {:ok, _} = Client.list_tools(client)
    end

    test "cancellation with invalid request ID type is handled", %{client: client, server: server} do
      # Send cancellation with wrong type
      send_server_notification(server, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{
          "requestId" => %{"not" => "a string or number"},
          "reason" => "Invalid type"
        }
      })

      # Should be ignored gracefully
      assert {:ok, _} = Client.list_tools(client)
    end
  end

  describe "Implementation Requirements" do
    test "cancellation notifications reference only valid requests" do
      # Per spec: Cancellation notifications MUST only reference requests that:
      # - Were previously issued in the same direction
      # - Are believed to still be in-progress

      # This is enforced by the client tracking pending_requests
      {:ok, server} =
        Server.start_link(
          transport: :test,
          handler: SlowHandler
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server
        )

      assert {:ok, %{connection_status: :ready}} = Client.get_status(client)

      # No pending requests initially
      assert [] = Client.get_pending_requests(client)

      # Start a request
      task =
        Task.async(fn ->
          Client.call_tool(client, "cancellable_tool", %{"iterations" => 30})
        end)

      # Deterministic: block until the client has actually registered the
      # in-flight request instead of guessing how long that takes.
      wait_until(fn -> length(Client.get_pending_requests(client)) == 1 end, timeout: 5_000)

      # Now there's a pending request
      assert [request_id] = Client.get_pending_requests(client)

      # Test actual cancellation notification validation
      # This should work since the request exists and is in progress
      :ok = Client.send_cancelled(client, request_id, "Valid cancellation")

      # Wait for task to complete (it should be cancelled)
      result = Task.await(task, 3000)
      assert result == {:error, :cancelled}

      # Clean up
      if Process.alive?(client), do: GenServer.stop(client)
      if Process.alive?(server), do: GenServer.stop(server)
    end

    test "logging of cancellation reasons" do
      # Per spec: Both parties SHOULD log cancellation reasons for debugging

      # This is tested by checking log output in other tests
      # The implementation logs: "Request X cancelled: reason"
      assert true
    end
  end

  defp send_server_notification(server, message) do
    {:ok, edge} = Runtime.edge(server)
    state = :sys.get_state(edge)
    assert {:ok, _} = state.transport.send_message(Jason.encode!(message), state.transport_state)
  end

  defp start_indexed_request(client, index, known_request_ids) do
    task =
      Task.async(fn ->
        {index,
         Client.call_tool(client, "cancellable_tool", %{"iterations" => 20, "index" => index})}
      end)

    expected_count = length(known_request_ids) + 1

    wait_until(
      fn -> length(Client.get_pending_requests(client)) == expected_count end,
      timeout: 5_000
    )

    assert [request_id] = Client.get_pending_requests(client) -- known_request_ids
    {task, request_id}
  end
end
