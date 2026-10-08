defmodule Arbor.MCP.ClientBeamTransportTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.HandlerServer

  defmodule CalculatorHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(initial_state), do: {:ok, Map.new(initial_state)}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         "protocolVersion" => "2025-03-26",
         "capabilities" => %{"tools" => %{}},
         "serverInfo" => %{
           "name" => "CalculatorHandler",
           "version" => "1.0.0"
         }
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        tool("add", "Add two numbers"),
        tool("subtract", "Subtract two numbers"),
        tool("divide", "Divide two numbers"),
        %{
          "name" => "slow_operation",
          "description" => "A slow operation for testing timeouts",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("add", %{"a" => a, "b" => b}, state) do
      {:ok, structured_result(%{"result" => a + b}), state}
    end

    def handle_call_tool("subtract", %{"a" => a, "b" => b}, state) do
      {:ok, structured_result(%{"result" => a - b}), state}
    end

    def handle_call_tool("divide", %{"b" => 0}, state) do
      {:error, "Division by zero", state}
    end

    def handle_call_tool("divide", %{"a" => a, "b" => b}, state) do
      {:ok, structured_result(%{"result" => a / b}), state}
    end

    def handle_call_tool("slow_operation", _args, state) do
      Process.sleep(100)
      {:ok, structured_result(%{"result" => "completed"}), state}
    end

    def handle_call_tool("counter", _args, state) do
      count = Map.get(state, :counter, 0) + 1
      {:ok, structured_result(%{"count" => count}), Map.put(state, :counter, count)}
    end

    def handle_call_tool(name, _args, state) do
      {:error, "Tool not found: #{name}", state}
    end

    defp tool(name, description) do
      %{
        "name" => name,
        "description" => description,
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "a" => %{"type" => "number"},
            "b" => %{"type" => "number"}
          },
          "required" => ["a", "b"]
        }
      }
    end

    defp structured_result(data) do
      %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(data)}],
        "structuredContent" => data
      }
    end
  end

  defmodule BatchHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         "protocolVersion" => "2025-03-26",
         "capabilities" => %{"tools" => %{}},
         "serverInfo" => %{"name" => "BatchHandler", "version" => "1.0.0"}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tool = %{
        "name" => "multiply",
        "description" => "Multiply two numbers",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "a" => %{"type" => "number"},
            "b" => %{"type" => "number"}
          },
          "required" => ["a", "b"]
        }
      }

      {:ok, [tool], nil, state}
    end

    @impl true
    def handle_call_tool("multiply", %{"a" => a, "b" => b}, state) do
      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => "#{a * b}"}],
         "structuredContent" => %{"result" => a * b}
       }, state}
    end

    def handle_call_tool(name, _args, state) do
      {:error, "Tool not found: #{name}", state}
    end
  end

  describe "Client with BEAM transport" do
    setup do
      {:ok, server_pid} =
        HandlerServer.start_link(
          transport: :beam,
          handler: CalculatorHandler,
          handler_args: %{counter: 0}
        )

      on_exit(fn -> stop_if_alive(server_pid) end)

      {:ok, server_pid: server_pid}
    end

    test "connects to BEAM server", %{server_pid: server_pid} do
      {:ok, client} =
        Client.start_link(
          transport: :beam,
          server: server_pid,
          protocol_mode: :legacy_only
        )

      {:ok, status} = Client.get_status(client)
      assert status.connection_status == :ready
    end

    test "calls tools via BEAM transport", %{server_pid: server_pid} do
      {:ok, client} = Client.start_link(transport: :beam, server: server_pid)

      assert {:ok, %{"structuredContent" => %{"result" => 5}}} =
               Client.call_tool(client, "add", %{"a" => 2, "b" => 3}, format: :map)

      assert {:ok, %{"structuredContent" => %{"result" => 10}}} =
               Client.call_tool(client, "subtract", %{"a" => 15, "b" => 5}, format: :map)

      assert {:ok, %{"structuredContent" => %{"result" => 2.5}}} =
               Client.call_tool(client, "divide", %{"a" => 5, "b" => 2}, format: :map)
    end

    test "handles errors via BEAM transport", %{server_pid: server_pid} do
      {:ok, client} = Client.start_link(transport: :beam, server: server_pid)

      assert {:error, %{"code" => -32000, "message" => divide_error}} =
               Client.call_tool(client, "divide", %{"a" => 10, "b" => 0}, format: :map)

      assert divide_error =~ "Division by zero"

      assert {:error, %{"code" => -32602, "message" => unknown_error}} =
               Client.call_tool(client, "unknown_method", %{}, format: :map)

      assert unknown_error =~ "Tool not found: unknown_method"
    end

    test "respects timeout settings", %{server_pid: server_pid} do
      {:ok, client} = Client.start_link(transport: :beam, server: server_pid, timeout: 50)

      assert {:error, :timeout} = Client.call_tool(client, "slow_operation", %{}, format: :map)
    end

    test "requires a server process" do
      Process.flag(:trap_exit, true)

      assert {:error, _reason} =
               Client.start_link(
                 transport: :beam,
                 service_name: :nonexistent_service
               )
    end
  end

  describe "Client with batch operations over BEAM transport" do
    setup do
      {:ok, server_pid} = HandlerServer.start_link(transport: :beam, handler: BatchHandler)
      on_exit(fn -> stop_if_alive(server_pid) end)
      {:ok, server_pid: server_pid}
    end

    test "handles batch requests via BEAM transport", %{server_pid: server_pid} do
      {:ok, client} =
        Client.start_link(
          transport: :beam,
          server: server_pid,
          protocol_mode: :legacy_only
        )

      requests = [
        {"tools/call", %{"name" => "multiply", "arguments" => %{"a" => 2, "b" => 3}}},
        {"tools/call", %{"name" => "multiply", "arguments" => %{"a" => 4, "b" => 5}}},
        {"tools/call", %{"name" => "multiply", "arguments" => %{"a" => 6, "b" => 7}}}
      ]

      assert {:ok, results} = Client.batch_request(client, requests)

      assert [
               {:ok, %{"structuredContent" => %{"result" => 6}}},
               {:ok, %{"structuredContent" => %{"result" => 20}}},
               {:ok, %{"structuredContent" => %{"result" => 42}}}
             ] = results
    end
  end

  describe "Client with concurrent operations over BEAM transport" do
    setup do
      {:ok, server_pid} =
        HandlerServer.start_link(
          transport: :beam,
          handler: CalculatorHandler,
          handler_args: %{counter: 0}
        )

      on_exit(fn -> stop_if_alive(server_pid) end)

      {:ok, server_pid: server_pid}
    end

    test "handles concurrent requests via BEAM transport", %{server_pid: server_pid} do
      {:ok, client} = Client.start_link(transport: :beam, server: server_pid)

      results =
        1..100
        |> Enum.map(fn _ ->
          Task.async(fn -> Client.call_tool(client, "counter", %{}, format: :map) end)
        end)
        |> Task.await_many(15_000)

      assert Enum.all?(results, fn
               {:ok, %{"structuredContent" => %{"count" => count}}} when is_integer(count) ->
                 true

               _ ->
                 false
             end)

      counts =
        results
        |> Enum.map(fn {:ok, %{"structuredContent" => %{"count" => count}}} -> count end)
        |> Enum.sort()

      assert counts == Enum.to_list(1..100)
    end
  end

  # The server is linked to the test process, so it can already be shutting
  # down when on_exit runs; `safe_stop_process/1` swallows every exit reason,
  # not only :noproc.
  defp stop_if_alive(pid) when is_pid(pid), do: Arbor.MCP.TestHelpers.safe_stop_process(pid)
end
