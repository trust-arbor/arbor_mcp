defmodule ExMCP.ACP.Adapters.ZCodeTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.ZCode
  alias ExMCP.ACP.PromptQueue

  setup do
    {:ok, state} = ZCode.init(cwd: "/tmp")

    %{state: state}
  end

  defp decode(data) when is_binary(data) do
    data
    |> String.trim()
    |> Jason.decode!()
  end

  defp decode_lines(data) do
    data
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&Jason.decode!/1)
  end

  describe "static adapter metadata" do
    test "returns zcode app-server command" do
      assert {"zcode", ["app-server"]} = ZCode.command([])
    end

    test "respects cli_path option" do
      {cmd, ["app-server"]} = ZCode.command(cli_path: "/usr/local/bin/zcode")
      assert cmd == "/usr/local/bin/zcode"
    end

    test "respects ZCODE_EXECUTABLE env" do
      prev = System.get_env("ZCODE_EXECUTABLE")
      System.put_env("ZCODE_EXECUTABLE", "/custom/zcode")
      {cmd, _} = ZCode.command([])
      assert cmd == "/custom/zcode"

      if prev,
        do: System.put_env("ZCODE_EXECUTABLE", prev),
        else: System.delete_env("ZCODE_EXECUTABLE")
    end

    test "advertises ACP capabilities" do
      caps = ZCode.capabilities()

      assert caps["loadSession"] == true
      assert caps["promptCapabilities"]["image"] == false
      assert caps["mcpCapabilities"]["http"] == true
      assert caps["sessionCapabilities"]["list"] == %{}
      assert caps["sessionCapabilities"]["resume"] == %{}
      assert caps["sessionCapabilities"]["close"] == %{}
      assert caps["sessionCapabilities"]["fork"] == %{}
      refute Map.has_key?(caps["sessionCapabilities"], "delete")
      refute Map.has_key?(caps["sessionCapabilities"], "additionalDirectories")
      refute Map.has_key?(caps, "auth")
    end

    test "matches ZCode mode ids" do
      ids = ZCode.modes() |> Enum.map(& &1["id"])
      assert ids == ["plan", "build", "edit", "auto", "yolo"]
    end

    test "advertises ZCode auth methods" do
      methods = ZCode.auth_methods([])
      ids = Enum.map(methods, & &1["id"])
      assert "zcode-login" in ids
    end
  end

  describe "post_connect/1" do
    test "sends workspace/readState request", %{state: state} do
      {:ok, data, new_state} = ZCode.post_connect(state)
      msg = decode(data)

      assert msg["method"] == "workspace/readState"
      assert msg["id"] == 1

      assert msg["params"]["workspace"] == %{
               "workspacePath" => "/tmp",
               "workspaceKey" => "/tmp"
             }

      assert new_state.next_id == 2
      assert new_state.pending_requests[1].type == :workspace_read_state
    end
  end

  describe "session lifecycle outbound mapping" do
    test "session/new sends session/create with workspace and mode", %{state: state} do
      msg = %{
        "method" => "session/new",
        "id" => 1,
        "params" => %{"cwd" => "/tmp/project", "modeId" => "plan"}
      }

      assert {:ok, data, new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)

      assert zcode_msg["method"] == "session/create"

      assert zcode_msg["params"]["workspace"] == %{
               "workspacePath" => "/tmp/project",
               "workspaceKey" => "/tmp/project"
             }

      assert zcode_msg["params"]["mode"] == "plan"
      assert new_state.pending_requests[new_state.next_id - 1].type == :session_create
    end

    test "session/new defaults to build mode", %{state: state} do
      msg = %{
        "method" => "session/new",
        "id" => 1,
        "params" => %{"cwd" => "/tmp/project"}
      }

      assert {:ok, data, _state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)
      assert zcode_msg["params"]["mode"] == "build"
    end

    test "session/load sends session/resume + session/subscribe", %{state: state} do
      msg = %{
        "method" => "session/load",
        "id" => 1,
        "params" => %{"sessionId" => "sess-1", "cwd" => "/tmp/project"}
      }

      assert {:ok, data, new_state} = ZCode.translate_outbound(msg, state)
      [resume_msg, subscribe_msg] = decode_lines(data)

      assert resume_msg["method"] == "session/resume"
      assert resume_msg["params"]["sessionId"] == "sess-1"
      assert resume_msg["params"]["workspace"]["workspacePath"] == "/tmp/project"
      assert subscribe_msg["method"] == "session/subscribe"
      assert subscribe_msg["params"]["sessionId"] == "sess-1"

      # Both requests should be tracked
      assert new_state.pending_requests[resume_msg["id"]].type == :session_resume
      assert new_state.pending_requests[resume_msg["id"]].acp_id == 1
    end

    test "session/resume sends session/resume without replay", %{state: state} do
      msg = %{
        "method" => "session/resume",
        "id" => 1,
        "params" => %{"sessionId" => "sess-1", "cwd" => "/tmp/project"}
      }

      assert {:ok, data, _new_state} = ZCode.translate_outbound(msg, state)
      [resume_msg, subscribe_msg] = decode_lines(data)

      assert resume_msg["method"] == "session/resume"
      assert subscribe_msg["method"] == "session/subscribe"
    end

    test "session/close sends session/close", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      msg = %{"method" => "session/close", "params" => %{"sessionId" => "sess-1"}}

      assert {:reply_and_write, %{}, data, new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)
      assert zcode_msg["method"] == "session/close"
      assert zcode_msg["params"]["sessionId"] == "sess-1"
      refute Map.has_key?(new_state.sessions, "sess-1")
    end

    test "session/delete is not translated", %{state: state} do
      msg = %{"method" => "session/delete", "params" => %{"sessionId" => "sess-1"}}
      assert {:ok, :skip, ^state} = ZCode.translate_outbound(msg, state)
    end

    test "session/list sends session/list request", %{state: state} do
      msg = %{
        "method" => "session/list",
        "id" => 1,
        "params" => %{"cwd" => "/tmp/project", "limit" => 10}
      }

      assert {:ok, data, new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)

      assert zcode_msg["method"] == "session/list"

      assert zcode_msg["params"]["workspace"] == %{
               "workspacePath" => "/tmp/project",
               "workspaceKey" => "/tmp/project"
             }

      assert zcode_msg["params"]["limit"] == 10
      assert new_state.pending_requests[zcode_msg["id"]].acp_id == 1
    end
  end

  describe "workspace authorization" do
    test "rejects workspaces outside configured roots" do
      {:ok, state} = ZCode.init(cwd: "/safe", workspace_roots: ["/safe"])

      msg = %{
        "method" => "session/new",
        "id" => 1,
        "params" => %{"cwd" => "/etc"}
      }

      assert {:error, "Workspace path is not authorized", ^state} =
               ZCode.translate_outbound(msg, state)
    end

    test "allows workspaces inside configured roots" do
      {:ok, state} = ZCode.init(cwd: "/safe", workspace_roots: ["/safe"])

      msg = %{
        "method" => "session/new",
        "id" => 1,
        "params" => %{"cwd" => "/safe/project"}
      }

      assert {:ok, data, _state} = ZCode.translate_outbound(msg, state)
      assert decode(data)["params"]["workspace"]["workspacePath"] == "/safe/project"
    end

    test "rejects relative workspace paths", %{state: state} do
      msg = %{
        "method" => "session/new",
        "id" => 1,
        "params" => %{"cwd" => "relative/project"}
      }

      assert {:error, "Workspace paths must be absolute", ^state} =
               ZCode.translate_outbound(msg, state)
    end

    test "rejects unsupported additional directories", %{state: state} do
      msg = %{
        "method" => "session/new",
        "id" => 1,
        "params" => %{
          "cwd" => "/tmp/project",
          "additionalDirectories" => ["/tmp/other"]
        }
      }

      assert {:error, "ZCode does not support additionalDirectories", ^state} =
               ZCode.translate_outbound(msg, state)
    end
  end

  describe "prompt flow" do
    setup %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))
      %{state: state}
    end

    test "session/prompt sends session/send", %{state: state} do
      msg = %{
        "method" => "session/prompt",
        "id" => 1,
        "params" => %{"sessionId" => "sess-1", "prompt" => "Hello"}
      }

      assert {:ok, data, _new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)

      assert zcode_msg["method"] == "session/send"
      assert zcode_msg["params"]["sessionId"] == "sess-1"
      assert zcode_msg["params"]["content"] == "Hello"
    end

    test "session/prompt with content blocks extracts text", %{state: state} do
      msg = %{
        "method" => "session/prompt",
        "id" => 1,
        "params" => %{
          "sessionId" => "sess-1",
          "prompt" => [
            %{"type" => "text", "text" => "Hello "},
            %{"type" => "text", "text" => "world"}
          ]
        }
      }

      assert {:ok, data, _state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)
      assert zcode_msg["params"]["content"] == "Hello world"
    end

    test "session/prompt queues when one is active", %{state: state} do
      # Set up a session with an active prompt
      state =
        ZCode.Sessions.update(state, "sess-1", fn session ->
          %{session | active_prompt_acp_id: 1}
        end)

      msg = %{
        "method" => "session/prompt",
        "id" => 2,
        "params" => %{"sessionId" => "sess-1", "prompt" => "Second message"}
      }

      assert {:messages, messages, new_state} = ZCode.translate_outbound(msg, state)
      assert length(messages) == 2
      assert PromptQueue.len(new_state.prompt_queue) == 1
    end

    test "turn completion starts the next prompt queued for that session", %{state: state} do
      state =
        ZCode.Sessions.update(state, "sess-1", fn session ->
          %{session | active_prompt_acp_id: 1}
        end)

      prompt = %{
        "method" => "session/prompt",
        "id" => 2,
        "params" => %{"sessionId" => "sess-1", "prompt" => "Second message"}
      }

      assert {:messages, _messages, queued_state} = ZCode.translate_outbound(prompt, state)

      event =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "turn.completed",
            "sessionId" => "sess-1",
            "payload" => %{"resultType" => "success"}
          }
        })

      assert {:messages_and_write, messages, writes, completed_state} =
               ZCode.translate_inbound(event, queued_state)

      queued_request = writes |> IO.iodata_to_binary() |> decode()
      assert queued_request["method"] == "session/send"
      assert queued_request["params"]["content"] == "Second message"
      assert Enum.any?(messages, &(&1["id"] == 1))
      assert completed_state.sessions["sess-1"].active_prompt_acp_id == 2
      assert PromptQueue.empty?(completed_state.prompt_queue)
    end

    test "session/cancel sends session/stop", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      msg = %{"method" => "session/cancel", "params" => %{"sessionId" => "sess-1"}}

      assert {:ok, data, new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)

      assert zcode_msg["method"] == "session/stop"
      assert zcode_msg["params"]["sessionId"] == "sess-1"
      assert new_state.pending_requests[zcode_msg["id"]].type == :session_stop
    end
  end

  describe "config and mode" do
    test "session/set_mode sends session/setMode", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      msg = %{
        "method" => "session/set_mode",
        "id" => 40,
        "params" => %{"sessionId" => "sess-1", "modeId" => "auto"}
      }

      assert {:pending_and_write, data, new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)
      assert zcode_msg["method"] == "session/setMode"
      assert zcode_msg["params"]["mode"] == "auto"
      assert new_state.sessions["sess-1"].mode_id == "build"
      assert new_state.pending_requests[zcode_msg["id"]].acp_id == 40
    end

    test "session/set_model sends session/setModel with provider/model ref", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      msg = %{
        "method" => "session/set_model",
        "id" => 41,
        "params" => %{"sessionId" => "sess-1", "modelId" => "anthropic/claude-sonnet"}
      }

      assert {:pending_and_write, data, _new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)
      assert zcode_msg["method"] == "session/setModel"
      assert zcode_msg["params"]["model"]["providerId"] == "anthropic"
      assert zcode_msg["params"]["model"]["modelId"] == "claude-sonnet"
    end

    test "session/set_config_option mode routes to set_mode", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      msg = %{
        "method" => "session/set_config_option",
        "id" => 42,
        "params" => %{"sessionId" => "sess-1", "configId" => "mode", "value" => "edit"}
      }

      assert {:pending_and_write, data, _} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)
      assert zcode_msg["method"] == "session/setMode"
    end

    test "session/set_config_option thought_level sends setThoughtLevel", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      msg = %{
        "method" => "session/set_config_option",
        "id" => 43,
        "params" => %{"sessionId" => "sess-1", "configId" => "thought_level", "value" => "high"}
      }

      assert {:pending_and_write, data, new_state} = ZCode.translate_outbound(msg, state)
      zcode_msg = decode(data)
      assert zcode_msg["method"] == "session/setThoughtLevel"
      assert zcode_msg["params"]["thoughtLevel"] == "high"
      assert new_state.sessions["sess-1"].thought_level == "medium"
    end
  end

  describe "inbound response mapping" do
    test "workspace/readState response populates models and sets ready", %{state: state} do
      state = %{
        state
        | pending_requests: %{1 => %{type: :workspace_read_state, acp_id: nil, meta: %{}}}
      }

      line =
        Jason.encode!(%{
          "id" => 1,
          "result" => %{
            "modelCatalog" => %{
              "available" => [
                %{
                  "ref" => %{"providerId" => "anthropic", "modelId" => "claude-sonnet"},
                  "label" => "Sonnet"
                }
              ]
            }
          }
        })

      assert {:skip, new_state} = ZCode.translate_inbound(line, state)
      assert new_state.phase == :ready
      assert length(new_state.models) == 1
    end

    test "session/create response produces ACP session result and subscribes", %{state: state} do
      state = %{
        state
        | pending_requests: %{1 => %{type: :session_create, acp_id: 20, meta: %{}}}
      }

      line =
        Jason.encode!(%{
          "id" => 1,
          "result" => %{
            "session" => %{"sessionId" => "sess-abc", "workspace" => "/tmp/project"},
            "projection" => %{"mode" => "build", "status" => "idle"}
          }
        })

      assert {:messages_and_write, [response], writes, new_state} =
               ZCode.translate_inbound(line, state)

      assert response["result"]["sessionId"] == "sess-abc"
      # The write should be a session/subscribe request
      subscribe = writes |> to_string() |> String.trim() |> Jason.decode!()
      assert subscribe["method"] == "session/subscribe"
      assert subscribe["params"]["sessionId"] == "sess-abc"

      assert Map.has_key?(new_state.sessions, "sess-abc")
    end

    test "session/list response produces sessions list", %{state: state} do
      state = %{
        state
        | pending_requests: %{1 => %{type: :session_list, acp_id: 20, meta: %{}}}
      }

      line =
        Jason.encode!(%{
          "id" => 1,
          "result" => %{
            "sessions" => [
              %{"sessionId" => "sess-1", "workspace" => "/tmp/a", "title" => "Session A"}
            ]
          }
        })

      assert {:messages, [response], _state} = ZCode.translate_inbound(line, state)
      assert response["id"] == 20
      assert length(response["result"]["sessions"]) == 1
      assert hd(response["result"]["sessions"])["sessionId"] == "sess-1"
    end
  end

  describe "inbound event mapping" do
    test "turn.completed synthesizes prompt response", %{state: state} do
      state =
        state
        |> ZCode.Sessions.put("sess-1", ZCode.Sessions.empty("sess-1", state))
        |> ZCode.Sessions.update("sess-1", fn session ->
          %{session | active_prompt_acp_id: 42}
        end)

      line =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "turn.completed",
            "sessionId" => "sess-1",
            "payload" => %{
              "resultType" => "success",
              "usage" => %{"inputTokens" => 100, "outputTokens" => 50}
            }
          }
        })

      assert {:messages, messages, _state} = ZCode.translate_inbound(line, state)

      # Should contain a prompt response with stopReason end_turn
      response = Enum.find(messages, &(&1["id"] == 42))
      assert response != nil
      assert response["result"]["stopReason"] == "end_turn"
      assert response["result"]["usage"]["inputTokens"] == 100
    end

    test "turn.completed with cancelled resultType maps to cancelled", %{state: state} do
      state =
        state
        |> ZCode.Sessions.put("sess-1", ZCode.Sessions.empty("sess-1", state))
        |> ZCode.Sessions.update("sess-1", fn session ->
          %{session | active_prompt_acp_id: 42}
        end)

      line =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "turn.completed",
            "sessionId" => "sess-1",
            "payload" => %{"resultType" => "cancelled"}
          }
        })

      assert {:messages, messages, _} = ZCode.translate_inbound(line, state)
      response = Enum.find(messages, &(&1["id"] == 42))
      assert response["result"]["stopReason"] == "cancelled"
    end

    test "part.delta with text field produces agent_message_chunk", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      line =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "part.delta",
            "sessionId" => "sess-1",
            "payload" => %{"field" => "text", "delta" => "Hello world"}
          }
        })

      assert {:messages, [msg], _state} = ZCode.translate_inbound(line, state)

      update = msg["params"]["update"]
      assert update["sessionUpdate"] == "agent_message_chunk"
      assert update["content"]["text"] == "Hello world"
    end

    test "part.delta with reasoning field produces agent_thought_chunk", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      line =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "part.delta",
            "sessionId" => "sess-1",
            "payload" => %{"field" => "reasoning", "delta" => "Thinking..."}
          }
        })

      assert {:messages, [msg], _state} = ZCode.translate_inbound(line, state)
      update = msg["params"]["update"]
      assert update["sessionUpdate"] == "agent_thought_chunk"
    end

    test "tool.updated scheduled produces tool_call", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      line =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "tool.updated",
            "sessionId" => "sess-1",
            "payload" => %{
              "kind" => "scheduled",
              "toolCallId" => "tc-1",
              "toolName" => "Bash",
              "input" => %{"command" => "ls"}
            }
          }
        })

      assert {:messages, [msg], _state} = ZCode.translate_inbound(line, state)
      update = msg["params"]["update"]
      assert update["sessionUpdate"] == "tool_call"
      assert update["toolCallId"] == "tc-1"
      assert update["status"] == "pending"
    end

    test "tool.updated result produces tool_call_update completed", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      line =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "tool.updated",
            "sessionId" => "sess-1",
            "payload" => %{
              "kind" => "result",
              "toolCallId" => "tc-1",
              "result" => %{"display" => %{"text" => "output"}}
            }
          }
        })

      assert {:messages, [msg], _state} = ZCode.translate_inbound(line, state)
      update = msg["params"]["update"]
      assert update["sessionUpdate"] == "tool_call_update"
      assert update["status"] == "completed"
    end

    test "tool.updated preserves structured result lists", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))
      result = [%{"type" => "text", "text" => "output"}]

      line =
        Jason.encode!(%{
          "method" => "session/event",
          "params" => %{
            "type" => "tool.updated",
            "sessionId" => "sess-1",
            "payload" => %{
              "kind" => "result",
              "toolCallId" => "tc-1",
              "result" => result
            }
          }
        })

      assert {:messages, [msg], _state} = ZCode.translate_inbound(line, state)
      assert msg["params"]["update"]["rawOutput"] == result
    end
  end

  describe "permission bridging" do
    test "requestPermission server request emits ACP permission request", %{state: state} do
      state = ZCode.Sessions.put(state, "sess-1", ZCode.Sessions.empty("sess-1", state))

      line =
        Jason.encode!(%{
          "id" => "server-1",
          "method" => "interaction/requestPermission",
          "params" => %{
            "toolCallId" => "tc-1",
            "toolName" => "Bash",
            "input" => %{"command" => "rm -rf /"},
            "riskLevel" => "critical",
            "reason" => "Destructive command",
            "options" => [
              %{
                "optionId" => "allow_once",
                "kind" => "allow",
                "name" => "Allow once",
                "response" => %{"decision" => "allow"}
              },
              %{
                "optionId" => "deny",
                "kind" => "deny",
                "name" => "Deny",
                "response" => %{"decision" => "deny"}
              }
            ]
          }
        })

      assert {:messages, messages, new_state} = ZCode.translate_inbound(line, state)

      # Should contain an ACP permission request
      permission_req = Enum.find(messages, &(&1["method"] == "session/request_permission"))
      assert permission_req != nil
      assert permission_req["params"]["toolCall"]["toolCallId"] == "tc-1"
      assert length(permission_req["params"]["options"]) == 2

      # The pending client request should be tracked
      acp_id = permission_req["id"]
      assert new_state.pending_client_requests[acp_id].zcode_id == "server-1"
    end

    test "ACP permission response maps back to ZCode response", %{state: state} do
      acp_id = "zcode-permission-1"

      state = %{
        state
        | pending_client_requests: %{
            acp_id => %{
              zcode_id: "server-1",
              kind: :permission,
              request: %{
                "options" => [
                  %{
                    "optionId" => "allow_once",
                    "response" => %{"decision" => "allow"}
                  }
                ]
              }
            }
          }
      }

      msg = %{
        "id" => acp_id,
        "result" => %{"outcome" => "selected", "optionId" => "allow_once"}
      }

      assert {:ok, data, new_state} = ZCode.translate_outbound(msg, state)
      zcode_response = decode(data)
      assert zcode_response["id"] == "server-1"
      assert zcode_response["result"]["decision"] == "allow"
      refute Map.has_key?(new_state.pending_client_requests, acp_id)
    end
  end

  describe "auto-responded server requests" do
    test "requestRuntimePreferences gets default response", %{state: state} do
      line =
        Jason.encode!(%{
          "id" => "server-1",
          "method" => "session/requestRuntimePreferences",
          "params" => %{}
        })

      assert {:skip_and_write, data, _state} = ZCode.translate_inbound(line, state)
      response = data |> to_string() |> String.trim() |> Jason.decode!()
      assert response["id"] == "server-1"
      assert response["result"]["memoryEnabled"] == false
    end

    test "requestUserInput gets cancelled response", %{state: state} do
      line =
        Jason.encode!(%{
          "id" => "server-1",
          "method" => "interaction/requestUserInput",
          "params" => %{}
        })

      assert {:skip_and_write, data, _state} = ZCode.translate_inbound(line, state)
      response = data |> to_string() |> String.trim() |> Jason.decode!()
      assert response["result"]["cancelled"] == true
    end
  end

  describe "non-JSON and empty lines" do
    test "empty line is skipped", %{state: state} do
      assert {:skip, ^state} = ZCode.translate_inbound("", state)
    end

    test "non-JSON line is skipped", %{state: state} do
      assert {:skip, ^state} = ZCode.translate_inbound("not json at all", state)
    end
  end
end
