defmodule ExMCP.ACP.Adapters.ClaudeSDKTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import ExMCP.TestHelpers, only: [wait_until: 1]

  alias ExMCP.ACP.AdapterBridge
  alias ExMCP.ACP.Adapters.ClaudeSDK
  alias ExMCP.ACP.Adapters.ClaudeSDK.Mapper
  alias ExMCP.ACP.Adapters.ClaudeSDK.SessionStore
  alias ExMCP.ACP.Capabilities
  alias ExMCP.ACP.PromptQueue

  setup do
    {:ok, state} = ClaudeSDK.init(cwd: "/tmp/project", model: "sonnet")
    %{state: state}
  end

  describe "command/1 and env/1" do
    test "uses SDK-compatible Claude Code flags by default" do
      {cmd, args} = ClaudeSDK.command([])

      assert cmd == "claude"
      assert ["--output-format", "stream-json"] = Enum.slice(args, 0, 2)
      assert "--input-format" in args
      assert "--verbose" in args
      assert "--permission-prompt-tool" in args
      assert "stdio" in args
      assert "--include-partial-messages" in args
      assert "--permission-mode" in args
      assert "default" in args
    end

    test "exposes SDK entrypoint env" do
      assert ClaudeSDK.env([]) == %{
               "CLAUDE_CODE_ENTRYPOINT" => "sdk-ts",
               "CLAUDE_AGENT_SDK_VERSION" => "0.3.238"
             }
    end

    test "passes session and mcp options through to Claude Code" do
      {_cmd, args} =
        ClaudeSDK.command(
          model: "opus",
          additional_directories: ["/tmp/shared"],
          mcp_servers: %{"docs" => %{"command" => "docs-mcp"}},
          resume: "sess_1"
        )

      assert "--model" in args
      assert "opus" in args
      assert "--add-dir" in args
      assert "/tmp/shared" in args
      assert [config] = mcp_config_values(args)
      assert %{"mcpServers" => %{"docs" => _}} = config |> File.read!() |> Jason.decode!()
      assert "--resume" in args
      assert "sess_1" in args
    end

    test "bypass permission mode requires the explicit dangerous opt-in flag" do
      {_cmd, args} = ClaudeSDK.command(permission_mode: :bypass)

      assert "--permission-mode" in args
      assert "bypassPermissions" in args
      assert "--allow-dangerously-skip-permissions" in args
    end
  end

  describe "capabilities/0" do
    test "advertises disk-backed session store operations" do
      capabilities = ClaudeSDK.capabilities()
      session_capabilities = capabilities["sessionCapabilities"]

      assert Map.has_key?(session_capabilities, "list")
      assert Map.has_key?(session_capabilities, "delete")
      assert Map.has_key?(session_capabilities, "resume")
      assert Map.has_key?(session_capabilities, "close")
      assert Map.has_key?(session_capabilities, "fork")
      assert capabilities["auth"]["logout"] == %{}
    end

    # Claude Code takes MCP servers only at launch, so no session-supplied
    # transport is advertised, not even ExMCP's BEAM one.
    test "advertises no session MCP transports" do
      mcp = ClaudeSDK.capabilities()["mcpCapabilities"]

      assert mcp["acp"] == false
      assert mcp["http"] == false
      assert mcp["sse"] == false
      assert get_in(mcp, ["_meta", "ex_mcp", "claude_sdk", "sessionMcpServers"]) == false
      refute Capabilities.supported?(ClaudeSDK.capabilities(), :mcp_beam)
    end
  end

  describe "MCP servers" do
    @describetag :tmp_dir

    test "writes :mcp_servers to a private file, keeping it off the command line" do
      {_cmd, args} =
        ClaudeSDK.command(
          mcp_servers: %{
            "api" => %{
              "type" => "http",
              "url" => "https://mcp.example.test/",
              "headers" => %{"Authorization" => "Bearer secret-token"}
            }
          }
        )

      refute Enum.any?(args, &String.contains?(&1, "secret-token"))
      assert [path] = mcp_config_values(args)
      assert Path.type(path) == :absolute

      assert %{"mcpServers" => %{"api" => %{"headers" => headers}}} =
               path |> File.read!() |> Jason.decode!()

      assert headers == %{"Authorization" => "Bearer secret-token"}
      assert permissions(path) == 0o600
      assert permissions(Path.dirname(path)) == 0o700
    end

    test "removes the file once the process that built the command exits" do
      test_pid = self()

      {owner, owner_ref} =
        spawn_monitor(fn ->
          {_cmd, args} = ClaudeSDK.command(mcp_servers: %{"docs" => %{"command" => "docs-mcp"}})
          send(test_pid, {:config, hd(mcp_config_values(args))})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:config, path}, 1_000
      assert File.exists?(path)

      send(owner, :stop)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
      wait_until(fn -> not File.exists?(Path.dirname(path)) end)
    end

    test "the file lives as long as the adapter bridge that launched Claude Code", %{
      tmp_dir: tmp_dir
    } do
      argv_file = Path.join(tmp_dir, "argv")
      cli = Path.join(tmp_dir, "claude")

      # Records its arguments, then waits for stdin to close like Claude Code.
      File.write!(cli, """
      #!/bin/sh
      for arg in "$@"; do printf '%s\\n' "$arg"; done > "#{argv_file}.tmp"
      mv "#{argv_file}.tmp" "#{argv_file}"
      while read -r _line; do :; done
      """)

      File.chmod!(cli, 0o755)

      {:ok, bridge} =
        AdapterBridge.start_link(
          adapter: ClaudeSDK,
          adapter_opts: [
            cli_path: cli,
            cwd: tmp_dir,
            mcp_servers: %{"docs" => %{"command" => "docs-mcp"}}
          ]
        )

      wait_until(fn -> File.exists?(argv_file) end)

      assert [path] =
               argv_file |> File.read!() |> String.split("\n", trim: true) |> mcp_config_values()

      assert File.exists?(path)

      AdapterBridge.close(bridge)
      wait_until(fn -> not File.exists?(Path.dirname(path)) end)
    end

    test "passes :mcp_config_path through as a path", %{tmp_dir: tmp_dir} do
      config = Path.join(tmp_dir, "mcp.json")
      File.write!(config, ~s({"mcpServers": {}}))

      {_cmd, args} = ClaudeSDK.command(mcp_config_path: config)
      assert mcp_config_values(args) == [config]

      # A relative path is resolved against the directory Claude Code runs in.
      {_cmd, args} = ClaudeSDK.command(mcp_config_path: "mcp.json", cwd: tmp_dir)
      assert mcp_config_values(args) == [config]
    end

    test "combines config paths with :mcp_servers, caller's files first", %{tmp_dir: tmp_dir} do
      first = Path.join(tmp_dir, "first.json")
      second = Path.join(tmp_dir, "second.json")
      Enum.each([first, second], &File.write!(&1, ~s({"mcpServers": {}})))

      {_cmd, args} =
        ClaudeSDK.command(
          mcp_config_path: [first, second],
          mcp_servers: %{"docs" => %{"command" => "docs-mcp"}}
        )

      assert [^first, ^second, generated] = mcp_config_values(args)
      assert %{"mcpServers" => %{"docs" => _}} = generated |> File.read!() |> Jason.decode!()
    end

    test "rejects an ACP-style server list without echoing it" do
      acp_servers = [
        %{
          "type" => "http",
          "name" => "api",
          "url" => "https://mcp.example.test/",
          "headers" => [%{"name" => "Authorization", "value" => "Bearer secret-token"}]
        }
      ]

      assert {:error, {:invalid_option, :mcp_servers, message}} =
               ClaudeSDK.command(mcp_servers: acp_servers)

      assert message =~ "got a list"
      assert message =~ "ACP-style"
      refute message =~ "secret-token"
    end

    test "rejects other :mcp_servers shapes without echoing them" do
      for servers <- [
            ~s({"mcpServers": {"api": {"headers": {"Authorization": "Bearer secret-token"}}}}),
            %{"api" => "Bearer secret-token"},
            %{"api" => %{"headers" => %{"Authorization" => {:bearer, "secret-token"}}}},
            %{:api => %{"url" => "x"}, "api" => %{"url" => "secret-token"}}
          ] do
        assert {:error, {:invalid_option, :mcp_servers, message}} =
                 ClaudeSDK.command(mcp_servers: servers)

        refute message =~ "secret-token"
      end
    end

    test "rejects a :mcp_config_path that is not an existing file", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "missing.json")

      assert {:error, {:invalid_option, :mcp_config_path, message}} =
               ClaudeSDK.command(mcp_config_path: missing)

      assert message =~ "missing.json"

      assert {:error, {:invalid_option, :mcp_config_path, _}} =
               ClaudeSDK.command(mcp_config_path: tmp_dir)

      assert {:error, {:invalid_option, :mcp_config_path, _}} =
               ClaudeSDK.command(mcp_config_path: 42)
    end

    test "the bridge refuses to start on invalid MCP options" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_option, :mcp_servers, _message}} =
               AdapterBridge.start_link(
                 adapter: ClaudeSDK,
                 adapter_opts: [mcp_servers: [%{"name" => "docs", "command" => "/bin/docs"}]]
               )
    end
  end

  describe "session mcpServers" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      %{opts: [cwd: tmp_dir, claude_config_dir: Path.join(tmp_dir, "claude")]}
    end

    test "session/new warns that servers the launch did not configure are not attached", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      {:ok, state} = ClaudeSDK.init(opts)

      log =
        capture_log(fn ->
          assert {:reply, %{"sessionId" => _}, _state} =
                   ClaudeSDK.translate_outbound(
                     session_request("session/new", tmp_dir, ["docs", "api"]),
                     state
                   )
        end)

      assert log =~ "session/new"
      assert log =~ ~s(["docs", "api"])
      assert log =~ "not attached"
      assert log =~ ":mcp_config_path"
    end

    test "names only the servers missing from :mcp_servers", %{opts: opts, tmp_dir: tmp_dir} do
      {:ok, state} = ClaudeSDK.init([mcp_servers: %{docs: %{"command" => "docs-mcp"}}] ++ opts)

      log =
        capture_log(fn ->
          ClaudeSDK.translate_outbound(
            session_request("session/new", tmp_dir, ["docs", "api"]),
            state
          )
        end)

      assert log =~ ~s(["api"])
      refute log =~ ~s("docs")
    end

    test "stays quiet when the launch configured every server, or has a config file", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      config = Path.join(tmp_dir, "mcp.json")
      File.write!(config, ~s({"mcpServers": {}}))

      for launch <- [
            [mcp_servers: %{"docs" => %{"command" => "docs-mcp"}}],
            [mcp_config_path: config],
            []
          ] do
        {:ok, state} = ClaudeSDK.init(launch ++ opts)
        requested = if launch == [], do: [], else: ["docs"]

        assert capture_log(fn ->
                 ClaudeSDK.translate_outbound(
                   session_request("session/new", tmp_dir, requested),
                   state
                 )
               end) == ""
      end
    end

    test "session/load, session/resume and session/fork warn too", %{
      opts: opts,
      tmp_dir: tmp_dir
    } do
      {:ok, state} = ClaudeSDK.init(opts)

      for method <- ["session/load", "session/resume"] do
        log =
          capture_log(fn ->
            ClaudeSDK.translate_outbound(session_request(method, tmp_dir, ["docs"]), state)
          end)

        assert log =~ method
        assert log =~ ~s(["docs"])
      end

      %{"params" => params} = session_request("session/fork", tmp_dir, ["docs"])
      log = capture_log(fn -> ClaudeSDK.fork_session(params, state) end)
      assert log =~ "session/fork"
    end
  end

  describe "post_connect/1" do
    test "sends SDK initialize control request", %{state: state} do
      assert {:ok, line, state} = ClaudeSDK.post_connect(state)
      decoded = Jason.decode!(line)

      assert decoded["type"] == "control_request"
      assert decoded["request"]["subtype"] == "initialize"
      assert Map.has_key?(state.pending_controls, decoded["request_id"])
    end

    test "captures client capabilities for initialize-dependent auth methods", %{state: state} do
      msg = %{
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "clientCapabilities" => %{
            "auth" => %{"terminal" => true, "_meta" => %{"gateway" => true}},
            "_meta" => %{"terminal-auth" => true}
          }
        }
      }

      assert {:ok, :skip, state} = ClaudeSDK.translate_outbound(msg, state)
      ids = ClaudeSDK.auth_methods([gateway_auth: true], state) |> Enum.map(& &1["id"])

      assert "claude-ai-login" in ids
      assert "console-login" in ids
      assert "gateway" in ids
      assert "gateway-bedrock" in ids

      console =
        Enum.find(
          ClaudeSDK.auth_methods([gateway_auth: true], state),
          &(&1["id"] == "console-login")
        )

      assert get_in(console, ["_meta", "terminal-auth", "command"]) == "claude"
    end
  end

  describe "session lifecycle" do
    test "session/new returns adapter-provided session setup", %{state: state} do
      msg = %{
        "id" => 1,
        "method" => "session/new",
        "params" => %{"cwd" => "/tmp/project"}
      }

      assert {:reply, result, state} = ClaudeSDK.translate_outbound(msg, state)

      assert result["sessionId"] == state.session_id
      assert result["modes"]["currentModeId"] == "default"
      assert Enum.any?(result["configOptions"], &(&1["id"] == "model"))
    end

    test "session/new honours the host's opt-out of bypassPermissions", %{state: state} do
      {:ok, allowing} =
        ClaudeSDK.init(
          cwd: "/tmp/project",
          model: "sonnet",
          allow_dangerously_skip_permissions: true
        )

      opted_out = %{
        "id" => 1,
        "method" => "session/new",
        "params" => %{
          "cwd" => "/tmp/project",
          "_meta" => %{
            "claudeCode" => %{"options" => %{"allowDangerouslySkipPermissions" => false}}
          }
        }
      }

      assert {:reply, result, state_out} = ClaudeSDK.translate_outbound(opted_out, allowing)
      refute Enum.any?(result["modes"]["availableModes"], &(&1["id"] == "bypassPermissions"))
      assert state_out.bypass_allowed? == false

      set_mode = %{
        "id" => 2,
        "method" => "session/set_mode",
        "params" => %{"sessionId" => state_out.session_id, "modeId" => "bypassPermissions"}
      }

      assert {:error, "Unsupported Claude permission mode: bypassPermissions", _state} =
               ClaudeSDK.translate_outbound(set_mode, state_out)

      # Without the meta the adapter option still offers the mode.
      plain = %{"id" => 3, "method" => "session/new", "params" => %{"cwd" => "/tmp/project"}}
      assert {:reply, result, _state} = ClaudeSDK.translate_outbound(plain, allowing)
      assert Enum.any?(result["modes"]["availableModes"], &(&1["id"] == "bypassPermissions"))

      # `true` cannot switch bypass on for an adapter that did not allow it.
      forced =
        put_in(
          opted_out,
          ["params", "_meta", "claudeCode", "options", "allowDangerouslySkipPermissions"],
          true
        )

      assert {:reply, result, _state} = ClaudeSDK.translate_outbound(forced, state)
      refute Enum.any?(result["modes"]["availableModes"], &(&1["id"] == "bypassPermissions"))
    end

    test "opting out clamps an active bypassPermissions mode back to default", %{state: state} do
      state = %{state | permission_mode: "bypassPermissions"}

      msg = %{
        "id" => 1,
        "method" => "session/new",
        "params" => %{
          "cwd" => "/tmp/project",
          "_meta" => %{
            "claudeCode" => %{"options" => %{"allowDangerouslySkipPermissions" => false}}
          }
        }
      }

      assert {:reply_and_write, result, data, state_out} =
               ClaudeSDK.translate_outbound(msg, state)

      assert result["modes"]["currentModeId"] == "default"
      refute Enum.any?(result["modes"]["availableModes"], &(&1["id"] == "bypassPermissions"))
      assert state_out.permission_mode == "default"

      control = data |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert control["request"]["subtype"] == "set_permission_mode"
      assert control["request"]["mode"] == "default"
      assert Map.values(state_out.pending_controls) |> Enum.member?(:set_permission_mode)
    end

    test "session/resume applies the opt-out the same way", %{state: state} do
      state = %{state | permission_mode: "bypassPermissions"}

      msg = %{
        "id" => 1,
        "method" => "session/resume",
        "params" => %{
          "sessionId" => "claude_sdk_7",
          "_meta" => %{
            "claudeCode" => %{"options" => %{"allowDangerouslySkipPermissions" => false}}
          }
        }
      }

      assert {:reply_and_write, result, _data, state_out} =
               ClaudeSDK.translate_outbound(msg, state)

      assert result["modes"]["currentModeId"] == "default"
      assert state_out.bypass_allowed? == false
    end

    test "session/close clears both ACP and provider session identities", %{state: state} do
      state = %{
        state
        | session_id: "claude_sdk_7",
          claude_session_id: "0ab10f45-9463-42ad-9733-a5b07089e47f"
      }

      msg = %{
        "id" => 2,
        "method" => "session/close",
        "params" => %{"sessionId" => "claude_sdk_7"}
      }

      assert {:reply, %{}, state} = ClaudeSDK.translate_outbound(msg, state)
      assert state.session_id == nil
      assert state.claude_session_id == nil
    end

    test "session/list reads Claude SDK sessions from disk" do
      {config_dir, cwd, session_id} = write_store_fixture("list me")
      {:ok, state} = ClaudeSDK.init(cwd: cwd, claude_config_dir: config_dir)

      assert {:ok, [session], _state} = ClaudeSDK.list_sessions(%{"cwd" => cwd}, state)
      assert session["sessionId"] == session_id
      assert session["cwd"] == cwd
      assert session["title"] == "list me"
    end

    test "session/delete removes Claude SDK sessions from disk" do
      {config_dir, cwd, session_id} = write_store_fixture("delete me")

      {:ok, state} =
        ClaudeSDK.init(cwd: cwd, claude_config_dir: config_dir, session_id: session_id)

      msg = %{
        "id" => 11,
        "method" => "session/delete",
        "params" => %{"sessionId" => session_id, "cwd" => cwd}
      }

      assert {:reply, %{}, state} = ClaudeSDK.translate_outbound(msg, state)
      assert state.session_id == nil
      assert state.claude_session_id == nil
      assert {:ok, [], _state} = ClaudeSDK.list_sessions(%{"cwd" => cwd}, state)
    end

    test "session/load replays persisted transcript before replying" do
      {config_dir, cwd, session_id} =
        write_store_fixture([
          %{
            "type" => "user",
            "uuid" => "user-1",
            "cwd" => cwd_placeholder(),
            "message" => %{"role" => "user", "content" => "hello"}
          },
          %{
            "type" => "assistant",
            "uuid" => "assistant-1",
            "session_id" => session_id_placeholder(),
            "message" => %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "hi there"}]
            }
          }
        ])

      {:ok, state} = ClaudeSDK.init(cwd: cwd, claude_config_dir: config_dir)

      msg = %{
        "id" => 12,
        "method" => "session/load",
        "params" => %{"sessionId" => session_id, "cwd" => cwd}
      }

      assert {:messages_and_reply, messages, result, state} =
               ClaudeSDK.translate_outbound(msg, state)

      assert result["sessionId"] == session_id

      updates = Enum.map(messages, &get_in(&1, ["params", "update", "sessionUpdate"]))
      assert "user_message_chunk" in updates
      assert "agent_message_chunk" in updates
      assert Map.has_key?(state.message_ids, "user-1")
    end

    test "session/fork copies persisted transcript and returns a new session id" do
      {config_dir, cwd, session_id} = write_store_fixture("fork me")
      {:ok, state} = ClaudeSDK.init(cwd: cwd, claude_config_dir: config_dir)

      assert {:ok, result, state} =
               ClaudeSDK.fork_session(%{"sessionId" => session_id, "cwd" => cwd}, state)

      forked_id = result["sessionId"]
      assert forked_id != session_id
      assert state.session_id == forked_id

      assert {:ok, [_entry]} =
               SessionStore.read_session_messages(forked_id,
                 claude_config_dir: config_dir,
                 cwd: cwd
               )
    end

    test "session/cancel writes SDK interrupt control request", %{state: state} do
      msg = %{"method" => "session/cancel", "params" => %{"sessionId" => "s1"}}

      assert {:ok, line, state} = ClaudeSDK.translate_outbound(msg, state)
      decoded = Jason.decode!(line)

      assert decoded["type"] == "control_request"
      assert decoded["request"]["subtype"] == "interrupt"
      assert Map.has_key?(state.pending_controls, decoded["request_id"])
    end

    test "logout clears adapter auth state without CLI side effects when disabled", %{
      state: state
    } do
      state = %{state | gateway_auth: %{"methodId" => "gateway"}, opts: [logout_cli: false]}
      msg = %{"id" => 14, "method" => "logout", "params" => %{}}

      assert {:reply, %{}, state} = ClaudeSDK.translate_outbound(msg, state)
      assert state.gateway_auth == nil
    end
  end

  describe "prompt translation" do
    test "converts ACP prompt blocks into SDK user message", %{state: state} do
      msg = %{
        "id" => 10,
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [
            %{"type" => "text", "text" => "hello"},
            %{"type" => "text", "text" => "/mcp:docs:search query"},
            %{"type" => "resource_link", "uri" => "file:///tmp/project/lib/a.ex"},
            %{
              "type" => "resource",
              "resource" => %{
                "uri" => "file:///tmp/project/README.md",
                "text" => "project docs"
              }
            },
            %{"type" => "image", "uri" => "https://example.test/image.png"}
          ]
        }
      }

      assert {:ok, line, state} = ClaudeSDK.translate_outbound(msg, state)
      decoded = Jason.decode!(line)

      assert decoded["type"] == "user"
      assert decoded["session_id"] == "s1"
      assert get_in(decoded, ["message", "content", Access.at(0), "text"]) == "hello"

      assert get_in(decoded, ["message", "content", Access.at(1), "text"]) ==
               "/docs:search (MCP) query"

      assert get_in(decoded, ["message", "content", Access.at(2), "text"]) ==
               "[@a.ex](file:///tmp/project/lib/a.ex)"

      assert get_in(decoded, ["message", "content", Access.at(3), "text"]) ==
               "[@README.md](file:///tmp/project/README.md)"

      assert get_in(decoded, ["message", "content", Access.at(4), "source", "type"]) == "url"

      assert get_in(decoded, ["message", "content", Access.at(5), "text"]) =~
               ~s(<context ref="file:///tmp/project/README.md">)

      assert state.pending_prompt_id == 10
    end

    test "queues a prompt while another prompt is active and drains it after result", %{
      state: state
    } do
      first = %{
        "id" => 10,
        "method" => "session/prompt",
        "params" => %{"sessionId" => "s1", "prompt" => [%{"type" => "text", "text" => "one"}]}
      }

      second = %{
        "id" => 11,
        "method" => "session/prompt",
        "params" => %{"sessionId" => "s1", "prompt" => [%{"type" => "text", "text" => "two"}]}
      }

      assert {:ok, _line, state} = ClaudeSDK.translate_outbound(first, state)
      assert {:ok, :skip, state} = ClaudeSDK.translate_outbound(second, state)
      assert PromptQueue.len(state.prompt_queue) == 1

      result = %{
        "type" => "result",
        "session_id" => "s1",
        "stop_reason" => "end_turn",
        "usage" => %{},
        "result" => "done"
      }

      assert {:messages_and_write, messages, [write], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(result), state)

      assert Enum.any?(messages, &(&1["id"] == 10))
      assert Jason.decode!(write)["message"]["content"] == [%{"type" => "text", "text" => "two"}]
      assert state.pending_prompt_id == 11
      assert PromptQueue.empty?(state.prompt_queue)
    end
  end

  describe "permission control bridge" do
    test "maps SDK can_use_tool request to ACP permission request and response", %{state: state} do
      event = %{
        "type" => "control_request",
        "request_id" => "perm_1",
        "request" => %{
          "subtype" => "can_use_tool",
          "tool_name" => "Bash",
          "tool_use_id" => "toolu_1",
          "input" => %{"command" => "mix test"},
          "decision_reason" => "command needs approval"
        }
      }

      assert {:messages, [tool_call, permission], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      assert get_in(tool_call, ["params", "update", "sessionUpdate"]) == "tool_call"
      assert get_in(tool_call, ["params", "update", "status"]) == "pending"
      assert permission["method"] == "session/request_permission"
      assert permission["params"]["toolCall"]["toolCallId"] == "toolu_1"
      assert Enum.any?(permission["params"]["options"], &(&1["kind"] == "allow_once"))

      response = %{
        "id" => permission["id"],
        "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
      }

      assert {:ok, line, _state} = ClaudeSDK.translate_outbound(response, state)
      decoded = Jason.decode!(line)

      assert decoded["type"] == "control_response"
      assert decoded["response"]["request_id"] == "perm_1"
      assert decoded["response"]["response"]["behavior"] == "allow"
    end
  end

  describe "runtime config controls" do
    test "advertises upstream config ids and applies fast and agent settings", %{state: state} do
      state = %{
        state
        | available_models: [
            %{
              "value" => "sonnet",
              "displayName" => "Claude Sonnet",
              "supportsFastMode" => true
            }
          ],
          available_agents: [%{"name" => "reviewer", "description" => "Review code"}],
          client_capabilities: %{"session" => %{"configOptions" => %{"boolean" => %{}}}}
      }

      ids = Mapper.config_options(state) |> Enum.map(& &1["id"])

      assert "mode" in ids
      assert "model" in ids
      assert "fast" in ids
      assert "agent" in ids
      refute "permission_mode" in ids

      fast = %{
        "id" => 30,
        "method" => "session/set_config_option",
        "params" => %{"sessionId" => "s1", "configId" => "fast", "value" => true}
      }

      assert {:reply_and_write, %{"configOptions" => _}, line, state} =
               ClaudeSDK.translate_outbound(fast, state)

      decoded = Jason.decode!(line)
      assert decoded["request"]["subtype"] == "apply_flag_settings"
      assert decoded["request"]["settings"] == %{"fastMode" => true}
      assert state.fast_mode_enabled == true

      agent = %{
        "id" => 31,
        "method" => "session/set_config_option",
        "params" => %{"sessionId" => "s1", "configId" => "agent", "value" => "reviewer"}
      }

      assert {:reply_and_write, %{"configOptions" => _}, line, state} =
               ClaudeSDK.translate_outbound(agent, state)

      decoded = Jason.decode!(line)
      assert decoded["request"]["settings"] == %{"agent" => "reviewer"}
      assert state.current_agent == "reviewer"
    end
  end

  describe "SDK event mapping" do
    test "regression: updates keep the ACP session id even when the CLI reports its own UUID",
         %{state: state} do
      # Claude Code 2.1.x stamps every stream-json event with the UUID it
      # minted for the process. The adapter used to adopt that UUID as
      # `state.session_id`, so every session/update went out under an id the
      # ACP client never saw from session/new and was dropped as "unknown
      # session" — the turn came back empty.
      request = %{
        "id" => 7,
        "method" => "session/new",
        "params" => %{"cwd" => "/tmp/project"}
      }

      assert {:reply, %{"sessionId" => acp_id}, state} =
               ClaudeSDK.translate_outbound(request, state)

      prompt = %{
        "id" => 8,
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => acp_id,
          "prompt" => [%{"type" => "text", "text" => "Say ready"}]
        }
      }

      assert {:ok, _line, state} = ClaudeSDK.translate_outbound(prompt, state)

      cli_uuid = "496377d0-00a4-4627-ad73-06a13d682836"
      refute acp_id == cli_uuid

      init = %{
        "type" => "system",
        "subtype" => "init",
        "session_id" => cli_uuid,
        "cwd" => "/tmp/project",
        "model" => "claude-opus-4-8",
        "tools" => []
      }

      assert {:messages, init_messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(init), state)

      for message <- init_messages, message["method"] == "session/update" do
        assert message["params"]["sessionId"] == acp_id
      end

      init_info =
        Enum.find(init_messages, fn message ->
          get_in(message, ["params", "update", "sessionUpdate"]) == "session_info_update"
        end)

      assert get_in(init_info, [
               "params",
               "update",
               "_meta",
               "ex_mcp",
               "claude_sdk",
               "sessionId"
             ]) == cli_uuid

      assistant = %{
        "type" => "assistant",
        "session_id" => cli_uuid,
        "message" => %{
          "model" => "claude-opus-4-8",
          "content" => [%{"type" => "text", "text" => "ready"}]
        }
      }

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(assistant), state)

      assert [message | _] = messages
      assert message["method"] == "session/update"
      assert message["params"]["sessionId"] == acp_id
      assert state.session_id == acp_id
      assert state.claude_session_id == cli_uuid

      result = %{
        "type" => "result",
        "subtype" => "success",
        "session_id" => cli_uuid,
        "result" => "ready",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 2},
        "modelUsage" => %{
          "claude-opus-4-8" => %{"contextWindow" => 200_000}
        }
      }

      assert {:messages, result_messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(result), state)

      assert_update_session_ids(result_messages, acp_id)
      response = Enum.find(result_messages, &(&1["id"] == 8))

      assert get_in(response, ["result", "_meta", "ex_mcp", "claude_sdk", "sessionId"]) ==
               cli_uuid

      assert state.session_id == acp_id
      assert state.claude_session_id == cli_uuid
    end

    test "emits pending tool_call from partial tool start", %{state: state} do
      event = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{
          "type" => "content_block_start",
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_read",
            "name" => "Read",
            "input" => %{"file_path" => "/tmp/project/lib/a.ex"}
          }
        }
      }

      assert {:messages, [message], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      update = message["params"]["update"]

      assert message["params"]["sessionId"] == "s1"
      assert update["sessionUpdate"] == "tool_call"
      assert update["status"] == "pending"
      assert update["kind"] == "read"
      assert Map.has_key?(state.tool_calls, "toolu_read")
    end

    test "maps TodoWrite to plan update", %{state: state} do
      event = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "todo_1",
              "name" => "TodoWrite",
              "input" => %{
                "todos" => [
                  %{"content" => "Read code", "status" => "completed"},
                  %{"content" => "Patch adapter", "status" => "in_progress"}
                ]
              }
            }
          ]
        }
      }

      assert {:messages, messages, _state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      plan = Enum.find(messages, &(get_in(&1, ["params", "update", "sessionUpdate"]) == "plan"))

      assert get_in(plan, ["params", "update", "entries", Access.at(0), "status"]) == "completed"

      assert get_in(plan, ["params", "update", "entries", Access.at(1), "status"]) ==
               "in_progress"
    end

    test "does not treat assistant message id as session id", %{state: state} do
      event = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{
          "id" => "msg_123",
          "content" => [%{"type" => "text", "text" => "hello"}]
        }
      }

      assert {:messages, [message], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      assert message["params"]["sessionId"] == "s1"
      assert state.session_id == "s1"
    end

    test "does not re-emit terminal assistant text after partial text chunks", %{state: state} do
      start_event = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{
          "type" => "content_block_start",
          "content_block" => %{"type" => "text", "text" => ""}
        }
      }

      delta_event = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => "streamed once"}
        }
      }

      assistant_event = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "streamed once"}]
        }
      }

      assert {:skip, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(start_event), state)

      assert {:messages, [chunk], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(delta_event), state)

      assert get_in(chunk, ["params", "update", "content", "text"]) == "streamed once"

      assert {:skip, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(assistant_event), state)

      assert IO.iodata_to_binary(Enum.reverse(state.text_acc)) == "streamed once"
    end

    test "does not suppress distinct identical assistant messages without partial deltas", %{
      state: state
    } do
      assistant = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{"content" => [%{"type" => "text", "text" => "SAME"}]}
      }

      assert {:messages, [_chunk], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(assistant), state)

      assert {:messages, [_chunk], _state} =
               ClaudeSDK.translate_inbound(Jason.encode!(assistant), state)
    end

    test "does not re-emit streamed text when the terminal assistant also contains a tool", %{
      state: state
    } do
      text_start = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{
          "type" => "content_block_start",
          "content_block" => %{"type" => "text", "text" => ""}
        }
      }

      text_delta = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => "before tool"}
        }
      }

      tool = %{
        "type" => "tool_use",
        "id" => "toolu_read",
        "name" => "Read",
        "input" => %{"file_path" => "/tmp/project/lib/a.ex"}
      }

      tool_start = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{"type" => "content_block_start", "content_block" => tool}
      }

      assistant = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "before tool"}, tool]
        }
      }

      assert {:skip, state} = ClaudeSDK.translate_inbound(Jason.encode!(text_start), state)

      assert {:messages, [_chunk], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(text_delta), state)

      assert {:messages, [_pending], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(tool_start), state)

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(assistant), state)

      refute Enum.any?(
               messages,
               &(get_in(&1, ["params", "update", "sessionUpdate"]) ==
                   "agent_message_chunk")
             )

      assert IO.iodata_to_binary(Enum.reverse(state.text_acc)) == "before tool"
    end

    test "allows assistant-only text after a streamed assistant", %{state: state} do
      text_start = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{
          "type" => "content_block_start",
          "content_block" => %{"type" => "text", "text" => ""}
        }
      }

      text_delta = %{
        "type" => "stream_event",
        "session_id" => "s1",
        "event" => %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => "first"}
        }
      }

      streamed_assistant = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{"content" => [%{"type" => "text", "text" => "first"}]}
      }

      fallback_assistant = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{"content" => [%{"type" => "text", "text" => " fallback"}]}
      }

      assert {:skip, state} = ClaudeSDK.translate_inbound(Jason.encode!(text_start), state)

      assert {:messages, [_chunk], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(text_delta), state)

      assert {:skip, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(streamed_assistant), state)

      assert {:messages, [fallback_chunk], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(fallback_assistant), state)

      assert get_in(fallback_chunk, ["params", "update", "content", "text"]) == " fallback"
      assert IO.iodata_to_binary(Enum.reverse(state.text_acc)) == "first fallback"
    end

    test "accumulates every assistant text block when no partials were streamed", %{
      state: state
    } do
      assistant = %{
        "type" => "assistant",
        "session_id" => "s1",
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "first"},
            %{"type" => "text", "text" => " second"}
          ]
        }
      }

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(assistant), state)

      chunks =
        for %{"params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk"} = update}} <-
              messages,
            do: get_in(update, ["content", "text"])

      assert chunks == ["first", " second"]
      assert IO.iodata_to_binary(Enum.reverse(state.text_acc)) == "first second"
    end

    test "final result produces ACP prompt response with stop reason and usage", %{state: state} do
      state = %{state | pending_prompt_id: 123, session_id: "s1", text_acc: ["world", "hello "]}

      event = %{
        "type" => "result",
        "subtype" => "success",
        "session_id" => "s1",
        "stop_reason" => "max_tokens",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2},
        "result" => "ignored when text_acc exists"
      }

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      response = Enum.find(messages, &(&1["id"] == 123))

      assert response["result"]["stopReason"] == "max_tokens"
      assert response["result"]["usage"]["inputTokens"] == 1

      assert get_in(response, ["result", "_meta", "ex_mcp", "claude_sdk", "text"]) ==
               "hello world"

      refute Enum.any?(
               messages,
               &(get_in(&1, ["params", "update", "sessionUpdate"]) == "agent_message_chunk")
             )

      assert state.pending_prompt_id == nil
    end

    test "final result emits fallback message chunk when Claude does not stream text", %{
      state: state
    } do
      state = %{state | pending_prompt_id: 123, session_id: "s1", text_acc: []}

      event = %{
        "type" => "result",
        "subtype" => "success",
        "session_id" => "s1",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2},
        "result" => "final only answer"
      }

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      chunk =
        Enum.find(
          messages,
          &(get_in(&1, ["params", "update", "sessionUpdate"]) == "agent_message_chunk")
        )

      response = Enum.find(messages, &(&1["id"] == 123))

      assert get_in(chunk, ["params", "sessionId"]) == "s1"
      assert get_in(chunk, ["params", "update", "content", "text"]) == "final only answer"
      assert response["result"]["stopReason"] == "end_turn"

      assert get_in(response, ["result", "_meta", "ex_mcp", "claude_sdk", "text"]) ==
               "final only answer"

      assert state.pending_prompt_id == nil
    end

    test "maps Bash tool results to terminal output metadata", %{state: state} do
      state = %{
        state
        | session_id: "s1",
          tool_calls: %{"toolu_bash" => %{name: "Bash", input: %{"command" => "ls"}}}
      }

      event = %{
        "type" => "user",
        "session_id" => "s1",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_bash",
              "content" => %{
                "type" => "bash_code_execution_result",
                "stdout" => "ok",
                "stderr" => "",
                "return_code" => 0
              }
            }
          ]
        }
      }

      assert {:messages, [message], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      update = message["params"]["update"]
      assert update["content"] == [%{"type" => "terminal", "terminalId" => "toolu_bash"}]

      assert get_in(update, ["_meta", "terminal_output"]) == %{
               "terminal_id" => "toolu_bash",
               "data" => "ok"
             }

      assert get_in(update, ["_meta", "terminal_exit"]) == %{
               "terminal_id" => "toolu_bash",
               "exit_code" => 0,
               "signal" => nil
             }

      refute Map.has_key?(state.tool_calls, "toolu_bash")
    end
  end

  describe "upstream capability parity" do
    test "advertises a stable mode catalog and gates bypass by explicit opt-in", %{state: state} do
      base = Mapper.modes_result(state)["availableModes"]
      base_ids = Enum.map(base, & &1["id"])
      assert "auto" in base_ids
      refute "bypassPermissions" in base_ids
      refute "dontAsk" in base_ids

      assert Enum.map(base, &get_in(&1, ["_meta", "kind"])) ==
               ["standard", "standard", "plan", "auto_review"]

      state = %{
        state
        | available_models: [%{"value" => "sonnet", "supportsAutoMode" => true}],
          opts: [allow_dangerously_skip_permissions: true]
      }

      modes = Mapper.modes_result(state)["availableModes"]
      assert "bypassPermissions" in Enum.map(modes, & &1["id"])
      assert List.last(modes)["_meta"] == %{"kind" => "full_access"}
    end

    test "rejects a mode that is not currently advertised", %{state: state} do
      request = %{
        "id" => 10,
        "method" => "session/set_mode",
        "params" => %{"sessionId" => "s1", "modeId" => "bypassPermissions"}
      }

      assert {:error, "Unsupported Claude permission mode: bypassPermissions", ^state} =
               ClaudeSDK.translate_outbound(request, state)
    end

    test "auto falls back to accept edits for a model without auto support", %{state: state} do
      state = %{state | available_models: [%{"value" => "sonnet", "supportsAutoMode" => false}]}

      request = %{
        "id" => 11,
        "method" => "session/set_mode",
        "params" => %{"sessionId" => "s1", "modeId" => "auto"}
      }

      assert {:messages_and_reply_and_write, messages, reply, data, state} =
               ClaudeSDK.translate_outbound(request, state)

      assert reply["modes"]["currentModeId"] == "acceptEdits"
      assert state.permission_mode == "acceptEdits"

      assert IO.iodata_to_binary(data) =~ ~s("mode":"acceptEdits")

      assert [notice, mode_update] = messages
      assert get_in(notice, ["params", "update", "content", "text"]) =~ "Auto mode unavailable"

      assert get_in(mode_update, ["params", "update"]) == %{
               "sessionUpdate" => "current_mode_update",
               "currentModeId" => "acceptEdits"
             }
    end

    test "permission choices only promise persistence when Claude supplied an update", %{
      state: state
    } do
      event = %{
        "type" => "control_request",
        "request_id" => "claude-permission-1",
        "request" => %{
          "subtype" => "can_use_tool",
          "tool_name" => "Bash",
          "tool_use_id" => "tool-1",
          "input" => %{"command" => "mix test"},
          "decision_reason" => "Runs tests",
          "permission_suggestions" => []
        }
      }

      assert {:messages, messages, _state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      request = Enum.find(messages, &(&1["method"] == "session/request_permission"))

      assert Enum.map(request["params"]["options"], & &1["optionId"]) == [
               "allow_once",
               "reject_once"
             ]

      assert get_in(request, ["_meta", "permission", "description"]) == "Reason: Runs tests"
    end

    test "ExitPlanMode applies the selected session mode", %{state: state} do
      state = %{
        state
        | available_models: [%{"value" => "sonnet", "supportsAutoMode" => true}]
      }

      event = %{
        "type" => "control_request",
        "request_id" => "exit-plan-1",
        "request" => %{
          "subtype" => "can_use_tool",
          "tool_name" => "ExitPlanMode",
          "tool_use_id" => "plan-tool",
          "input" => %{"plan" => "Implement it"}
        }
      }

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      request = Enum.find(messages, &(&1["method"] == "session/request_permission"))
      assert hd(request["params"]["options"])["optionId"] == "exit-plan-auto"

      response = %{
        "id" => request["id"],
        "result" => %{
          "outcome" => %{"outcome" => "selected", "optionId" => "exit-plan-auto"}
        }
      }

      assert {:ok, data, _state} = ClaudeSDK.translate_outbound(response, state)
      control = data |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()

      assert get_in(control, ["response", "response", "updatedPermissions"]) == [
               %{"type" => "setMode", "mode" => "auto", "destination" => "session"}
             ]
    end

    test "AskUserQuestion round-trips through ACP form elicitation", %{state: state} do
      state = %{
        state
        | session_id: "s1",
          client_capabilities: %{"elicitation" => %{"form" => %{}}}
      }

      event = %{
        "type" => "control_request",
        "request_id" => "ask-1",
        "request" => %{
          "subtype" => "can_use_tool",
          "tool_name" => "AskUserQuestion",
          "tool_use_id" => "question-tool",
          "input" => %{
            "questions" => [
              %{
                "question" => "Which color?",
                "header" => "Color",
                "multiSelect" => false,
                "options" => [
                  %{"label" => "Blue", "description" => "Cool", "preview" => "#00f"}
                ]
              }
            ]
          }
        }
      }

      assert {:messages, [request], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      assert request["method"] == "elicitation/create"
      assert request["params"]["mode"] == "form"
      assert request["params"]["toolCallId"] == "question-tool"

      response = %{
        "id" => request["id"],
        "result" => %{"action" => "accept", "content" => %{"question_0" => "Blue"}}
      }

      assert {:ok, data, _state} = ClaudeSDK.translate_outbound(response, state)
      control = data |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()

      assert get_in(control, ["response", "response", "updatedInput", "answers"]) == %{
               "Which color?" => "Blue"
             }
    end

    test "AskUserQuestion keeps a single-select pick and carries custom text as notes",
         %{state: state} do
      {request, state} = ask_user_question(state, multi_select: false)

      response = %{
        "id" => request["id"],
        "result" => %{
          "action" => "accept",
          "content" => %{"question_0" => "Blue", "question_0_custom" => "  navy, please  "}
        }
      }

      assert {:ok, data, _state} = ClaudeSDK.translate_outbound(response, state)
      updated_input = decoded_updated_input(data)

      assert updated_input["answers"] == %{"Which color?" => "Blue"}
      assert updated_input["annotations"] == %{"Which color?" => %{"notes" => "navy, please"}}
    end

    test "AskUserQuestion custom text alone answers a single-select question",
         %{state: state} do
      {request, state} = ask_user_question(state, multi_select: false)

      response = %{
        "id" => request["id"],
        "result" => %{"action" => "accept", "content" => %{"question_0_custom" => "Teal"}}
      }

      assert {:ok, data, _state} = ClaudeSDK.translate_outbound(response, state)
      updated_input = decoded_updated_input(data)

      assert updated_input["answers"] == %{"Which color?" => "Teal"}
      refute Map.has_key?(updated_input, "annotations")
    end

    test "AskUserQuestion joins custom text into a multi-select in the CLI's quoted form",
         %{state: state} do
      {request, state} = ask_user_question(state, multi_select: true)

      response = %{
        "id" => request["id"],
        "result" => %{
          "action" => "accept",
          "content" => %{
            "question_0" => ["Blue", "Green"],
            "question_0_custom" => "Redis, not Memcached"
          }
        }
      }

      assert {:ok, data, _state} = ClaudeSDK.translate_outbound(response, state)
      updated_input = decoded_updated_input(data)

      assert updated_input["answers"] == %{
               "Which color?" => ~s(Blue, Green, "Redis, not Memcached")
             }

      refute Map.has_key?(updated_input, "annotations")
    end

    test "AskUserQuestion merges notes into annotations the tool input already carries",
         %{state: state} do
      {request, state} =
        ask_user_question(state,
          multi_select: false,
          input_extra: %{"annotations" => %{"Other question" => %{"notes" => "kept"}}}
        )

      response = %{
        "id" => request["id"],
        "result" => %{
          "action" => "accept",
          "content" => %{"question_0" => "Blue", "question_0_custom" => "note"}
        }
      }

      assert {:ok, data, _state} = ClaudeSDK.translate_outbound(response, state)
      updated_input = decoded_updated_input(data)

      assert updated_input["annotations"] == %{
               "Other question" => %{"notes" => "kept"},
               "Which color?" => %{"notes" => "note"}
             }
    end

    test "AskUserQuestion fails closed without form elicitation", %{state: state} do
      event = %{
        "type" => "control_request",
        "request_id" => "ask-unsupported",
        "request" => %{
          "subtype" => "can_use_tool",
          "tool_name" => "AskUserQuestion",
          "tool_use_id" => "question-tool",
          "input" => %{
            "questions" => [
              %{"question" => "Continue?", "options" => [%{"label" => "Yes"}]}
            ]
          }
        }
      }

      assert {:skip_and_write, data, _state} =
               ClaudeSDK.translate_inbound(Jason.encode!(event), state)

      control = data |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert get_in(control, ["response", "response", "behavior"]) == "deny"
      assert get_in(control, ["response", "response", "interrupt"]) == true
    end

    test "keeps the prompt open until spawned background subagents drain", %{state: state} do
      acp_id = "claude_sdk_42"
      cli_uuid = "d59acfec-f910-4c3b-bb2f-087ab4c4bd62"

      state = %{
        state
        | pending_prompt_id: 321,
          session_id: acp_id,
          claude_session_id: cli_uuid
      }

      started = %{
        "type" => "system",
        "subtype" => "task_started",
        "session_id" => cli_uuid,
        "task_id" => "agent-1",
        "tool_use_id" => "tool-1",
        "subagent_type" => "general-purpose",
        "description" => "Check the tests"
      }

      assert {:messages, [_plan], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(started), state)

      result = %{
        "type" => "result",
        "subtype" => "success",
        "session_id" => cli_uuid,
        "result" => "initial answer",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(result), state)

      refute Enum.any?(messages, &(&1["id"] == 321))
      assert_update_session_ids(messages, acp_id)
      assert state.pending_prompt_id == 321
      assert state.deferred_result == result
      assert state.session_id == acp_id
      assert state.claude_session_id == cli_uuid

      completed = %{
        "type" => "system",
        "subtype" => "task_notification",
        "session_id" => cli_uuid,
        "task_id" => "agent-1",
        "status" => "completed",
        "summary" => "Done"
      }

      assert {:messages, [_plan], state} =
               ClaudeSDK.translate_inbound(Jason.encode!(completed), state)

      idle = %{
        "type" => "system",
        "subtype" => "session_state_changed",
        "session_id" => cli_uuid,
        "state" => "idle"
      }

      assert {:messages, messages, state} =
               ClaudeSDK.translate_inbound(Jason.encode!(idle), state)

      response = Enum.find(messages, &(&1["id"] == 321))
      assert response["result"]["stopReason"] == "end_turn"

      assert get_in(response, ["result", "_meta", "ex_mcp", "claude_sdk", "sessionId"]) ==
               cli_uuid

      assert_update_session_ids(messages, acp_id)
      assert state.pending_prompt_id == nil
      assert state.deferred_result == nil
      assert state.session_id == acp_id
      assert state.claude_session_id == cli_uuid
    end
  end

  defp mcp_config_values(args) do
    args
    |> Enum.drop_while(&(&1 != "--mcp-config"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "--")))
  end

  defp permissions(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp session_request(method, cwd, server_names) do
    servers =
      Enum.map(
        server_names,
        &%{"name" => &1, "command" => "/usr/bin/#{&1}", "args" => [], "env" => []}
      )

    %{
      "id" => 1,
      "method" => method,
      "params" => %{
        "sessionId" => "123e4567-e89b-12d3-a456-426614174000",
        "cwd" => cwd,
        "mcpServers" => servers
      }
    }
  end

  defp assert_update_session_ids(messages, expected_session_id) do
    updates = Enum.filter(messages, &(&1["method"] == "session/update"))
    assert updates != []
    assert Enum.all?(updates, &(&1["params"]["sessionId"] == expected_session_id))
  end

  defp write_store_fixture(summary) when is_binary(summary) do
    write_store_fixture([%{"type" => "summary", "summary" => summary}])
  end

  defp write_store_fixture(entries) when is_list(entries) do
    root =
      System.tmp_dir!()
      |> Path.join("ex_mcp_claude_sdk_adapter_#{System.unique_integer([:positive])}")

    config_dir = Path.join(root, "claude")
    cwd = Path.join(root, "workspace")
    session_id = "123e4567-e89b-12d3-a456-426614174000"

    File.mkdir_p!(cwd)

    project_dir =
      config_dir
      |> Path.join("projects")
      |> Path.join(SessionStore.project_key(cwd))

    File.mkdir_p!(project_dir)

    entries =
      Enum.map(entries, fn entry ->
        entry
        |> replace_placeholder(cwd_placeholder(), cwd)
        |> replace_placeholder(session_id_placeholder(), session_id)
        |> Map.put_new("cwd", cwd)
      end)

    project_dir
    |> Path.join("#{session_id}.jsonl")
    |> File.write!(Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n")

    on_exit(fn -> File.rm_rf!(root) end)

    {config_dir, cwd, session_id}
  end

  defp replace_placeholder(value, placeholder, replacement) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} ->
      {key, replace_placeholder(nested, placeholder, replacement)}
    end)
    |> Map.new()
  end

  defp replace_placeholder(value, placeholder, replacement) when is_list(value),
    do: Enum.map(value, &replace_placeholder(&1, placeholder, replacement))

  defp replace_placeholder(value, placeholder, replacement) when value == placeholder,
    do: replacement

  defp replace_placeholder(value, _placeholder, _replacement), do: value

  defp cwd_placeholder, do: "__cwd__"
  defp session_id_placeholder, do: "__session_id__"

  defp ask_user_question(state, opts) do
    state = %{
      state
      | session_id: "s1",
        client_capabilities: %{"elicitation" => %{"form" => %{}}}
    }

    input =
      Map.merge(
        %{
          "questions" => [
            %{
              "question" => "Which color?",
              "header" => "Color",
              "multiSelect" => Keyword.fetch!(opts, :multi_select),
              "options" => [
                %{"label" => "Blue", "description" => "Cool"},
                %{"label" => "Green", "description" => "Calm"}
              ]
            }
          ]
        },
        Keyword.get(opts, :input_extra, %{})
      )

    event = %{
      "type" => "control_request",
      "request_id" => "ask-#{System.unique_integer([:positive])}",
      "request" => %{
        "subtype" => "can_use_tool",
        "tool_name" => "AskUserQuestion",
        "tool_use_id" => "question-tool",
        "input" => input
      }
    }

    {:messages, [request], state} = ClaudeSDK.translate_inbound(Jason.encode!(event), state)
    {request, state}
  end

  defp decoded_updated_input(data) do
    data
    |> IO.iodata_to_binary()
    |> String.trim()
    |> Jason.decode!()
    |> get_in(["response", "response", "updatedInput"])
  end
end
