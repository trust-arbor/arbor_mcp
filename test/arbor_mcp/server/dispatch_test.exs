defmodule Arbor.MCP.Server.DispatchTest do
  @moduledoc """
  Tests for the shared MCP method table used by the handler-process and stdio
  transports (audit M9), including the method coverage stdio used to lack
  (M15) and the client-facing error shaping (M12).
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Server.Dispatch

  defmodule FullHandler do
    use Arbor.MCP.Server.Handler

    def init(_args), do: {:ok, %{level: nil}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok, %{"protocolVersion" => "2025-11-25", "serverInfo" => %{"name" => "full"}}, state}
    end

    @impl true
    def handle_list_tools(cursor, state) do
      {:ok, [%{name: "echo", description: "echo"}], cursor && "next", state}
    end

    @impl true
    def handle_call_tool("echo", args, state) do
      {:ok, %{content: [%{type: "text", text: args["text"]}], is_error: false}, state}
    end

    def handle_call_tool("bare_map", _args, state) do
      {:ok, %{value: 42}, state}
    end

    def handle_call_tool("boom", _args, state) do
      {:error, %{internal: :secret_detail}, state}
    end

    def handle_call_tool("needs_sampling", _args, state) do
      error = Arbor.MCP.Error.missing_required_client_capability(%{"sampling" => %{}})
      {:error, error, state}
    end

    def handle_call_tool("background", _args, state) do
      {:ok,
       %{
         resultType: :task,
         taskId: "task-1",
         status: "working",
         createdAt: "2026-08-04T00:00:00Z",
         lastUpdatedAt: "2026-08-04T00:00:00Z",
         ttlMs: 60_000,
         pollIntervalMs: 1_000
       }, state}
    end

    def handle_call_tool(name, _args, state) do
      {:error, "Unknown tool: #{name}", state}
    end

    @impl true
    def handle_complete(_ref, _argument, state) do
      {:ok, %{completion: %{values: ["a"]}}, state}
    end

    @impl true
    def handle_subscribe_resource(_uri, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [%{"uri" => "file:///"}], state}

    @impl true
    def handle_set_log_level(level, state), do: {:ok, %{state | level: level}}

    @impl true
    def handle_task_get(task_id, state) do
      {:ok,
       %{
         "taskId" => task_id,
         "status" => "working",
         "createdAt" => "2026-08-04T00:00:00Z",
         "lastUpdatedAt" => "2026-08-04T00:00:00Z",
         "ttlMs" => 60_000
       }, state}
    end

    @impl true
    def handle_task_list(_cursor, state), do: {:ok, [%{"taskId" => "t1"}], nil, state}

    @impl true
    def handle_task_update(_task_id, _input_responses, state), do: {:ok, %{}, state}
  end

  defmodule BareHandler do
    @behaviour Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_call_tool(_name, _args, state), do: {:error, "no tools", state}
  end

  defp request(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => 1}
  end

  defp dispatch(method, params \\ %{}, handler \\ FullHandler, state \\ %{level: nil}) do
    Dispatch.dispatch(request(method, params), handler, state)
  end

  describe "method coverage" do
    test "every advertised method is answered" do
      for method <- Dispatch.methods(), method != "notifications/elicitation/complete" do
        assert {:response, response, _state} = dispatch(method)
        assert response["jsonrpc"] == "2.0"
        assert Map.has_key?(response, "result") or Map.has_key?(response, "error")
      end
    end

    test "known_method?/1 reports the table" do
      assert Dispatch.known_method?("completion/complete")
      assert Dispatch.known_method?("logging/setLevel")
      assert Dispatch.known_method?("tasks/get")
      assert Dispatch.known_method?("tasks/update")
      refute Dispatch.known_method?("custom/thing")
    end

    test "ping answers an empty result" do
      assert {:response, %{"result" => %{}}, _state} = dispatch("ping")
    end

    test "rejects incomplete modern request metadata before dispatch" do
      params = %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
        }
      }

      assert {:response, %{"error" => error}, _state} = dispatch("tools/list", params)
      assert error["code"] == -32602
      assert error["data"]["field"] == "io.modelcontextprotocol/clientCapabilities"
    end

    test "advertises the configured modern versions for unsupported requests" do
      params = %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2099-01-01",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }

      assert {:response, %{"error" => error}, _state} =
               Dispatch.dispatch(
                 request("tools/list", params),
                 FullHandler,
                 %{level: nil},
                 protocol_mode: :modern_only
               )

      assert error["code"] == -32022

      assert error["data"] == %{
               "requested" => "2099-01-01",
               "supported" => ["2026-07-28"]
             }
    end

    test "stamps successful modern results at the dispatch boundary" do
      params = %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }

      assert {:response, %{"result" => result}, _state} = dispatch("tools/list", params)
      assert result["resultType"] == "complete"
      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "Arbor.MCP"
    end

    test "preserves missing client capability errors from handlers" do
      params = %{
        "name" => "needs_sampling",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }

      assert {:response, %{"error" => error}, _state} = dispatch("tools/call", params)
      assert error["code"] == -32021
      assert error["data"]["requiredCapabilities"] == %{"sampling" => %{}}
    end

    test "rejects methods removed from the modern protocol" do
      params = %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }

      assert {:response, %{"error" => error}, _state} = dispatch("ping", params)
      assert error["code"] == -32601
      assert error["data"]["method"] == "ping"
      assert error["data"]["protocolVersion"] == "2026-07-28"
    end

    test "gates modern task methods on the per-request extension capability" do
      params = modern_params(%{"taskId" => "task-1"})

      assert {:response, %{"error" => error}, _state} = dispatch("tasks/get", params)
      assert error["code"] == -32021

      assert error["data"]["requiredCapabilities"] == %{
               "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
             }

      params = modern_task_params(%{"taskId" => "task-1"})
      assert {:response, %{"result" => result}, _state} = dispatch("tasks/get", params)
      assert result["resultType"] == "complete"
      assert result["taskId"] == "task-1"

      update =
        modern_task_params(%{
          "taskId" => "task-1",
          "inputResponses" => %{"approval" => %{"action" => "accept"}}
        })

      assert {:response, %{"result" => %{"resultType" => "complete"}}, _state} =
               dispatch("tasks/update", update)
    end

    test "never returns an unsolicited task handle to a non-declaring client" do
      params = modern_params(%{"name" => "background", "arguments" => %{}})

      assert {:response, %{"error" => error}, _state} = dispatch("tools/call", params)
      assert error["code"] == -32021

      params = modern_task_params(%{"name" => "background", "arguments" => %{}})
      assert {:response, %{"result" => result}, _state} = dispatch("tools/call", params)
      assert result["resultType"] == "task"
      assert result["taskId"] == "task-1"
      refute Map.has_key?(result, "content")
    end

    test "keeps legacy-only task list and result methods out of the modern table" do
      params = modern_task_params(%{"taskId" => "task-1"})

      for method <- ["tasks/list", "tasks/result"] do
        assert {:response, %{"error" => error}, _state} = dispatch(method, params)
        assert error["code"] == -32601
      end
    end
  end

  describe "results" do
    test "tools/list is paginated" do
      assert {:response, %{"result" => result}, _state} = dispatch("tools/list")
      assert [%{name: "echo"}] = result["tools"]
      refute Map.has_key?(result, "nextCursor")

      assert {:response, %{"result" => paged}, _state} =
               dispatch("tools/list", %{"cursor" => "c"})

      assert paged["nextCursor"] == "next"
    end

    test "tools/call normalizes content and the isError flag" do
      params = %{"name" => "echo", "arguments" => %{"text" => "hi"}}
      assert {:response, %{"result" => result}, _state} = dispatch("tools/call", params)

      assert result["content"] == [%{"type" => "text", "text" => "hi"}]
      assert result["isError"] == false
    end

    test "tools/call wraps a content-less map for handler transports" do
      params = %{"name" => "bare_map", "arguments" => %{}}
      assert {:response, %{"result" => result}, _state} = dispatch("tools/call", params)
      assert result == %{"content" => %{"value" => 42}}
    end

    test "roots/list wraps the handler list" do
      assert {:response, %{"result" => %{"roots" => [_ | _]}}, _state} = dispatch("roots/list")
    end

    test "logging/setLevel reaches the handler" do
      assert {:response, %{"result" => %{}}, state} =
               dispatch("logging/setLevel", %{"level" => "debug"})

      assert state.level == "debug"
    end

    test "task methods are wired" do
      assert {:response, %{"result" => %{"taskId" => "t7"}}, _state} =
               dispatch("tasks/get", %{"taskId" => "t7"})

      assert {:response, %{"result" => %{"tasks" => [_]}}, _state} = dispatch("tasks/list")
    end
  end

  describe "errors" do
    test "unknown methods are -32601" do
      assert {:response, %{"error" => error}, _state} = dispatch("nope/nope")
      assert error["code"] == -32601
      assert error["message"] =~ "Method not found"
    end

    test "unknown notifications produce no response" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/unknown"}
      assert {:notification, _state} = Dispatch.dispatch(notification, FullHandler, %{})
    end

    test "callbacks a handler does not implement are -32601" do
      req =
        request("completion/complete", %{
          "ref" => %{},
          "argument" => %{"name" => "value", "value" => ""}
        })

      assert {:response, %{"error" => error}, _state} =
               Dispatch.dispatch(req, BareHandler, %{})

      assert error["code"] == -32601
    end

    test "invalid method parameters never reach the handler" do
      request = request("tools/call", %{"arguments" => %{}})

      assert {:response, %{"error" => error}, %{level: nil}} =
               Dispatch.dispatch(request, FullHandler, %{level: nil})

      assert error["code"] == -32602
      assert error["data"] == %{missing: ["name"]}
    end

    test "handler-authored string reasons are preserved" do
      params = %{"name" => "missing", "arguments" => %{}}
      assert {:response, %{"error" => error}, _state} = dispatch("tools/call", params)
      assert error["code"] == -32602
      assert error["message"] == "Tool call error: Unknown tool: missing"
    end

    @tag capture_log: true
    test "opaque reasons are not leaked to the client" do
      params = %{"name" => "boom", "arguments" => %{}}
      assert {:response, %{"error" => error}, _state} = dispatch("tools/call", params)
      assert error["message"] == "Tool call error"
      refute inspect(error) =~ "secret_detail"
    end

    test "invalid requests are -32600" do
      assert {:response, %{"error" => error}, _state} =
               Dispatch.dispatch(["not", "a", "request"], FullHandler, %{})

      assert error["code"] == -32600
    end
  end

  defp modern_params(params) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end

  defp modern_task_params(params) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{
        "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
      }
    })
  end
end
