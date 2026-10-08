defmodule Arbor.MCP.MessageProcessorTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.MessageProcessor.Conn

  defmodule TestPlug do
    @behaviour Arbor.MCP.MessageProcessor

    def init(opts), do: opts

    def call(conn, opts) do
      value = Keyword.get(opts, :assign_value, "test")
      MessageProcessor.assign(conn, :test_key, value)
    end
  end

  defmodule HaltingPlug do
    @behaviour Arbor.MCP.MessageProcessor

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> MessageProcessor.assign(:halted_here, true)
      |> MessageProcessor.halt()
    end
  end

  defmodule HandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok, %{name: "handler-server", version: "1.0.0", capabilities: %{completions: %{}}}, state}
    end

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_complete(ref, argument, state) do
      {:ok,
       %{
         completion: %{
           values: ["#{ref["name"]}:#{argument["value"]}"],
           total: 1,
           hasMore: false
         }
       }, state}
    end
  end

  defmodule InitOptsHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         name: Map.fetch!(state, :name),
         version: Map.fetch!(state, :version),
         capabilities: %{}
       }, state}
    end
  end

  defmodule TrackedHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      state = Map.new(opts)
      send(state.test_pid, {:handler_started, self()})
      {:ok, state}
    end

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}
  end

  defmodule RaisingHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      state = Map.new(opts)
      send(state.test_pid, {:handler_started, self()})
      {:ok, state}
    end

    @impl true
    def handle_list_tools(_cursor, _state) do
      raise "handler blew up: s3cr3t-detail"
    end
  end

  defmodule BlockingHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      state = Map.new(opts)
      send(state.test_pid, {:handler_started, self()})
      {:ok, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      # Blocks until told otherwise; the caller's timeout fires first.
      receive do
        :unblock -> {:ok, [], nil, state}
      end
    end
  end

  defmodule ErrorReturningHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state) do
      {:error, %{secret: "s3cr3t-detail"}, state}
    end
  end

  defmodule ToolErrorHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_list_tools(_cursor, state) do
      {:ok,
       [
         %{
           name: "test_error_handling",
           description: "Tests error response handling",
           inputSchema: %{type: "object", properties: %{}}
         }
       ], nil, state}
    end

    @impl true
    def handle_call_tool("test_error_handling", _args, state),
      do: {:error, "This tool intentionally returns an error for testing", state}

    def handle_call_tool(name, _args, state),
      do: {:error, "Unknown tool: #{name}", state}
  end

  defmodule StringNameHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_list_prompts(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_get_prompt("broken", _args, state),
      do: {:error, "render exploded", state}

    def handle_get_prompt(name, _args, state),
      do: {:error, "Unknown prompt: #{name}", state}

    @impl true
    def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_read_resource("test://boom", state),
      do: {:error, "disk exploded", state}

    def handle_read_resource(uri, state),
      do: {:error, "Resource not found: #{uri}", state}
  end

  defmodule FailingInitHandlerServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:stop, {:boom, "s3cr3t-detail"}}
  end

  # Plain GenServer handler: lets these tests drive the reply shapes the
  # handler bridge produces without going through `use Arbor.MCP.Server.Handler`.
  defmodule ProtocolHandlerServer do
    use GenServer

    def init(opts), do: {:ok, Map.new(opts)}

    def handle_call({:set_log_level, "verbose"}, _from, state) do
      {:reply, {:error, "Invalid log level: verbose"}, state}
    end

    def handle_call({:set_log_level, level}, _from, state) do
      send(state.test_pid, {:log_level_set, level})
      {:reply, {:ok, %{}}, state}
    end

    def handle_call({:task_get, task_id}, _from, state) do
      {:reply, {:ok, %{"taskId" => task_id, "status" => "completed"}}, state}
    end

    def handle_call({:task_update, task_id, responses}, _from, state) do
      send(state.test_pid, {:task_updated, task_id, responses})
      {:reply, {:ok, %{}}, state}
    end

    def handle_call({:list_roots}, _from, state) do
      {:reply, {:ok, [%{"uri" => "file:///"}]}, state}
    end

    def handle_call({:request, "custom/ok", _params}, _from, state) do
      {:reply, {:ok, %{"ok" => true}}, state}
    end

    def handle_call({:request, "custom/fail", _params}, _from, state) do
      {:reply, {:error, %{secret: "s3cr3t-detail"}}, state}
    end

    def handle_call({:request, method, _params}, _from, state) do
      {:reply, {:error, "Unknown method: #{method}"}, state}
    end
  end

  describe "new/2" do
    test "creates a new connection with request" do
      request = %{"method" => "test", "params" => %{}}
      conn = MessageProcessor.new(request, transport: :http, session_id: "123")

      assert %Conn{} = conn
      assert conn.request == request
      assert conn.transport == :http
      assert conn.session_id == "123"
      assert conn.response == nil
      assert conn.assigns == %{}
      assert conn.halted == false
    end
  end

  describe "assign/3" do
    test "assigns a value to the connection" do
      conn = MessageProcessor.new(%{})
      updated_conn = MessageProcessor.assign(conn, :key, "value")

      assert updated_conn.assigns[:key] == "value"
    end
  end

  describe "halt/1" do
    test "halts the connection" do
      conn = MessageProcessor.new(%{})
      halted_conn = MessageProcessor.halt(conn)

      assert halted_conn.halted == true
    end
  end

  describe "put_response/2" do
    test "sets the response" do
      conn = MessageProcessor.new(%{})
      response = %{"result" => "success"}
      updated_conn = MessageProcessor.put_response(conn, response)

      assert updated_conn.response == response
    end
  end

  describe "run/2" do
    test "runs a series of plugs" do
      conn = MessageProcessor.new(%{})

      plugs = [
        {TestPlug, [assign_value: "first"]},
        {TestPlug, [assign_value: "second"]}
      ]

      result_conn = MessageProcessor.run(plugs, conn)

      # Second plug should overwrite the first
      assert result_conn.assigns[:test_key] == "second"
    end

    test "stops processing when halted" do
      conn = MessageProcessor.new(%{})

      plugs = [
        {HaltingPlug, []},
        {TestPlug, [assign_value: "should_not_run"]}
      ]

      result_conn = MessageProcessor.run(plugs, conn)

      assert result_conn.halted == true
      assert result_conn.assigns[:halted_here] == true
      assert result_conn.assigns[:test_key] == nil
    end
  end

  describe "process/2 with Server.Handler modules" do
    test "normalizes initialize replies from handler GenServers" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0.0"}
        },
        "id" => 1
      }

      conn =
        request |> MessageProcessor.new() |> MessageProcessor.process(%{handler: HandlerServer})

      assert conn.response["result"]["serverInfo"] == %{
               "name" => "handler-server",
               "version" => "1.0.0"
             }

      assert conn.response["result"]["protocolVersion"] == "2025-11-25"
    end

    test "dispatches completion params as ref and argument" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "completion/complete",
        "params" => %{
          "ref" => %{"type" => "ref/prompt", "name" => "prompt"},
          "argument" => %{"name" => "arg", "value" => "par"}
        },
        "id" => 2
      }

      conn =
        request |> MessageProcessor.new() |> MessageProcessor.process(%{handler: HandlerServer})

      assert conn.response["result"]["completion"]["values"] == ["prompt:par"]
    end

    test "passes handler_opts to temporary handler GenServers" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0.0"}
        },
        "id" => 3
      }

      conn =
        request
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: InitOptsHandlerServer,
          handler_opts: [name: "configured-handler", version: "2.0.0"]
        })

      assert conn.response["result"]["serverInfo"] == %{
               "name" => "configured-handler",
               "version" => "2.0.0"
             }
    end
  end

  describe "process/2 tools/call protocol vs execution errors" do
    test "registered tool {:error, reason} stays result isError, not JSON-RPC" do
      conn =
        30
        |> tools_call_request("test_error_handling")
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: ToolErrorHandlerServer})

      assert %{"result" => result} = conn.response
      refute Map.has_key?(conn.response, "error")
      assert result["isError"] == true
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text =~ "This tool intentionally returns an error for testing"
    end

    test "unknown tool name string is JSON-RPC -32602, not isError" do
      conn =
        31
        |> tools_call_request("nope")
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: ToolErrorHandlerServer})

      assert %{"error" => error} = conn.response
      refute Map.has_key?(conn.response, "result")
      assert error["code"] == -32602
      assert error["message"] =~ "Unknown tool: nope"
    end
  end

  describe "process/2 prompt and resource unknown-name strings" do
    @describetag capture_log: true

    test "unknown prompt name string is JSON-RPC -32602, not -32603" do
      conn =
        32
        |> protocol_request("prompts/get", %{"name" => "nope", "arguments" => %{}})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: StringNameHandlerServer})

      assert %{"error" => error} = conn.response
      refute Map.has_key?(conn.response, "result")
      assert error["code"] == -32602
      assert error["message"] =~ "Unknown prompt: nope"
    end

    test "unknown resource string is JSON-RPC -32602, not -32603" do
      conn =
        33
        |> protocol_request("resources/read", %{"uri" => "missing://x"})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: StringNameHandlerServer})

      assert %{"error" => error} = conn.response
      refute Map.has_key?(conn.response, "result")
      assert error["code"] == -32602
      assert error["message"] =~ "Resource not found: missing://x"
    end

    test "non-unknown prompt string stays -32603" do
      conn =
        34
        |> protocol_request("prompts/get", %{"name" => "broken", "arguments" => %{}})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: StringNameHandlerServer})

      assert %{"error" => error} = conn.response
      assert error["code"] == -32603
    end

    test "non-unknown resource string stays -32603" do
      conn =
        35
        |> protocol_request("resources/read", %{"uri" => "test://boom"})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: StringNameHandlerServer})

      assert %{"error" => error} = conn.response
      assert error["code"] == -32603
    end
  end

  describe "process/2 handler fault tolerance" do
    @describetag capture_log: true

    test "handler crash returns -32603 and does not kill the request process" do
      Process.flag(:trap_exit, true)

      conn =
        10
        |> tools_list_request()
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: RaisingHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert %{"error" => error} = conn.response
      assert error["code"] == -32603
      assert error["message"] == "Tools list failed"
      assert error["data"] == %{"type" => "handler_crash"}
      refute inspect(conn.response) =~ "s3cr3t-detail"

      # The handler must not be linked to the request process, so no exit
      # signal is delivered even while trapping exits.
      refute_received {:EXIT, _pid, _reason}

      assert_receive {:handler_started, handler_pid}
      assert_handler_down(handler_pid)
    end

    test "handler blocking past :handler_call_timeout returns -32603 timeout error" do
      conn =
        11
        |> tools_list_request()
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: BlockingHandlerServer,
          handler_opts: [test_pid: self()],
          handler_call_timeout: 100
        })

      assert %{"error" => error} = conn.response
      assert error["code"] == -32603
      assert error["data"] == %{"type" => "handler_timeout"}

      # The stuck handler must be reaped after the request, not leaked.
      assert_receive {:handler_started, handler_pid}
      assert_handler_down(handler_pid)
    end

    test "handler is stopped after a successful request (no process leak)" do
      conn =
        12
        |> tools_list_request()
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: TrackedHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert conn.response["result"] == %{"tools" => []}

      assert_receive {:handler_started, handler_pid}
      assert_handler_down(handler_pid)
    end

    test "handler error returns do not leak error details in the response" do
      conn =
        13
        |> tools_list_request()
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: ErrorReturningHandlerServer})

      assert %{"error" => error} = conn.response
      assert error["code"] == -32603
      assert error["message"] == "Tools list failed"
      assert error["data"] == %{"type" => "handler_error"}
      refute inspect(conn.response) =~ "s3cr3t-detail"
    end

    test "handler start failure returns a generic -32603 error" do
      conn =
        14
        |> tools_list_request()
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: FailingInitHandlerServer})

      assert %{"error" => error} = conn.response
      assert error["code"] == -32603
      assert error["message"] == "Internal server error"
      assert error["data"] == %{"type" => "handler_start_failed"}
      refute inspect(conn.response) =~ "s3cr3t-detail"
    end
  end

  describe "process/2 method coverage" do
    @describetag capture_log: true

    test "logging/setLevel is routed to the handler" do
      conn =
        20
        |> protocol_request("logging/setLevel", %{"level" => "debug"})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert conn.response["result"] == %{}
      assert_receive {:log_level_set, "debug"}
    end

    test "logging/setLevel rejects invalid levels before handler dispatch" do
      conn =
        21
        |> protocol_request("logging/setLevel", %{"level" => "verbose"})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert %{"error" => error} = conn.response
      assert error["code"] == -32602
      assert error["message"] == "Invalid parameters"
      refute_received {:log_level_set, "verbose"}
    end

    test "task methods reach the handler" do
      conn =
        22
        |> protocol_request("tasks/get", %{"taskId" => "t-1"})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert conn.response["result"] == %{"taskId" => "t-1", "status" => "completed"}
    end

    test "modern tasks/update reaches the handler as an ack-only write" do
      params = %{
        "taskId" => "t-1",
        "inputResponses" => %{"approval" => %{"action" => "accept"}},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{
            "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
          }
        }
      }

      conn =
        26
        |> protocol_request("tasks/update", params)
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()],
          protocol_mode: :modern_only
        })

      assert conn.response["result"]["resultType"] == "complete"
      assert_receive {:task_updated, "t-1", %{"approval" => %{"action" => "accept"}}}
    end

    test "roots/list reaches the handler" do
      conn =
        23
        |> protocol_request("roots/list", %{})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert conn.response["result"] == %{"roots" => [%{"uri" => "file:///"}]}
    end

    test "custom methods succeed through the handler escape hatch" do
      conn =
        24
        |> protocol_request("custom/ok", %{})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert conn.response["result"] == %{"ok" => true}
    end

    test "an unimplemented custom method is -32601" do
      conn =
        25
        |> protocol_request("custom/missing", %{})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert %{"error" => error} = conn.response
      assert error["code"] == -32601
      assert error["message"] == "Method not found"
    end

    test "a failing custom method is -32603, not -32601" do
      conn =
        26
        |> protocol_request("custom/fail", %{})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{
          handler: ProtocolHandlerServer,
          handler_opts: [test_pid: self()]
        })

      assert %{"error" => error} = conn.response
      assert error["code"] == -32603
      assert error["data"] == %{"type" => "handler_error"}
      refute inspect(conn.response) =~ "s3cr3t-detail"
    end
  end

  defp protocol_request(id, method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}
  end

  defp tools_call_request(id, name, arguments \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments},
      "id" => id
    }
  end

  defp tools_list_request(id) do
    %{"jsonrpc" => "2.0", "method" => "tools/list", "params" => %{}, "id" => id}
  end

  defp assert_handler_down(handler_pid) do
    ref = Process.monitor(handler_pid)
    assert_receive {:DOWN, ^ref, :process, ^handler_pid, _reason}, 2_000
  end
end
