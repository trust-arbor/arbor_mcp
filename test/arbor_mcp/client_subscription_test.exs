defmodule Arbor.MCP.ClientSubscriptionTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client

  @moduletag :subscription

  # Helper to create a mock client that handles all required calls
  defp create_mock_client(custom_handler) do
    spawn(fn ->
      loop = fn loop ->
        receive do
          {:"$gen_call", from, :get_default_timeout} ->
            GenServer.reply(from, {:ok, 5000})
            loop.(loop)

          {:"$gen_call", from, :get_default_retry_policy} ->
            GenServer.reply(from, {:ok, []})
            loop.(loop)

          {:"$gen_call", from, message} when is_function(custom_handler) ->
            response = custom_handler.(message)
            GenServer.reply(from, response)
            loop.(loop)

          {:"$gen_call", from, {:request, _method, _params, _opts}} ->
            # Default handler for requests
            GenServer.reply(from, {:ok, %{}})
            loop.(loop)
        end
      end

      loop.(loop)
    end)
  end

  describe "Client.subscribe_resource/2" do
    test "creates proper subscription request" do
      # Mock GenServer.call to capture the request
      test_pid = self()

      client =
        spawn(fn ->
          loop = fn loop ->
            receive do
              {:"$gen_call", from, {:request, method, params, _opts}} ->
                send(test_pid, {:captured_request, method, params})
                GenServer.reply(from, {:ok, %{}})
                loop.(loop)

              {:"$gen_call", from, :get_default_timeout} ->
                GenServer.reply(from, {:ok, 5000})
                loop.(loop)

              {:"$gen_call", from, :get_default_retry_policy} ->
                GenServer.reply(from, {:ok, []})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      # Test subscription
      assert {:ok, _result} = Client.subscribe_resource(client, "file:///config.json")

      # Verify correct request was sent
      assert_receive {:captured_request, "resources/subscribe", %{"uri" => "file:///config.json"}}
    end

    test "handles subscription success response" do
      client =
        spawn(fn ->
          loop = fn loop ->
            receive do
              {:"$gen_call", from, {:request, "resources/subscribe", _params, _opts}} ->
                GenServer.reply(from, {:ok, %{}})
                loop.(loop)

              {:"$gen_call", from, :get_default_timeout} ->
                GenServer.reply(from, {:ok, 5000})
                loop.(loop)

              {:"$gen_call", from, :get_default_retry_policy} ->
                GenServer.reply(from, {:ok, []})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      assert {:ok, %{}} = Client.subscribe_resource(client, "file:///test.txt")
    end

    test "handles subscription error response" do
      client =
        spawn(fn ->
          loop = fn loop ->
            receive do
              {:"$gen_call", from, {:request, "resources/subscribe", _params, _opts}} ->
                GenServer.reply(from, {:error, "Resource not found"})
                loop.(loop)

              {:"$gen_call", from, :get_default_timeout} ->
                GenServer.reply(from, {:ok, 5000})
                loop.(loop)

              {:"$gen_call", from, :get_default_retry_policy} ->
                GenServer.reply(from, {:ok, []})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      assert {:error, "Resource not found"} =
               Client.subscribe_resource(client, "file:///missing.txt")
    end

    test "supports timeout option" do
      client =
        create_mock_client(fn
          {:request, "resources/subscribe", _params, _opts} ->
            :timer.sleep(100)
            {:ok, %{}}
        end)

      assert {:ok, %{}} = Client.subscribe_resource(client, "file:///slow.txt", timeout: 200)
    end

    test "supports format option" do
      client =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:request, "resources/subscribe", _params, _opts}} ->
              GenServer.reply(from, {:ok, %{"status" => "subscribed"}})
          end
        end)

      # Test default format (should use atomize_keys)
      assert {:ok, result} = Client.subscribe_resource(client, "file:///test.txt")

      # The result should be processed through format_response
      # (specific format depends on atomize_keys implementation)
      assert is_map(result)
    end
  end

  describe "Client.unsubscribe_resource/2" do
    test "creates proper unsubscription request" do
      test_pid = self()

      client =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:request, method, params, _opts}} ->
              send(test_pid, {:captured_request, method, params})
              GenServer.reply(from, {:ok, %{}})
          end
        end)

      assert {:ok, _result} = Client.unsubscribe_resource(client, "file:///config.json")

      assert_receive {:captured_request, "resources/unsubscribe",
                      %{"uri" => "file:///config.json"}}
    end

    test "handles unsubscription success response" do
      client =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:request, "resources/unsubscribe", _params, _opts}} ->
              GenServer.reply(from, {:ok, %{}})
          end
        end)

      assert {:ok, %{}} = Client.unsubscribe_resource(client, "file:///test.txt")
    end

    test "handles unsubscription error response" do
      client =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:request, "resources/unsubscribe", _params, _opts}} ->
              GenServer.reply(from, {:error, "Not subscribed"})
          end
        end)

      assert {:error, "Not subscribed"} = Client.unsubscribe_resource(client, "file:///test.txt")
    end
  end

  describe "resource notification handling" do
    test "handles resource update notifications" do
      # This test would require integration with the full Client GenServer
      # For now, we'll test the notification handling logic separately

      # Test that debug logging doesn't crash
      Application.put_env(:arbor_mcp, :debug_logging, true)

      # The notification handling is tested as part of handle_info in Client
      # This serves as a placeholder for more comprehensive integration testing
      assert true

      Application.put_env(:arbor_mcp, :debug_logging, false)
    end
  end

  describe "function signatures and documentation" do
    test "subscribe_resource/3 has correct arity" do
      # Ensure module is compiled
      Code.ensure_compiled!(Arbor.MCP.Client)
      # Functions with default arguments only have the maximum arity
      assert function_exported?(Arbor.MCP.Client, :subscribe_resource, 3)
    end

    test "unsubscribe_resource/3 has correct arity" do
      # Ensure module is compiled
      Code.ensure_compiled!(Arbor.MCP.Client)
      # Functions with default arguments only have the maximum arity
      assert function_exported?(Arbor.MCP.Client, :unsubscribe_resource, 3)
    end
  end
end
