defmodule ExMCP.ACP.AdapterBridgeTest do
  # The subprocess environment regression test mutates the process-global OS env.
  use ExUnit.Case, async: false

  alias ExMCP.ACP.AdapterBridge
  alias ExMCP.ACP.AdapterBridge.PortRunner

  # MockAdapter: uses a simple cat-like echo process for testing
  defmodule MockAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct [:session_id, messages_received: []]

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts) do
      # Use cat as a simple echo process — reads stdin, writes to stdout
      {"cat", []}
    end

    @impl true
    def capabilities do
      %{"streaming" => true, "mockAdapter" => true}
    end

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state) do
      {:ok, :skip, state}
    end

    def translate_outbound(%{"method" => "session/prompt", "params" => params}, state) do
      # Echo the prompt text back as a line to stdin
      text =
        params["prompt"]
        |> List.first()
        |> Map.get("text", "")

      data = Jason.encode!(%{"type" => "echo", "text" => text}) <> "\n"
      {:ok, data, state}
    end

    def translate_outbound(_msg, state) do
      {:ok, :skip, state}
    end

    @impl true
    def translate_inbound(line, state) do
      case Jason.decode(String.trim(line)) do
        {:ok, %{"type" => "echo", "text" => text}} ->
          notification = %{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "sessionId" => "test_session",
              "update" => %{
                "sessionUpdate" => "agent_message_chunk",
                "content" => %{"type" => "text", "text" => text}
              }
            }
          }

          {:messages, [notification], state}

        _ ->
          {:skip, state}
      end
    end
  end

  defmodule DeferredSetterAdapter do
    @behaviour ExMCP.ACP.Adapter

    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), pending: MapSet.new()}}
    def command(opts), do: if(Keyword.get(opts, :no_port), do: :one_shot, else: {"cat", []})
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

    def translate_outbound(%{"method" => method, "id" => id}, state)
        when method in ["session/set_model", "session/set_mode", "session/set_config_option"] do
      data = Jason.encode!(%{"native_request" => id}) <> "\n"
      {:pending_and_write, data, %{state | pending: MapSet.put(state.pending, id)}}
    end

    def translate_outbound(
          %{"method" => "$/cancel_request", "params" => %{"requestId" => id}},
          state
        ) do
      send(state.test_pid, {:native_setter_cancelled, id})
      {:ok, :skip, %{state | pending: MapSet.delete(state.pending, id)}}
    end

    def translate_inbound(line, state) do
      %{"native_request" => id} = Jason.decode!(String.trim(line))
      send(state.test_pid, {:native_setter_received, id})
      {:skip, state}
    end

    def outbound_write_failed(%{"id" => id}, _reason, state) do
      %{state | pending: MapSet.delete(state.pending, id)}
    end

    def handle_adapter_message({:native_setter_reply, id, reply}, state) do
      if MapSet.member?(state.pending, id) do
        message = Map.merge(%{"jsonrpc" => "2.0", "id" => id}, reply)
        {:messages, [message], %{state | pending: MapSet.delete(state.pending, id)}}
      else
        {:skip, state}
      end
    end

    def handle_adapter_message(_message, state), do: {:skip, state}
  end

  # OneShotMockAdapter: simulates one-shot execution
  defmodule OneShotMockAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct []

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: :one_shot

    @impl true
    def capabilities, do: %{"streaming" => false}

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state) do
      {:ok, :skip, state}
    end

    def translate_outbound(%{"method" => "session/prompt", "id" => id}, state) do
      cmd_fn = fn ->
        result = %{
          "jsonrpc" => "2.0",
          "result" => %{"stopReason" => "end_turn", "text" => "one-shot result"},
          "id" => id
        }

        {:ok, [Jason.encode!(result)]}
      end

      {:one_shot, cmd_fn, state}
    end

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}
  end

  defmodule BlockingOneShotAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct [:test_pid]

    @impl true
    def init(opts), do: {:ok, %__MODULE__{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def command(_opts), do: :one_shot

    @impl true
    def capabilities, do: %{}

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

    def translate_outbound(%{"method" => "session/prompt", "id" => id}, state) do
      test_pid = state.test_pid

      cmd_fn = fn ->
        send(test_pid, {:one_shot_started, self()})

        receive do
          :release ->
            {:ok, [Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}})]}
        end
      end

      {:one_shot, cmd_fn, state}
    end

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}
  end

  defmodule ErrorMockAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct []

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

    def translate_outbound(%{"method" => method}, state)
        when method in ["authenticate", "session/prompt"] do
      {:error, :adapter_refused, state}
    end

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}
  end

  test "adapter subprocess environment clears inherited Mix selectors" do
    env =
      [env: [{"MIX_ENV", "test"}, {"CUSTOM_UNSET", false}]]
      |> PortRunner.safe_env(MockAdapter)
      |> Map.new(fn {name, value} -> {to_string(name), value} end)

    assert env["MIX_ENV"] == ~c"test"
    assert env["MIX_TARGET"] == false
    assert env["CUSTOM_UNSET"] == false
  end

  test "security regression: isolated adapter subprocess excludes ambient secrets" do
    sentinel = "EX_MCP_SECURITY_REGRESSION_AMBIENT_SECRET"
    explicit = "EX_MCP_SECURITY_REGRESSION_EXPLICIT"
    previous = System.get_env(sentinel)

    System.put_env(sentinel, "must-not-reach-child")

    on_exit(fn ->
      if previous do
        System.put_env(sentinel, previous)
      else
        System.delete_env(sentinel)
      end
    end)

    script = """
    IO.puts("ambient=" <> inspect(System.get_env(#{inspect(sentinel)})))
    IO.puts("explicit=" <> inspect(System.get_env(#{inspect(explicit)})))
    IO.puts("path_present=" <> inspect(is_binary(System.get_env("PATH"))))
    IO.puts("home_present=" <> inspect(is_binary(System.get_env("HOME"))))
    """

    assert {:ok, port} =
             PortRunner.open(
               System.find_executable("elixir"),
               ["-e", script],
               [env: [{explicit, "explicit-value"}]],
               MockAdapter
             )

    output = collect_port_output(port)

    assert output =~ "ambient=nil"
    assert output =~ ~s(explicit="explicit-value")
    assert output =~ "path_present=true"
    assert output =~ "home_present=true"
    refute output =~ "must-not-reach-child"
  end

  test "rejects ACP frames larger than the configured bridge limit" do
    {:ok, bridge} =
      AdapterBridge.start_link(
        adapter: OneShotMockAdapter,
        adapter_opts: [],
        max_buffer_bytes: 64
      )

    oversized =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{"prompt" => [%{"type" => "text", "text" => String.duplicate("x", 64)}]},
        "id" => 1
      })

    assert {:error, :frame_too_large} = AdapterBridge.send_message(bridge, oversized)
    assert :ok = AdapterBridge.close(bridge)
  end

  test "isolated adapter subprocess policy rejects unknown modes" do
    assert {:error, {:invalid_environment_policy, :unknown}} =
             PortRunner.open("elixir", [], [environment_policy: :unknown], MockAdapter)
  end

  defmodule CommandErrorAdapter do
    @behaviour ExMCP.ACP.Adapter

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def command(opts), do: {:error, {:bad_launch, Keyword.get(opts, :why)}}

    @impl true
    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}
  end

  defmodule ManagedMockAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct [:test_pid, shutdown?: false]

    @impl true
    def init(opts), do: {:ok, %__MODULE__{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def command(_opts), do: :adapter_managed

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}
    def translate_outbound(_msg, state), do: {:ok, :pending, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}

    @impl true
    def handle_adapter_message({:managed_emit, text}, state) do
      message = %{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "managed-session",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => text}
          }
        }
      }

      {:messages, [message], state}
    end

    def handle_adapter_message(_message, state), do: {:skip, state}

    @impl true
    def shutdown(state) do
      send(state.test_pid, :managed_shutdown)
      %{state | shutdown?: true}
    end
  end

  defp collect_port_output(port, output \\ "") do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, output <> data)

      {^port, {:exit_status, 0}} ->
        output

      {^port, {:exit_status, status}} ->
        flunk("environment probe exited with status #{status}: #{output}")
    after
      10_000 ->
        flunk("timed out waiting for environment probe: #{output}")
    end
  end

  defmodule ParamListAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct []

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def capabilities, do: %{"sessionCapabilities" => %{}}

    @impl true
    def list_sessions(params, state) do
      {:ok,
       %{
         "sessions" => [
           %{
             "sessionId" => "param-session",
             "cwd" => params["cwd"],
             "title" => params["cursor"]
           }
         ],
         "nextCursor" => "next-page",
         "_meta" => %{}
       }, state}
    end

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}
    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}
  end

  defmodule AuthForkAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct []

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def capabilities, do: %{"sessionCapabilities" => %{}}

    @impl true
    def auth_methods(_opts), do: [%{"id" => "terminal", "name" => "Terminal login"}]

    @impl true
    def fork_session(%{"sessionId" => "missing-point"}, state) do
      # The shape ExMCP.ACP.Adapters.ClaudeSDK returns for a fork point the
      # transcript does not contain, which the bridge must answer as -32602.
      {:error, {:invalid_params, "Fork point message msg_nope was not found"}, state}
    end

    def fork_session(%{"sessionId" => "broken"}, state) do
      {:error, "Claude session broken could not be forked", state}
    end

    def fork_session(params, state) do
      {:ok,
       %{
         "sessionId" => "forked-#{params["sessionId"]}",
         "_meta" => %{"cwd" => params["cwd"]}
       }, state}
    end

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}
    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}
  end

  defmodule SyntheticMessagesAdapter do
    @behaviour ExMCP.ACP.Adapter

    defstruct []

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def capabilities do
      %{
        "sessionCapabilities" => %{
          "fork" => %{}
        }
      }
    end

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

    def translate_outbound(%{"method" => "authenticate"}, state) do
      {:messages, [notice("auth-message")], state}
    end

    def translate_outbound(%{"method" => "session/set_mode"}, state) do
      {:messages_and_write, [notice("mode-message")], "ignored\n", state}
    end

    def translate_outbound(%{"method" => "session/set_model"}, state) do
      {:messages_and_write, [notice("model-message")], "ignored\n", state}
    end

    def translate_outbound(%{"method" => "session/fork"}, state) do
      {:messages, [notice("fork-message")], state}
    end

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state), do: {:skip, state}

    defp notice(text) do
      %{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "adapter-session",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => text}
          }
        }
      }
    end
  end

  # The golden gate drives adapters directly, so the `messageId` the Claude
  # adapter now stamps on chunk updates is never seen going through the bridge
  # there. This adapter builds its chunks with the same `AdapterEvents`
  # builders the Claude mapper uses, so the bridge's JSON round trip is
  # exercised for a stamped and an unstamped chunk.
  defmodule MessageIdAdapter do
    @behaviour ExMCP.ACP.Adapter

    alias ExMCP.ACP.AdapterEvents

    defstruct []

    @impl true
    def init(_opts), do: {:ok, %__MODULE__{}}

    @impl true
    def command(_opts), do: {"cat", []}

    @impl true
    def capabilities, do: %{}

    @impl true
    def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

    def translate_outbound(%{"method" => "session/prompt"}, state),
      do: {:ok, "go\n", state}

    def translate_outbound(_msg, state), do: {:ok, :skip, state}

    @impl true
    def translate_inbound(_line, state) do
      messages = [
        AdapterEvents.agent_message_chunk("s1", "stamped", message_id: "msg_bridge_1"),
        AdapterEvents.agent_thought_chunk("s1", "thinking", message_id: "msg_bridge_1"),
        AdapterEvents.agent_message_chunk("s1", "unstamped"),
        AdapterEvents.tool_call("s1", %{"toolCallId" => "toolu_1", "title" => "Read"})
      ]

      {:messages, messages, state}
    end
  end

  # Helper to send initialize and drain the synthesized init response
  defp send_initialize(bridge) do
    :ok =
      AdapterBridge.send_message(
        bridge,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "initialize",
          "id" => 0,
          "params" => %{}
        })
      )

    {:ok, init_raw} = AdapterBridge.receive_message(bridge, 5_000)
    Jason.decode!(init_raw)
  end

  describe "start_link/1 with persistent adapter" do
    test "starts and produces initialize response" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])

      # Send initialize to trigger synthesized init response
      msg = send_initialize(bridge)

      assert msg["jsonrpc"] == "2.0"
      assert msg["result"]["agentInfo"]["name"] == "mockadapter"
      assert msg["result"]["agentCapabilities"]["streaming"] == true
      assert msg["result"]["agentCapabilities"]["mockAdapter"] == true
      assert msg["result"]["authMethods"] == []
      assert msg["result"]["protocolVersion"] == 1

      AdapterBridge.close(bridge)
    end

    test "fails to start with the reason an adapter's command/1 returns" do
      Process.flag(:trap_exit, true)

      assert {:error, {:bad_launch, :no_config}} =
               AdapterBridge.start_link(
                 adapter: CommandErrorAdapter,
                 adapter_opts: [why: :no_config]
               )
    end
  end

  describe "send and receive round-trip" do
    test "prompt goes through adapter translate and back" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])

      # Send initialize and drain init response
      _init = send_initialize(bridge)

      # Send a prompt
      prompt_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "test_session",
          "prompt" => [%{"type" => "text", "text" => "Hello adapter"}]
        },
        "id" => 42
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(prompt_msg))

      # cat echoes back what we send — the adapter translates it to a session/update
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["method"] == "session/update"
      assert msg["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
      assert msg["params"]["update"]["content"] == %{"type" => "text", "text" => "Hello adapter"}

      AdapterBridge.close(bridge)
    end
  end

  describe "native event metadata" do
    test "summary mode tags adapter name and sequence on every derived message" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [], native_events: :summary)

      _init = send_initialize(bridge)

      assert prompt_and_native(bridge, "one") == %{"adapter" => "mockadapter", "sequence" => 1}
      assert prompt_and_native(bridge, "two") == %{"adapter" => "mockadapter", "sequence" => 2}

      AdapterBridge.close(bridge)
    end

    test "raw mode also embeds the decoded native event" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [], native_events: :raw)

      _init = send_initialize(bridge)

      assert prompt_and_native(bridge, "raw") == %{
               "adapter" => "mockadapter",
               "sequence" => 1,
               "event" => %{"type" => "echo", "text" => "raw"}
             }

      AdapterBridge.close(bridge)
    end

    test "the default leaves adapter messages untouched" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      assert prompt_and_native(bridge, "default") == nil

      AdapterBridge.close(bridge)
    end

    test "off mode leaves adapter messages untouched" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [], native_events: :off)

      _init = send_initialize(bridge)

      assert prompt_and_native(bridge, "off") == nil

      AdapterBridge.close(bridge)
    end

    test "rejects an unknown native_events mode" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _stack}} =
               AdapterBridge.start_link(
                 adapter: MockAdapter,
                 adapter_opts: [],
                 native_events: :verbose
               )
    end
  end

  defp prompt_and_native(bridge, text) do
    prompt = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => "test_session",
        "prompt" => [%{"type" => "text", "text" => text}]
      }
    }

    assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(prompt))
    assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
    msg = Jason.decode!(raw)

    assert msg["method"] == "session/update"
    assert msg["params"]["update"]["content"] == %{"type" => "text", "text" => text}

    get_in(msg, ["params", "update", "_meta", "ex_mcp", "native"])
  end

  describe "one-shot adapter" do
    test "produces results without persistent Port" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: OneShotMockAdapter, adapter_opts: [])

      # Send initialize and drain init response
      _init = send_initialize(bridge)

      # Send prompt
      prompt_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [%{"type" => "text", "text" => "test"}]
        },
        "id" => 99
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(prompt_msg))

      # One-shot result arrives via Task message
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["result"]["stopReason"] == "end_turn"
      assert msg["result"]["text"] == "one-shot result"
      assert msg["id"] == 99

      AdapterBridge.close(bridge)
    end

    test "bounds concurrent one-shot tasks and frees capacity on completion" do
      {:ok, bridge} =
        AdapterBridge.start_link(
          adapter: BlockingOneShotAdapter,
          adapter_opts: [test_pid: self()],
          max_one_shot_tasks: 1
        )

      _init = send_initialize(bridge)

      prompt = fn id ->
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "session/prompt",
          "params" => %{"sessionId" => "s1", "prompt" => [%{"type" => "text", "text" => "x"}]},
          "id" => id
        })
      end

      assert :ok = AdapterBridge.send_message(bridge, prompt.(1))
      assert_receive {:one_shot_started, task_pid}
      assert {:error, :too_many_one_shot_tasks} = AdapterBridge.send_message(bridge, prompt.(2))

      send(task_pid, :release)
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 1_000)
      assert Jason.decode!(raw)["id"] == 1

      assert :ok = AdapterBridge.send_message(bridge, prompt.(3))
      assert_receive {:one_shot_started, next_task_pid}
      send(next_task_pid, :release)
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 1_000)
      assert Jason.decode!(raw)["id"] == 3

      AdapterBridge.close(bridge)
    end
  end

  describe "adapter-managed adapter" do
    test "forwards unmanaged messages and calls shutdown on close" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: ManagedMockAdapter, adapter_opts: [test_pid: self()])

      _init = send_initialize(bridge)

      send(bridge, {:managed_emit, "managed hello"})

      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["method"] == "session/update"
      assert msg["params"]["sessionId"] == "managed-session"
      assert msg["params"]["update"]["content"]["text"] == "managed hello"

      AdapterBridge.close(bridge)
      assert_receive :managed_shutdown
    end

    test "closes before aggregate outbox bytes exceed the configured limit" do
      {:ok, bridge} =
        AdapterBridge.start_link(
          adapter: ManagedMockAdapter,
          adapter_opts: [test_pid: self()],
          max_outbox_messages: 100,
          max_outbox_bytes: 600
        )

      _init = send_initialize(bridge)
      text = String.duplicate("x", 300)

      send(bridge, {:managed_emit, text})
      state = :sys.get_state(bridge)
      assert state.status == :ready
      assert state.outbox_bytes > 0
      assert state.outbox_bytes < state.max_outbox_bytes

      send(bridge, {:managed_emit, text})
      state = :sys.get_state(bridge)
      assert state.status == :closed
      assert state.outbox_bytes == 0
      assert :queue.is_empty(state.outbox)
    end
  end

  describe "waiter queue" do
    test "receive blocks until message available" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])

      # Send initialize and drain init response
      _init = send_initialize(bridge)

      # Start a receive that will block
      task =
        Task.async(fn ->
          AdapterBridge.receive_message(bridge, 10_000)
        end)

      # Give the receive call time to register as a waiter
      Process.sleep(50)

      # Now send a prompt that will produce a response
      prompt_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [%{"type" => "text", "text" => "delayed"}]
        },
        "id" => 1
      }

      AdapterBridge.send_message(bridge, Jason.encode!(prompt_msg))

      # The blocked receive should now get the message
      assert {:ok, raw} = Task.await(task, 10_000)
      msg = Jason.decode!(raw)
      assert msg["params"]["update"]["content"] == %{"type" => "text", "text" => "delayed"}

      AdapterBridge.close(bridge)
    end

    test "a timed-out receive cannot consume a later message" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      assert catch_exit(AdapterBridge.receive_message(bridge, 10))
      Process.sleep(15)

      prompt = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [%{"type" => "text", "text" => "after timeout"}]
        },
        "id" => 7
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(prompt))
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 1_000)

      assert get_in(Jason.decode!(raw), ["params", "update", "content", "text"]) ==
               "after timeout"

      AdapterBridge.close(bridge)
    end
  end

  describe "close/1" do
    test "closes cleanly" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      assert :ok = AdapterBridge.close(bridge)
      refute Process.alive?(bridge)
    end
  end

  describe "port exit" do
    test "replies error to waiters when port exits" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])

      # Send initialize and drain init response
      _init = send_initialize(bridge)

      # Close the underlying port by closing the bridge
      # We'll test via the close path
      AdapterBridge.close(bridge)

      # Bridge is stopped, no more messages
      refute Process.alive?(bridge)
    end
  end

  describe "skip messages" do
    test "initialize is handled by bridge and adapter skips it" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])

      # Send initialize — bridge synthesizes init response, adapter skips port write
      init_msg = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{},
        "id" => 1
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(init_msg))

      # Should get synthesized init response
      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["id"] == 1
      assert msg["result"]["agentInfo"]["name"] == "mockadapter"

      AdapterBridge.close(bridge)
    end
  end

  describe "adapter translation errors" do
    test "enqueue a JSON-RPC error for normal request dispatch" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: ErrorMockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      prompt_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => "s1",
          "prompt" => [%{"type" => "text", "text" => "test"}]
        },
        "id" => 44
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(prompt_msg))
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["id"] == 44
      assert msg["error"]["code"] == -32603
      assert msg["error"]["message"] == "adapter_refused"

      AdapterBridge.close(bridge)
    end

    test "enqueue a JSON-RPC error for synthesized lifecycle helpers" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: ErrorMockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      auth_msg = %{"jsonrpc" => "2.0", "method" => "authenticate", "params" => %{}, "id" => 45}

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(auth_msg))
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["id"] == 45
      assert msg["error"]["code"] == -32603
      assert msg["error"]["message"] == "adapter_refused"

      AdapterBridge.close(bridge)
    end
  end

  describe "session/list" do
    test "returns method-not-found for adapter without list capability" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      list_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/list",
        "params" => %{},
        "id" => 50
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(list_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["id"] == 50
      assert msg["error"]["code"] == -32601

      AdapterBridge.close(bridge)
    end

    test "forwards ACP list params to adapter list_sessions/2" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: ParamListAdapter, adapter_opts: [])
      init = send_initialize(bridge)

      assert get_in(init, ["result", "agentCapabilities", "sessionCapabilities", "list"]) == %{}

      list_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/list",
        "params" => %{"cwd" => "/tmp/project", "cursor" => "page-2"},
        "id" => 51
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(list_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      session = msg["result"]["sessions"] |> List.first()

      assert msg["id"] == 51
      assert session["sessionId"] == "param-session"
      assert session["cwd"] == "/tmp/project"
      assert session["title"] == "page-2"
      assert msg["result"]["nextCursor"] == "next-page"
      assert msg["result"]["_meta"] == %{}

      AdapterBridge.close(bridge)
    end
  end

  describe "authMethods and session/fork" do
    test "initialize advertises adapter auth methods and fork capability" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: AuthForkAdapter, adapter_opts: [])
      init = send_initialize(bridge)

      assert init["result"]["authMethods"] == [
               %{"id" => "terminal", "name" => "Terminal login"}
             ]

      assert get_in(init, ["result", "agentCapabilities", "sessionCapabilities", "fork"]) == %{}

      AdapterBridge.close(bridge)
    end

    test "forwards session/fork to adapter fork_session/2" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: AuthForkAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      fork_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/fork",
        "params" => %{"sessionId" => "s1", "cwd" => "/tmp/project"},
        "id" => 52
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(fork_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["id"] == 52
      assert msg["result"]["sessionId"] == "forked-s1"
      assert msg["result"]["_meta"]["cwd"] == "/tmp/project"

      AdapterBridge.close(bridge)
    end

    # The golden gate drives fork_session/2 directly and never sees the
    # bridge, so the tuple reason a missing fork point returns is pinned here.
    test "a fork point the adapter could not resolve answers invalid params" do
      assert %{"code" => -32_602, "message" => "Fork point message msg_nope was not found"} =
               fork_error("missing-point")
    end

    test "any other fork failure stays an internal error" do
      assert %{"code" => -32_603, "message" => "Claude session broken could not be forked"} =
               fork_error("broken")
    end
  end

  defp fork_error(session_id) do
    {:ok, bridge} = AdapterBridge.start_link(adapter: AuthForkAdapter, adapter_opts: [])
    _init = send_initialize(bridge)

    fork_msg = %{
      "jsonrpc" => "2.0",
      "method" => "session/fork",
      "params" => %{"sessionId" => session_id, "cwd" => "/tmp/project"},
      "id" => 53
    }

    assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(fork_msg))

    {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
    msg = Jason.decode!(raw)
    assert msg["id"] == 53

    AdapterBridge.close(bridge)

    msg["error"]
  end

  describe "chunk messageId" do
    test "a stamped messageId reaches the client and an unstamped chunk omits the key" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MessageIdAdapter, adapter_opts: [])

      _init = send_initialize(bridge)

      prompt = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{"sessionId" => "s1", "prompt" => []},
        "id" => 77
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(prompt))

      updates =
        for _ <- 1..4 do
          assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
          Jason.decode!(raw)["params"]["update"]
        end

      assert [message_chunk, thought_chunk, unstamped, tool_call] = updates

      assert message_chunk["messageId"] == "msg_bridge_1"
      assert thought_chunk["messageId"] == "msg_bridge_1"
      refute Map.has_key?(unstamped, "messageId")
      refute Map.has_key?(tool_call, "messageId")

      assert :ok =
               ExMCP.ACP.RequestValidation.validate_session_update(%{
                 "sessionId" => "s1",
                 "update" => message_chunk
               })

      AdapterBridge.close(bridge)
    end
  end

  describe "synthetic responses with adapter-emitted messages" do
    test "pushes messages before synthesized authenticate response" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: SyntheticMessagesAdapter, adapter_opts: [])

      _init = send_initialize(bridge)

      auth_msg = %{"jsonrpc" => "2.0", "method" => "authenticate", "params" => %{}, "id" => 53}

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(auth_msg))

      assert {:ok, raw_notice} = AdapterBridge.receive_message(bridge, 5_000)
      notice = Jason.decode!(raw_notice)
      assert notice["params"]["update"]["content"]["text"] == "auth-message"

      assert {:ok, raw_response} = AdapterBridge.receive_message(bridge, 5_000)
      response = Jason.decode!(raw_response)
      assert response["id"] == 53
      assert response["result"] == %{}

      AdapterBridge.close(bridge)
    end

    test "pushes messages before synthesized response when writing to the subprocess" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: SyntheticMessagesAdapter, adapter_opts: [])

      _init = send_initialize(bridge)

      mode_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_mode",
        "params" => %{"sessionId" => "s1", "modeId" => "code"},
        "id" => 54
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(mode_msg))

      assert {:ok, raw_notice} = AdapterBridge.receive_message(bridge, 5_000)
      notice = Jason.decode!(raw_notice)
      assert notice["params"]["update"]["content"]["text"] == "mode-message"

      assert {:ok, raw_response} = AdapterBridge.receive_message(bridge, 5_000)
      response = Jason.decode!(raw_response)
      assert response["id"] == 54
      assert response["result"] == %{}

      AdapterBridge.close(bridge)
    end

    test "pushes messages before synthesized set_model response" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: SyntheticMessagesAdapter, adapter_opts: [])

      _init = send_initialize(bridge)

      model_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_model",
        "params" => %{"sessionId" => "s1", "modelId" => "gpt-5.1-codex"},
        "id" => 55
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(model_msg))

      assert {:ok, raw_notice} = AdapterBridge.receive_message(bridge, 5_000)
      notice = Jason.decode!(raw_notice)
      assert notice["params"]["update"]["content"]["text"] == "model-message"

      assert {:ok, raw_response} = AdapterBridge.receive_message(bridge, 5_000)
      response = Jason.decode!(raw_response)
      assert response["id"] == 55
      assert response["result"] == %{}

      AdapterBridge.close(bridge)
    end

    test "pushes messages before synthesized fork response" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: SyntheticMessagesAdapter, adapter_opts: [])

      _init = send_initialize(bridge)

      fork_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/fork",
        "params" => %{"sessionId" => "s1", "cwd" => "/tmp"},
        "id" => 55
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(fork_msg))

      assert {:ok, raw_notice} = AdapterBridge.receive_message(bridge, 5_000)
      notice = Jason.decode!(raw_notice)
      assert notice["params"]["update"]["content"]["text"] == "fork-message"

      assert {:ok, raw_response} = AdapterBridge.receive_message(bridge, 5_000)
      response = Jason.decode!(raw_response)
      assert response["id"] == 55
      assert response["result"] == %{}

      AdapterBridge.close(bridge)
    end
  end

  describe "session/set_mode" do
    test "returns OK response" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      mode_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_mode",
        "params" => %{"sessionId" => "s1", "modeId" => "code"},
        "id" => 51
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(mode_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["id"] == 51
      assert is_map(msg["result"])

      AdapterBridge.close(bridge)
    end
  end

  describe "session/set_model" do
    test "zero-timeout polling reads buffered output and never registers an empty waiter" do
      bridge = start_supervised!({AdapterBridge, adapter: MockAdapter, adapter_opts: []})
      message = %{"jsonrpc" => "2.0", "id" => 200, "method" => "initialize", "params" => %{}}
      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(message))
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 0)
      assert Jason.decode!(raw)["id"] == 200
      assert {:error, :timeout} = AdapterBridge.receive_message(bridge, 0)
      assert :queue.is_empty(:sys.get_state(bridge).waiters)
    end

    test "deferred setters wait for one correlated native result or error" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: DeferredSetterAdapter, adapter_opts: [test_pid: self()])

      on_exit(fn -> if Process.alive?(bridge), do: AdapterBridge.close(bridge) end)
      _init = send_initialize(bridge)

      for {method, id} <-
            Enum.with_index(
              ["session/set_model", "session/set_mode", "session/set_config_option"],
              201
            ) do
        message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}}
        assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(message))
        assert_receive {:native_setter_received, ^id}, 1_000
        assert {:error, :timeout} = AdapterBridge.receive_message(bridge, 0)

        reply =
          if rem(id, 2) == 0,
            do: %{"result" => %{}},
            else: %{"error" => %{"code" => -32_602, "message" => "native rejected"}}

        send(bridge, {:native_setter_reply, id, reply})
        assert {:ok, raw} = AdapterBridge.receive_message(bridge, 1_000)
        assert Jason.decode!(raw) == Map.merge(%{"jsonrpc" => "2.0", "id" => id}, reply)
        send(bridge, {:native_setter_reply, id, %{"result" => %{}}})
        assert {:error, :timeout} = AdapterBridge.receive_message(bridge, 0)
      end

      assert :ok = AdapterBridge.close(bridge)
    end

    test "rejected deferred writes retire tracking and ignore late native replies" do
      {:ok, bridge} =
        AdapterBridge.start_link(
          adapter: DeferredSetterAdapter,
          adapter_opts: [test_pid: self(), no_port: true]
        )

      on_exit(fn -> if Process.alive?(bridge), do: AdapterBridge.close(bridge) end)

      methods =
        List.duplicate(["session/set_model", "session/set_mode", "session/set_config_option"], 3)
        |> List.flatten()

      for {method, id} <- Enum.with_index(methods, 211) do
        message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}}
        assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(message))
        assert {:ok, raw} = AdapterBridge.receive_message(bridge, 1_000)
        response = Jason.decode!(raw)
        assert response["id"] == id
        assert response["error"]["message"] == "no_port"
        refute Map.has_key?(response, "result")
        assert :sys.get_state(bridge).adapter_state.pending == MapSet.new()
        send(bridge, {:native_setter_reply, id, %{"result" => %{}}})
        assert {:error, :timeout} = AdapterBridge.receive_message(bridge, 0)
      end

      assert :ok = AdapterBridge.close(bridge)
    end

    test "a deferred setter timeout cancels its correlation and cannot settle the next request" do
      alias ExMCP.ACP.{AdapterTransport, Client}

      client =
        start_supervised!(
          {Client,
           transport_mod: AdapterTransport,
           adapter: DeferredSetterAdapter,
           adapter_opts: [test_pid: self()]}
        )

      bridge = :sys.get_state(client).transport_state.bridge
      first = Task.async(fn -> Client.set_model(client, "session", "first") end)
      assert_receive {:native_setter_received, first_id}, 1_000

      # Trigger the real deadline handler after native admission, without racing a short timer.
      send(client, {:pending_request_timeout, first_id})
      assert {:error, :request_timeout} = Task.await(first, 1_000)
      assert_receive {:native_setter_cancelled, ^first_id}, 1_000
      assert :sys.get_state(client).pending_requests == %{}
      assert :sys.get_state(bridge).adapter_state.pending == MapSet.new()

      second = Task.async(fn -> Client.set_model(client, "session", "second") end)
      assert_receive {:native_setter_received, second_id}, 1_000
      refute second_id == first_id
      send(bridge, {:native_setter_reply, first_id, %{"result" => %{"stale" => true}}})
      assert :sys.get_state(bridge).adapter_state.pending == MapSet.new([second_id])
      assert Task.yield(second, 0) == nil
      send(bridge, {:native_setter_reply, second_id, %{"result" => %{}}})
      assert {:ok, %{}} = Task.await(second, 1_000)
      assert :ok = Client.disconnect(client)
    end

    test "returns method-not-found when adapter skips set_model" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      model_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_model",
        "params" => %{"sessionId" => "s1", "modelId" => "gpt-5.1-codex"},
        "id" => 56
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(model_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["id"] == 56
      assert msg["error"]["code"] == -32601
      assert msg["error"]["message"] == "Method not found: session/set_model"

      AdapterBridge.close(bridge)
    end
  end

  describe "session/set_config_option" do
    test "returns OK response" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      config_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_config_option",
        "params" => %{"sessionId" => "s1", "configId" => "model", "value" => "test"},
        "id" => 52
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(config_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["id"] == 52
      assert is_map(msg["result"])
      assert msg["result"]["configOptions"] == []

      AdapterBridge.close(bridge)
    end
  end

  describe "authenticate" do
    test "returns method-not-found for adapter without auth" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      auth_msg = %{
        "jsonrpc" => "2.0",
        "method" => "authenticate",
        "params" => %{"provider" => "api_key"},
        "id" => 60
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(auth_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["id"] == 60
      assert msg["error"]["code"] == -32601
      assert msg["error"]["message"] == "Method not found: authenticate"

      AdapterBridge.close(bridge)
    end
  end

  describe "logout" do
    test "returns method-not-found for adapter without logout capability" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      logout_msg = %{"jsonrpc" => "2.0", "method" => "logout", "params" => %{}, "id" => 61}

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(logout_msg))

      {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)
      assert msg["id"] == 61
      assert msg["error"]["code"] == -32601

      AdapterBridge.close(bridge)
    end
  end

  describe "session/resume and session/close" do
    test "rejects unadvertised optional methods" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: MockAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      resume_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/resume",
        "params" => %{"sessionId" => "s1", "cwd" => "/tmp", "mcpServers" => []},
        "id" => 70
      }

      close_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/close",
        "params" => %{"sessionId" => "s1"},
        "id" => 71
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(resume_msg))
      assert {:ok, raw_resume} = AdapterBridge.receive_message(bridge, 5_000)
      resume_response = Jason.decode!(raw_resume)
      assert resume_response["id"] == 70
      assert resume_response["error"]["code"] == -32601

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(close_msg))
      assert {:ok, raw_close} = AdapterBridge.receive_message(bridge, 5_000)
      close_response = Jason.decode!(raw_close)
      assert close_response["id"] == 71
      assert close_response["error"]["code"] == -32601

      AdapterBridge.close(bridge)
    end
  end

  describe "session responses with modes and config_options" do
    # MockAdapter with modes and config_options
    defmodule EnhancedMockAdapter do
      @behaviour ExMCP.ACP.Adapter

      defstruct []

      @impl true
      def init(_opts), do: {:ok, %__MODULE__{}}

      @impl true
      def command(_opts), do: {"cat", []}

      @impl true
      def capabilities, do: %{"streaming" => true}

      @impl true
      def modes do
        [%{"id" => "code", "name" => "Code Mode"}]
      end

      @impl true
      def config_options do
        [
          %{
            "id" => "model",
            "name" => "Model",
            "category" => "model",
            "type" => "select",
            "currentValue" => "default",
            "options" => [%{"value" => "default", "name" => "Default"}]
          }
        ]
      end

      @impl true
      def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}
      def translate_outbound(_msg, state), do: {:ok, :skip, state}

      @impl true
      def translate_inbound(_line, state), do: {:skip, state}
    end

    test "includes modes and configOptions in session/new response" do
      {:ok, bridge} =
        AdapterBridge.start_link(adapter: EnhancedMockAdapter, adapter_opts: [])

      init = send_initialize(bridge)

      caps = init["result"]["agentCapabilities"]
      assert caps["streaming"] == true
      refute Map.has_key?(caps, "modes")
      refute Map.has_key?(caps, "configOptions")

      new_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/new",
        "params" => %{"cwd" => "/tmp", "mcpServers" => []},
        "id" => 80
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(new_msg))
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["result"]["modes"]["currentModeId"] == "code"
      assert hd(msg["result"]["modes"]["availableModes"])["id"] == "code"
      assert hd(msg["result"]["configOptions"])["id"] == "model"

      AdapterBridge.close(bridge)
    end
  end

  describe "adapter direct replies" do
    defmodule DirectReplyAdapter do
      @behaviour ExMCP.ACP.Adapter

      defstruct []

      @impl true
      def init(_opts), do: {:ok, %__MODULE__{}}

      @impl true
      def command(_opts), do: {"cat", []}

      @impl true
      def capabilities do
        %{
          "sessionCapabilities" => %{
            "delete" => %{}
          }
        }
      end

      @impl true
      def translate_outbound(%{"method" => "initialize"}, state), do: {:ok, :skip, state}

      def translate_outbound(%{"method" => "session/new"}, state) do
        {:reply, %{"sessionId" => "adapter-session", "extra" => true}, state}
      end

      def translate_outbound(%{"method" => "session/delete"}, state) do
        {:reply, %{"deleted" => true}, state}
      end

      def translate_outbound(
            %{"method" => "session/set_config_option", "params" => %{"configId" => "mode"}},
            state
          ) do
        options = [%{"id" => "mode"}]

        messages = [
          %{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "sessionId" => "adapter-session",
              "update" => %{
                "sessionUpdate" => "config_option_update",
                "configOptions" => options
              }
            }
          }
        ]

        {:messages_and_reply, messages, %{"configOptions" => options}, state}
      end

      def translate_outbound(%{"method" => "session/set_config_option"}, state) do
        data = Jason.encode!(%{"type" => "config_echo", "ok" => true}) <> "\n"
        {:reply_and_write, %{"configOptions" => [%{"id" => "model"}]}, data, state}
      end

      # The five-tuple from the Adapter contract: a notice to the client, a
      # reply, and a control line for the subprocess, all from one request.
      # This is the shape the Claude adapter's Auto-mode fallback returns.
      def translate_outbound(%{"method" => "session/set_mode"}, state) do
        messages = [
          %{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "sessionId" => "adapter-session",
              "update" => %{
                "sessionUpdate" => "agent_message_chunk",
                "content" => %{"type" => "text", "text" => "mode clamped"}
              }
            }
          }
        ]

        data = Jason.encode!(%{"type" => "config_echo", "clamped" => true}) <> "\n"
        {:messages_and_reply_and_write, messages, %{"modes" => %{}}, data, state}
      end

      def translate_outbound(_msg, state), do: {:ok, :skip, state}

      @impl true
      def translate_inbound(line, state) do
        case Jason.decode(String.trim(line)) do
          {:ok, %{"type" => "config_echo"}} ->
            {:messages,
             [
               %{
                 "jsonrpc" => "2.0",
                 "method" => "session/update",
                 "params" => %{
                   "sessionId" => "adapter-session",
                   "update" => %{"sessionUpdate" => "config_option_update", "configOptions" => []}
                 }
               }
             ], state}

          _ ->
            {:skip, state}
        end
      end
    end

    test "uses adapter-provided session/new result instead of synthesizing an id" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: DirectReplyAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      new_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/new",
        "params" => %{"cwd" => "/tmp"},
        "id" => 90
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(new_msg))
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["id"] == 90
      assert msg["result"]["sessionId"] == "adapter-session"
      assert msg["result"]["extra"] == true

      AdapterBridge.close(bridge)
    end

    test "supports session/delete when advertised" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: DirectReplyAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      delete_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/delete",
        "params" => %{"sessionId" => "adapter-session"},
        "id" => 91
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(delete_msg))
      assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
      msg = Jason.decode!(raw)

      assert msg["id"] == 91
      assert msg["result"] == %{"deleted" => true}

      AdapterBridge.close(bridge)
    end

    test "messages_and_reply emits config update and responds to config option requests" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: DirectReplyAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      config_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_config_option",
        "params" => %{
          "sessionId" => "adapter-session",
          "configId" => "mode",
          "value" => "agent"
        },
        "id" => 93
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(config_msg))
      assert {:ok, raw_update} = AdapterBridge.receive_message(bridge, 5_000)
      update = Jason.decode!(raw_update)
      assert update["method"] == "session/update"
      assert update["params"]["update"]["configOptions"] == [%{"id" => "mode"}]

      assert {:ok, raw_response} = AdapterBridge.receive_message(bridge, 5_000)
      response = Jason.decode!(raw_response)
      assert response["id"] == 93
      assert response["result"]["configOptions"] == [%{"id" => "mode"}]

      AdapterBridge.close(bridge)
    end

    test "reply_and_write responds and still forwards data to the subprocess" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: DirectReplyAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      config_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_config_option",
        "params" => %{
          "sessionId" => "adapter-session",
          "configId" => "model",
          "value" => "sonnet"
        },
        "id" => 92
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(config_msg))
      assert {:ok, raw_response} = AdapterBridge.receive_message(bridge, 5_000)
      response = Jason.decode!(raw_response)
      assert response["id"] == 92
      assert response["result"]["configOptions"] == [%{"id" => "model"}]

      assert {:ok, raw_update} = AdapterBridge.receive_message(bridge, 5_000)
      update = Jason.decode!(raw_update)
      assert update["method"] == "session/update"
      assert update["params"]["update"]["sessionUpdate"] == "config_option_update"

      AdapterBridge.close(bridge)
    end

    # Regression: the five-tuple is part of the Adapter contract but only the
    # session lifecycle path implemented it, so returning it from any other
    # method raised a FunctionClauseError in the bridge and killed the
    # connection. The golden adapter suites cannot catch this: they drive the
    # adapter directly and never go through AdapterBridge.
    test "messages_and_reply_and_write replies, notifies, and forwards data" do
      {:ok, bridge} = AdapterBridge.start_link(adapter: DirectReplyAdapter, adapter_opts: [])
      _init = send_initialize(bridge)

      mode_msg = %{
        "jsonrpc" => "2.0",
        "method" => "session/set_mode",
        "params" => %{"sessionId" => "adapter-session", "modeId" => "auto"},
        "id" => 93
      }

      assert :ok = AdapterBridge.send_message(bridge, Jason.encode!(mode_msg))

      messages =
        Enum.map(1..3, fn _ ->
          assert {:ok, raw} = AdapterBridge.receive_message(bridge, 5_000)
          Jason.decode!(raw)
        end)

      # The reply carries the result.
      assert Enum.any?(messages, &(&1["id"] == 93 and is_map(&1["result"]["modes"])))

      # The adapter's own notice reaches the client.
      assert Enum.any?(messages, fn m ->
               get_in(m, ["params", "update", "content", "text"]) == "mode clamped"
             end)

      # The control line reached the subprocess, which echoed it back through
      # translate_inbound.
      assert Enum.any?(messages, fn m ->
               get_in(m, ["params", "update", "sessionUpdate"]) == "config_option_update"
             end)

      AdapterBridge.close(bridge)
    end
  end
end
