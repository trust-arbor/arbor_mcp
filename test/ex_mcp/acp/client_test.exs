defmodule ExMCP.ACP.ClientTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Client
  alias ExMCP.ACP.Client.DefaultHandler
  alias ExMCP.ACP.Protocol

  # MessageRelay: a simple process-based mailbox shared between mock agent and transport.
  # Agent pushes messages in, transport's receive_message pops them out.
  defmodule MessageRelay do
    use GenServer

    def start_link do
      GenServer.start_link(__MODULE__, [])
    end

    def push(relay, message) do
      GenServer.cast(relay, {:push, message})
    end

    def pop(relay, timeout \\ 30_000) do
      GenServer.call(relay, :pop, timeout)
    end

    @impl true
    def init([]) do
      {:ok, %{queue: :queue.new(), waiters: :queue.new()}}
    end

    @impl true
    def handle_cast({:push, message}, state) do
      case :queue.out(state.waiters) do
        {{:value, from}, rest} ->
          GenServer.reply(from, {:ok, message})
          {:noreply, %{state | waiters: rest}}

        {:empty, _} ->
          {:noreply, %{state | queue: :queue.in(message, state.queue)}}
      end
    end

    @impl true
    def handle_call(:pop, from, state) do
      case :queue.out(state.queue) do
        {{:value, message}, rest} ->
          {:reply, {:ok, message}, %{state | queue: rest}}

        {:empty, _} ->
          {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
      end
    end

    @impl true
    def handle_call(:stop, _from, state) do
      # Reply to all waiters with error
      flush_waiters(state.waiters)
      {:stop, :normal, :ok, state}
    end

    defp flush_waiters(waiters) do
      case :queue.out(waiters) do
        {{:value, from}, rest} ->
          GenServer.reply(from, {:error, :closed})
          flush_waiters(rest)

        {:empty, _} ->
          :ok
      end
    end
  end

  # MockACPTransport: uses MessageRelay for agent→client messages.
  defmodule MockACPTransport do
    @behaviour ExMCP.Transport

    @initialize_noise ~s({"jsonrpc":"2.0","method":"session/update","params":{}})

    defstruct [
      :agent_pid,
      :to_client_relay,
      :to_agent_relay,
      :close_listener,
      initialize_noise: false
    ]

    @impl true
    def connect(opts) do
      agent_pid = Keyword.fetch!(opts, :agent_pid)
      to_client_relay = Keyword.fetch!(opts, :to_client_relay)
      to_agent_relay = Keyword.fetch!(opts, :to_agent_relay)
      close_listener = Keyword.get(opts, :close_listener)

      {:ok,
       %__MODULE__{
         agent_pid: agent_pid,
         to_client_relay: to_client_relay,
         to_agent_relay: to_agent_relay,
         close_listener: close_listener,
         initialize_noise: Keyword.get(opts, :initialize_noise, false)
       }}
    end

    @impl true
    def send_message(message, %__MODULE__{to_agent_relay: relay} = state) do
      MessageRelay.push(relay, message)
      {:ok, state}
    end

    @impl true
    def receive_message(%__MODULE__{initialize_noise: true} = state),
      do: {:ok, @initialize_noise, state}

    def receive_message(%__MODULE__{to_client_relay: relay} = state) do
      case MessageRelay.pop(relay) do
        {:ok, message} -> {:ok, message, state}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def close(%__MODULE__{close_listener: listener}) do
      if is_pid(listener), do: send(listener, :mock_acp_transport_closed)
      :ok
    end

    @impl true
    def connected?(%__MODULE__{agent_pid: pid}) do
      is_pid(pid) and Process.alive?(pid)
    end
  end

  # MockACPAgent: reads from to_agent_relay, writes to to_client_relay.
  defmodule MockACPAgent do
    def start(to_client_relay, to_agent_relay, opts \\ []) do
      test_pid = self()
      updates = Keyword.get(opts, :updates, [])
      load_updates = Keyword.get(opts, :load_updates, [])
      permission_request = Keyword.get(opts, :permission_request)
      cancel_permission_request = Keyword.get(opts, :cancel_permission_request, false)
      agent_request = Keyword.get(opts, :agent_request)
      protocol_version = Keyword.get(opts, :protocol_version, 1)
      initialize_delay_ms = Keyword.get(opts, :initialize_delay_ms, 0)
      ignore_method = Keyword.get(opts, :ignore_method)

      capabilities =
        Keyword.get(opts, :capabilities, %{
          "streaming" => true,
          "loadSession" => true,
          "sessionCapabilities" => %{
            "list" => %{},
            "resume" => %{},
            "close" => %{},
            "delete" => %{},
            "fork" => %{},
            "additionalDirectories" => %{}
          },
          "auth" => %{"logout" => %{}}
        })

      auth_methods =
        Keyword.get(opts, :auth_methods, [
          %{"id" => "api-key", "name" => "API Key"}
        ])

      spawn_link(fn ->
        loop(%{
          to_client: to_client_relay,
          to_agent: to_agent_relay,
          updates: updates,
          load_updates: load_updates,
          permission_request: permission_request,
          cancel_permission_request: cancel_permission_request,
          agent_request: agent_request,
          protocol_version: protocol_version,
          initialize_delay_ms: initialize_delay_ms,
          ignore_method: ignore_method,
          capabilities: capabilities,
          auth_methods: auth_methods,
          test_pid: test_pid
        })
      end)
    end

    defp loop(state) do
      case MessageRelay.pop(state.to_agent) do
        {:ok, json} ->
          msg = Jason.decode!(json)
          handle_message(msg, state)
          loop(state)

        {:error, _} ->
          :ok
      end
    end

    defp handle_message(%{"method" => method}, %{ignore_method: method} = state) do
      send(state.test_pid, {:ignored_request, method})
      :ok
    end

    defp handle_message(%{"method" => "initialize", "id" => id} = msg, state) do
      send(state.test_pid, {:initialize_request, msg["params"] || %{}})
      Process.sleep(state.initialize_delay_ms)

      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{
            "agentInfo" => %{"name" => "mock_agent", "version" => "1.0.0"},
            "agentCapabilities" => state.capabilities,
            "authMethods" => state.auth_methods,
            "protocolVersion" => state.protocol_version
          },
          "id" => id
        })

      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/new", "id" => id, "params" => params}, state) do
      send(state.test_pid, {:new_session_request, params})

      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{"sessionId" => "sess_mock_001"},
          "id" => id
        })

      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "authenticate", "id" => id, "params" => params}, state) do
      send(state.test_pid, {:authenticate_request, params})
      response = Jason.encode!(Protocol.encode_response(%{}, id))
      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "logout", "id" => id}, state) do
      send(state.test_pid, :logout_request)
      response = Jason.encode!(Protocol.encode_response(%{}, id))
      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/load", "id" => id, "params" => params}, state) do
      send(state.test_pid, {:load_session_request, params})
      session_id = params["sessionId"]

      for update <- state.load_updates do
        notification =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "sessionId" => session_id,
              "update" => update
            }
          })

        MessageRelay.push(state.to_client, notification)
      end

      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{"sessionId" => "sess_loaded_001"},
          "id" => id
        })

      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/resume", "id" => id, "params" => params}, state) do
      send(state.test_pid, {:resume_session_request, params})

      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{"modes" => nil, "configOptions" => nil},
          "id" => id
        })

      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/fork", "id" => id, "params" => params}, state) do
      send(state.test_pid, {:fork_session_request, params})

      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{"sessionId" => "sess_forked_001", "modes" => nil, "configOptions" => nil},
          "id" => id
        })

      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/list", "id" => id, "params" => params}, state) do
      send(state.test_pid, {:list_sessions_request, params})

      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{
            "sessions" => [
              %{
                "sessionId" => "sess_mock_001",
                "cwd" => "/tmp/project",
                "title" => "Mock session"
              }
            ]
          },
          "id" => id
        })

      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/prompt", "id" => id, "params" => params}, state) do
      session_id = params["sessionId"]

      # Send queued session/update notifications
      for update <- state.updates do
        notification =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => %{
              "sessionId" => session_id,
              "update" => update
            }
          })

        MessageRelay.push(state.to_client, notification)
      end

      # Optionally send a permission request
      if state.permission_request do
        {tool_call, options} = state.permission_request
        perm_id = System.unique_integer([:positive])

        perm_request =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "session/request_permission",
            "params" => %{
              "sessionId" => session_id,
              "toolCall" => tool_call,
              "options" => options
            },
            "id" => perm_id
          })

        MessageRelay.push(state.to_client, perm_request)

        if state.cancel_permission_request do
          cancel_request = Jason.encode!(Protocol.encode_cancel_request(perm_id))
          MessageRelay.push(state.to_client, cancel_request)
        end

        # Wait for the permission response
        case MessageRelay.pop(state.to_agent) do
          {:ok, json} ->
            resp = Jason.decode!(json)
            send(state.test_pid, {:permission_response, resp})

          {:error, _} ->
            :ok
        end
      end

      if state.agent_request do
        {method, request_params} = state.agent_request
        request_id = System.unique_integer([:positive])

        request =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => method,
            "params" => Map.put_new(request_params, "sessionId", session_id),
            "id" => request_id
          })

        MessageRelay.push(state.to_client, request)

        case MessageRelay.pop(state.to_agent) do
          {:ok, json} ->
            send(state.test_pid, {:agent_request_response, Jason.decode!(json)})

          {:error, _reason} ->
            :ok
        end
      end

      # Send the prompt result
      response =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "result" => %{"stopReason" => "end_turn"},
          "id" => id
        })

      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/cancel"}, _state) do
      :ok
    end

    defp handle_message(%{"method" => "session/close", "id" => id}, state) do
      send(state.test_pid, :close_session_request)
      response = Jason.encode!(Protocol.encode_response(%{}, id))
      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/delete", "id" => id}, state) do
      send(state.test_pid, :delete_session_request)
      response = Jason.encode!(Protocol.encode_response(%{}, id))
      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/set_mode", "id" => id}, state) do
      response = Jason.encode!(Protocol.encode_response(%{}, id))
      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(%{"method" => "session/set_config_option", "id" => id}, state) do
      response = Jason.encode!(Protocol.encode_response(%{}, id))
      MessageRelay.push(state.to_client, response)
    end

    defp handle_message(_msg, _state), do: :ok
  end

  defmodule BlockingUpdateHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent)}}

    @impl true
    def handle_session_update(_session_id, update, state) do
      send(state.parent, {:blocking_update_handler_started, self(), update})

      receive do
        :release_update_handler -> {:ok, state}
      after
        5_000 -> {:ok, state}
      end
    end

    @impl true
    def handle_permission_request(_session_id, _tool_call, options, state) do
      option = List.first(options) || %{"optionId" => "allow"}
      {:ok, %{"outcome" => "selected", "optionId" => option["optionId"]}, state}
    end
  end

  defmodule BlockingPermissionHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent)}}

    @impl true
    def handle_session_update(_session_id, _update, state), do: {:ok, state}

    @impl true
    def handle_permission_request(_session_id, _tool_call, options, state) do
      send(state.parent, {:blocking_permission_handler_started, self()})

      receive do
        :release_permission_handler ->
          option = List.first(options) || %{"optionId" => "allow"}
          {:ok, %{"outcome" => "selected", "optionId" => option["optionId"]}, state}
      after
        5_000 ->
          {:ok, %{"outcome" => "cancelled"}, state}
      end
    end
  end

  # Handler that implements file_read but NOT file_write or terminal.
  # Used to assert capability auto-advertisement reflects per-callback support.
  defmodule FileReadOnlyHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_session_update(_session_id, _update, state), do: {:ok, state}

    @impl true
    def handle_permission_request(_session_id, _tool_call, _options, state) do
      {:ok, %{"outcome" => "cancelled"}, state}
    end

    @impl true
    def handle_file_read(_session_id, _path, _opts, state) do
      {:ok, "file content", state}
    end
  end

  # Handler that implements file_read, file_write, AND terminal.
  defmodule FullCapabilityHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_session_update(_session_id, _update, state), do: {:ok, state}

    @impl true
    def handle_permission_request(_session_id, _tool_call, _options, state) do
      {:ok, %{"outcome" => "cancelled"}, state}
    end

    @impl true
    def handle_file_read(_session_id, _path, _opts, state) do
      {:ok, "content", state}
    end

    @impl true
    def handle_file_write(_session_id, _path, _content, state) do
      {:ok, state}
    end

    @impl true
    def handle_terminal_request(_session_id, _method, _params, state) do
      {:ok, %{}, state}
    end
  end

  defmodule FormElicitationHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_session_update(_session_id, _update, state), do: {:ok, state}

    @impl true
    def handle_permission_request(_session_id, _tool_call, _options, state) do
      {:ok, %{"outcome" => "cancelled"}, state}
    end

    @impl true
    def handle_form_elicitation(params, state) do
      value = get_in(params, ["requestedSchema", "properties", "choice", "default"]) || "blue"
      {:ok, %{"action" => "accept", "content" => %{"choice" => value}}, state}
    end
  end

  defp start_client(agent_opts \\ [], client_opts \\ []) do
    {:ok, to_client_relay} = MessageRelay.start_link()
    {:ok, to_agent_relay} = MessageRelay.start_link()

    agent_pid = MockACPAgent.start(to_client_relay, to_agent_relay, agent_opts)

    {:ok, client} =
      Client.start_link(
        [
          transport_mod: MockACPTransport,
          command: ["mock"],
          agent_pid: agent_pid,
          to_client_relay: to_client_relay,
          to_agent_relay: to_agent_relay
        ] ++ client_opts
      )

    {client, agent_pid}
  end

  defp session_update_frame(session_id, text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  describe "initialize handshake" do
    test "stores agent capabilities" do
      {client, _agent} = start_client()

      assert {:ok, caps} = Client.agent_capabilities(client)
      assert caps["streaming"] == true
      assert caps["sessionCapabilities"]["resume"] == %{}

      assert {:ok, auth_methods} = Client.auth_methods(client)
      assert [%{"id" => "api-key"}] = auth_methods

      assert Client.status(client) == :ready
    end

    test "honors a configurable total initialize timeout and closes the transport" do
      {:ok, to_client_relay} = MessageRelay.start_link()
      {:ok, to_agent_relay} = MessageRelay.start_link()
      silent_agent = spawn_link(fn -> Process.sleep(:infinity) end)
      test_pid = self()

      assert {:error, :init_timeout} =
               Task.async(fn ->
                 Process.flag(:trap_exit, true)

                 Client.start_link(
                   transport_mod: MockACPTransport,
                   command: ["mock"],
                   agent_pid: silent_agent,
                   to_client_relay: to_client_relay,
                   to_agent_relay: to_agent_relay,
                   close_listener: test_pid,
                   initialize_timeout: 20
                 )
               end)
               |> Task.await()

      assert_receive :mock_acp_transport_closed, 200
    end

    test "unrelated initialize traffic cannot extend the total timeout" do
      {:ok, to_client_relay} = MessageRelay.start_link()
      {:ok, to_agent_relay} = MessageRelay.start_link()
      test_pid = self()

      assert {:error, :init_timeout} =
               Task.async(fn ->
                 Process.flag(:trap_exit, true)

                 Client.start_link(
                   transport_mod: MockACPTransport,
                   command: ["mock"],
                   agent_pid: self(),
                   to_client_relay: to_client_relay,
                   to_agent_relay: to_agent_relay,
                   close_listener: test_pid,
                   initialize_noise: true,
                   initialize_timeout: 20
                 )
               end)
               |> Task.await(1_000)

      assert_receive :mock_acp_transport_closed, 200
    end

    test "accepts a delayed initialize response within the configured budget" do
      {client, _agent} =
        start_client([initialize_delay_ms: 40], initialize_timeout: 200)

      assert Client.status(client) == :ready
    end

    test "rejects initialize responses with a missing protocolVersion" do
      {:ok, to_client_relay} = MessageRelay.start_link()
      {:ok, to_agent_relay} = MessageRelay.start_link()

      agent_pid =
        MockACPAgent.start(to_client_relay, to_agent_relay, protocol_version: nil)

      assert {:error, :invalid_initialize_protocol_version} =
               Task.async(fn ->
                 Process.flag(:trap_exit, true)

                 Client.start_link(
                   transport_mod: MockACPTransport,
                   command: ["mock"],
                   agent_pid: agent_pid,
                   to_client_relay: to_client_relay,
                   to_agent_relay: to_agent_relay
                 )
               end)
               |> Task.await()
    end

    test "rejects invalid initialize timeout values before opening the transport" do
      {:ok, to_client_relay} = MessageRelay.start_link()
      {:ok, to_agent_relay} = MessageRelay.start_link()

      for timeout <- [0, 4_294_967_296] do
        assert {:error, :invalid_initialize_timeout} =
                 Task.async(fn ->
                   Process.flag(:trap_exit, true)

                   Client.start_link(
                     transport_mod: MockACPTransport,
                     command: ["mock"],
                     agent_pid: self(),
                     to_client_relay: to_client_relay,
                     to_agent_relay: to_agent_relay,
                     initialize_timeout: timeout
                   )
                 end)
                 |> Task.await()
      end

      refute_receive :mock_acp_transport_closed, 50
    end
  end

  # spec regression: ACP spec
  # (https://agentclientprotocol.com/protocol/initialization) states:
  # "capabilities omitted in the initialize request MUST be treated as
  # UNSUPPORTED." So if the client never advertises
  # `clientCapabilities.fs.readTextFile`, the agent MUST NOT call
  # `fs/read_text_file` — even if the client's handler is fully capable
  # of answering it.
  #
  # The previous implementation only set these capabilities from manually
  # passed `:capabilities` opts. A user wiring up a handler that exports
  # `handle_file_read/4` but forgetting to manually advertise the
  # capability would get a silently broken integration: the handler is
  # ready, but the agent never asks. The fix is to auto-advertise FS and
  # terminal capabilities based on the handler's exported callbacks.
  describe "spec regression: capability auto-advertisement from handler exports" do
    test "advertises fs.readTextFile when handler exports handle_file_read/4" do
      {_client, _agent} =
        start_client([],
          handler: FileReadOnlyHandler,
          handler_opts: []
        )

      assert_receive {:initialize_request, params}, 5_000

      caps = params["clientCapabilities"] || %{}

      assert get_in(caps, ["fs", "readTextFile"]) == true,
             "Handler exports handle_file_read/4 but client did not advertise " <>
               "clientCapabilities.fs.readTextFile. Per spec, the agent will treat " <>
               "fs/read_text_file as unsupported. Auto-advertise based on " <>
               "function_exported?(handler, :handle_file_read, 4). Got: #{inspect(caps)}"
    end

    test "does NOT advertise fs.writeTextFile when handler does not export handle_file_write/4" do
      {_client, _agent} =
        start_client([],
          handler: FileReadOnlyHandler,
          handler_opts: []
        )

      assert_receive {:initialize_request, params}, 5_000

      caps = params["clientCapabilities"] || %{}

      # Per spec, omitted == unsupported. So either absent or explicitly false is fine;
      # `true` would be a lie (handler can't answer).
      refute get_in(caps, ["fs", "writeTextFile"]) == true,
             "Client advertised fs.writeTextFile but handler does not export " <>
               "handle_file_write/4. Auto-advertisement must reflect actual handler support."
    end

    test "does NOT advertise terminal when handler does not export handle_terminal_request/4" do
      {_client, _agent} =
        start_client([],
          handler: FileReadOnlyHandler,
          handler_opts: []
        )

      assert_receive {:initialize_request, params}, 5_000
      caps = params["clientCapabilities"] || %{}

      refute caps["terminal"] == true,
             "Client advertised terminal but handler does not export " <>
               "handle_terminal_request/4."
    end

    test "advertises fs.readTextFile, fs.writeTextFile, and terminal when handler exports all three" do
      {_client, _agent} =
        start_client([],
          handler: FullCapabilityHandler,
          handler_opts: []
        )

      assert_receive {:initialize_request, params}, 5_000
      caps = params["clientCapabilities"] || %{}

      assert get_in(caps, ["fs", "readTextFile"]) == true
      assert get_in(caps, ["fs", "writeTextFile"]) == true
      assert caps["terminal"] == true
    end

    test "advertises only the elicitation modes implemented by the handler" do
      {_client, _agent} =
        start_client([],
          handler: FormElicitationHandler,
          handler_opts: []
        )

      assert_receive {:initialize_request, params}, 5_000
      caps = params["clientCapabilities"] || %{}

      assert get_in(caps, ["elicitation", "form"]) == %{}
      assert get_in(caps, ["elicitation", "url"]) == nil
    end

    test "explicit :capabilities opt overrides auto-advertisement" do
      # If the caller explicitly passes :capabilities, that wins. The
      # auto-advertisement is a sensible default, not a forced policy.
      {_client, _agent} =
        start_client([],
          handler: FileReadOnlyHandler,
          handler_opts: [],
          capabilities: %{"fs" => %{"readTextFile" => false}}
        )

      assert_receive {:initialize_request, params}, 5_000

      assert get_in(params["clientCapabilities"], ["fs", "readTextFile"]) == false,
             "Explicit :capabilities opt must override auto-advertisement."
    end
  end

  describe "inbound agent request hardening" do
    test "dispatches an advertised form elicitation and returns accepted content" do
      {client, _agent} =
        start_client(
          [
            agent_request:
              {"elicitation/create",
               %{
                 "mode" => "form",
                 "message" => "Choose",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{
                     "choice" => %{"type" => "string", "default" => "green"}
                   }
                 }
               }}
          ],
          handler: FormElicitationHandler
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "choose")

      assert_receive {:agent_request_response, response}
      assert response["result"] == %{"action" => "accept", "content" => %{"choice" => "green"}}
    end

    test "rejects filesystem requests not advertised during initialize" do
      {client, _agent} =
        start_client(
          [agent_request: {"fs/read_text_file", %{"path" => "/tmp/file.txt"}}],
          handler: FullCapabilityHandler,
          capabilities: %{}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "read")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["code"] == -32_601
    end

    test "rejects relative filesystem paths before invoking the handler" do
      {client, _agent} =
        start_client(
          [agent_request: {"fs/read_text_file", %{"path" => "relative.txt"}}],
          handler: FullCapabilityHandler,
          capabilities: %{"fs" => %{"readTextFile" => true}}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "read")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["code"] == -32_602
    end

    test "rejects the non-1-based read_text_file line zero" do
      {client, _agent} =
        start_client(
          [agent_request: {"fs/read_text_file", %{"path" => "/tmp/file.txt", "line" => 0}}],
          handler: FullCapabilityHandler,
          capabilities: %{"fs" => %{"readTextFile" => true}}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "read")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["code"] == -32_602
    end

    test "rejects sensitive requests for a session not established by this client" do
      {client, _agent} =
        start_client(
          [
            agent_request:
              {"fs/read_text_file",
               %{
                 "sessionId" => "attacker-session",
                 "path" => "/tmp/file.txt"
               }}
          ],
          handler: FullCapabilityHandler,
          capabilities: %{"fs" => %{"readTextFile" => true}}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "read")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["code"] == -32_602
      assert error["message"] == "Unknown session"
    end

    test "rejects filesystem requests outside the established session roots" do
      {client, _agent} =
        start_client(
          [agent_request: {"fs/read_text_file", %{"path" => "/etc/passwd"}}],
          handler: FullCapabilityHandler,
          capabilities: %{"fs" => %{"readTextFile" => true}}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "read")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["code"] == -32_602
      assert error["message"] == "Path is outside the session workspace"
    end

    test "resolves existing symlinks before authorizing a filesystem path" do
      root =
        Path.join(System.tmp_dir!(), "ex_mcp_acp_root_#{System.unique_integer([:positive])}")

      outside =
        Path.join(System.tmp_dir!(), "ex_mcp_acp_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(root, "escape"))

      on_exit(fn ->
        File.rm_rf!(root)
        File.rm_rf!(outside)
      end)

      {client, _agent} =
        start_client(
          [agent_request: {"fs/read_text_file", %{"path" => Path.join(root, "escape/new.txt")}}],
          handler: FullCapabilityHandler,
          capabilities: %{"fs" => %{"readTextFile" => true}}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, root)
      assert {:ok, _result} = Client.prompt(client, session_id, "read")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["message"] == "Path is outside the session workspace"
    end

    test "allows a nonexistent path below an established session root" do
      {client, _agent} =
        start_client(
          [agent_request: {"fs/read_text_file", %{"path" => "/tmp/not-created-yet/file.txt"}}],
          handler: FullCapabilityHandler,
          capabilities: %{"fs" => %{"readTextFile" => true}}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "read")

      assert_receive {:agent_request_response, %{"result" => %{"content" => "content"}}}
    end

    test "rejects terminal working directories outside the established session roots" do
      {client, _agent} =
        start_client(
          [agent_request: {"terminal/create", %{"command" => "echo", "cwd" => "/etc"}}],
          handler: FullCapabilityHandler,
          capabilities: %{"terminal" => true}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "terminal")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["message"] == "Path is outside the session workspace"
    end

    test "rejects unknown terminal methods even when terminal support was advertised" do
      {client, _agent} =
        start_client(
          [agent_request: {"terminal/arbitrary", %{}}],
          handler: FullCapabilityHandler,
          capabilities: %{"terminal" => true}
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      assert {:ok, _result} = Client.prompt(client, session_id, "terminal")

      assert_receive {:agent_request_response, %{"error" => error}}
      assert error["code"] == -32_601
    end
  end

  describe "authenticate/3 and logout/2" do
    test "authenticate sends stable methodId params" do
      {client, _agent} = start_client()

      assert {:ok, %{}} = Client.authenticate(client, "api-key")
      assert_receive {:authenticate_request, %{"methodId" => "api-key"}}, 5_000
    end

    test "logout requires and uses auth.logout capability" do
      {client, _agent} = start_client()

      assert {:ok, %{}} = Client.logout(client)
      assert_receive :logout_request, 5_000
    end

    test "logout returns unsupported when capability is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert {:error, {:unsupported_capability, :logout}} = Client.logout(client)
      refute_receive :logout_request, 100
    end
  end

  describe "new_session/3" do
    test "returns session ID" do
      {client, _agent} = start_client()

      assert {:ok, result} = Client.new_session(client, "/tmp/project")
      assert result["sessionId"] == "sess_mock_001"
    end

    test "sends additionalDirectories when provided" do
      {client, _agent} = start_client()

      assert {:ok, _result} =
               Client.new_session(client, "/tmp/project",
                 additional_directories: ["/tmp/shared"],
                 mcp_servers: []
               )

      assert_receive {:new_session_request,
                      %{
                        "cwd" => "/tmp/project",
                        "additionalDirectories" => ["/tmp/shared"],
                        "mcpServers" => []
                      }},
                     5_000
    end

    test "rejects additionalDirectories when capability is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert {:error, {:unsupported_capability, :additional_directories}} =
               Client.new_session(client, "/tmp/project", additional_directories: ["/tmp/shared"])

      refute_receive {:new_session_request, _params}, 100
    end
  end

  describe "load_session/4" do
    test "returns loaded session ID" do
      {client, _agent} = start_client()

      assert {:ok, result} = Client.load_session(client, "old_session_123", "/tmp")
      assert result["sessionId"] == "sess_loaded_001"
    end

    test "sends additionalDirectories when provided" do
      {client, _agent} = start_client()

      assert {:ok, _result} =
               Client.load_session(client, "old_session_123", "/tmp",
                 additional_directories: ["/tmp/shared"]
               )

      assert_receive {:load_session_request,
                      %{
                        "sessionId" => "old_session_123",
                        "cwd" => "/tmp",
                        "additionalDirectories" => ["/tmp/shared"]
                      }},
                     5_000
    end
  end

  describe "resume_session/4" do
    test "returns resume result when capability is advertised" do
      {client, _agent} = start_client()

      assert {:ok, result} = Client.resume_session(client, "old_session_123", "/tmp")
      assert Map.has_key?(result, "modes")
    end

    test "sends additionalDirectories when provided" do
      {client, _agent} = start_client()

      assert {:ok, _result} =
               Client.resume_session(client, "old_session_123", "/tmp",
                 additional_directories: ["/tmp/shared"]
               )

      assert_receive {:resume_session_request,
                      %{
                        "sessionId" => "old_session_123",
                        "cwd" => "/tmp",
                        "additionalDirectories" => ["/tmp/shared"]
                      }},
                     5_000
    end

    test "returns unsupported when capability is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert {:error, {:unsupported_capability, :session_resume}} =
               Client.resume_session(client, "old_session_123", "/tmp")
    end
  end

  describe "fork_session/4" do
    test "returns forked session when capability is advertised" do
      {client, _agent} = start_client()

      assert {:ok, result} = Client.fork_session(client, "old_session_123", "/tmp")
      assert result["sessionId"] == "sess_forked_001"
    end

    test "sends additionalDirectories when provided" do
      {client, _agent} = start_client()

      assert {:ok, _result} =
               Client.fork_session(client, "old_session_123", "/tmp",
                 additional_directories: ["/tmp/shared"]
               )

      assert_receive {:fork_session_request,
                      %{
                        "sessionId" => "old_session_123",
                        "cwd" => "/tmp",
                        "additionalDirectories" => ["/tmp/shared"]
                      }},
                     5_000
    end

    test "returns unsupported when capability is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert {:error, {:unsupported_capability, :session_fork}} =
               Client.fork_session(client, "old_session_123", "/tmp")
    end
  end

  describe "list_sessions/2" do
    test "sends cursor and cwd filters when capability is advertised" do
      {client, _agent} = start_client()

      assert {:ok, %{"sessions" => [session]}} =
               Client.list_sessions(client, cursor: "page-2", cwd: "/tmp/project")

      assert session["sessionId"] == "sess_mock_001"

      assert_receive {:list_sessions_request, %{"cursor" => "page-2", "cwd" => "/tmp/project"}},
                     5_000
    end

    test "omits additionalDirectories filter for SDK-compatible schema" do
      {client, _agent} = start_client()

      assert {:ok, %{"sessions" => [_session]}} =
               Client.list_sessions(client,
                 cwd: "/tmp/project",
                 additional_directories: ["/tmp/shared"]
               )

      assert_receive {:list_sessions_request, %{"cwd" => "/tmp/project"}}, 5_000
    end

    test "returns unsupported when capability is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert {:error, {:unsupported_capability, :session_list}} = Client.list_sessions(client)
    end
  end

  describe "prompt/4" do
    test "blocks until response with streaming events" do
      updates = [
        %{
          "sessionUpdate" => "session_info_update",
          "_meta" => %{"status" => "working"}
        },
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "I'll fix that bug."}
        }
      ]

      {client, _agent} = start_client(updates: updates)

      {:ok, _} = Client.new_session(client, "/tmp")
      assert {:ok, result} = Client.prompt(client, "sess_mock_001", "Fix the bug")
      assert result["stopReason"] == "end_turn"
    end

    test "handler receives streaming events" do
      updates = [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Working on it..."}
        }
      ]

      {client, _agent} = start_client(updates: updates)

      {:ok, _} = Client.new_session(client, "/tmp")
      {:ok, _} = Client.prompt(client, "sess_mock_001", "Do something")

      assert Client.status(client) == :ready
    end

    test "slow session update handlers do not block prompt completion or event listener" do
      updates = [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "streamed"}
        }
      ]

      {client, _agent} =
        start_client(
          [updates: updates],
          handler: BlockingUpdateHandler,
          handler_opts: [parent: self()],
          event_listener: self()
        )

      {:ok, _} = Client.new_session(client, "/tmp")

      task =
        Task.async(fn ->
          Client.prompt(client, "sess_mock_001", "Do something", timeout: 1_000)
        end)

      assert_receive {:acp_session_update, "sess_mock_001", update}, 500
      assert update["sessionUpdate"] == "agent_message_chunk"
      assert_receive {:blocking_update_handler_started, handler_pid, ^update}, 500

      assert {:ok, %{"text" => "streamed"}} = Task.await(task, 1_000)
      send(handler_pid, :release_update_handler)
    end

    test "accepts string content" do
      {client, _agent} = start_client()

      {:ok, _} = Client.new_session(client, "/tmp")
      assert {:ok, _} = Client.prompt(client, "sess_mock_001", "Hello agent")
    end

    test "accepts block list content" do
      {client, _agent} = start_client()

      {:ok, _} = Client.new_session(client, "/tmp")
      blocks = [%{"type" => "text", "text" => "Hello"}]
      assert {:ok, _} = Client.prompt(client, "sess_mock_001", blocks)
    end

    test "rejects non-string non-list content" do
      {client, _agent} = start_client()

      {:ok, _} = Client.new_session(client, "/tmp")

      assert {:error, {:invalid_params, :prompt_must_be_a_list}} =
               Client.prompt(client, "sess_mock_001", %{"type" => "text", "text" => "Hello"})
    end

    test "rejects image blocks when prompt capability is not advertised" do
      {client, _agent} = start_client()

      {:ok, _} = Client.new_session(client, "/tmp")

      assert {:error, {:unsupported_capability, {:prompt, :image}}} =
               Client.prompt(client, "sess_mock_001", [
                 %{"type" => "image", "mimeType" => "image/png", "data" => "abc"}
               ])
    end

    test "merges streamed agent_message_chunk text into the prompt result" do
      # Agents like grok stream the answer via session/update agent_message_chunk
      # rather than returning it in the prompt result. The client must accumulate
      # that text and surface it as result["text"]; thought chunks are excluded.
      updates = [
        %{
          "sessionUpdate" => "agent_thought_chunk",
          "content" => %{"type" => "text", "text" => "thinking"}
        },
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Hello "}
        },
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "world."}
        }
      ]

      {client, _agent} = start_client(updates: updates)
      {:ok, _} = Client.new_session(client, "/tmp")

      assert {:ok, result} = Client.prompt(client, "sess_mock_001", "hi")
      assert result["text"] == "Hello world."
    end

    test "ignores agent_message_chunk text when no prompt is pending" do
      load_updates = [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "history "}
        }
      ]

      prompt_updates = [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "fresh"}
        }
      ]

      {client, _agent} = start_client(load_updates: load_updates, updates: prompt_updates)

      assert {:ok, %{"sessionId" => "sess_loaded_001"}} =
               Client.load_session(client, "sess_mock_001", "/tmp/project")

      assert {:ok, %{"stopReason" => "end_turn", "text" => "fresh"}} =
               Client.prompt(client, "sess_mock_001", "hello")
    end
  end

  describe "cancel/2" do
    test "sends notification without blocking" do
      {client, _agent} = start_client()

      assert :ok = Client.cancel(client, "sess_mock_001")
    end
  end

  describe "close_session/3" do
    test "sends close request when capability is advertised" do
      {client, _agent} = start_client()

      assert {:ok, %{}} = Client.close_session(client, "sess_mock_001")
      assert_receive :close_session_request, 5_000
    end

    test "returns unsupported when capability is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert {:error, {:unsupported_capability, :session_close}} =
               Client.close_session(client, "sess_mock_001")

      refute_receive :close_session_request, 100
    end
  end

  describe "delete_session/3" do
    test "sends delete request when capability is advertised" do
      {client, _agent} = start_client()

      assert {:ok, %{}} = Client.delete_session(client, "sess_mock_001")
      assert_receive :delete_session_request, 5_000
    end

    test "returns unsupported when capability is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert {:error, {:unsupported_capability, :session_delete}} =
               Client.delete_session(client, "sess_mock_001")

      refute_receive :delete_session_request, 100
    end
  end

  describe "end_session/2" do
    test "uses close when capability is advertised" do
      {client, _agent} = start_client()

      assert {:ok, %{}} = Client.end_session(client, "sess_mock_001")
      assert_receive :close_session_request, 5_000
    end

    test "falls back to local telemetry behavior when close is not advertised" do
      {client, _agent} = start_client(capabilities: %{"streaming" => true})

      assert :ok = Client.end_session(client, "sess_mock_001")
      refute_receive :close_session_request, 100
    end
  end

  describe "permission request handling" do
    test "routes to handler and sends response back" do
      tool_call = %{
        "toolCallId" => "tc_write",
        "toolName" => "file_write",
        "arguments" => %{"path" => "/etc/hosts"}
      }

      options = [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]

      {client, _agent} = start_client(permission_request: {tool_call, options})

      {:ok, _} = Client.new_session(client, "/tmp")
      {:ok, _} = Client.prompt(client, "sess_mock_001", "Write a file")

      assert_receive {:permission_response, resp}, 5_000
      assert resp["result"]["outcome"]["outcome"] == "selected"
      assert resp["result"]["outcome"]["optionId"] == "deny"
    end

    test "cancel replies cancelled to pending permission requests without waiting for handler" do
      tool_call = %{
        "toolCallId" => "tc_write",
        "toolName" => "file_write",
        "arguments" => %{"path" => "/etc/hosts"}
      }

      options = [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]

      {client, _agent} =
        start_client(
          [permission_request: {tool_call, options}],
          handler: BlockingPermissionHandler,
          handler_opts: [parent: self()]
        )

      {:ok, _} = Client.new_session(client, "/tmp")

      task =
        Task.async(fn ->
          Client.prompt(client, "sess_mock_001", "Write a file", timeout: 2_000)
        end)

      assert_receive {:blocking_permission_handler_started, handler_pid}, 500

      assert :ok = Client.cancel(client, "sess_mock_001")
      assert_receive {:permission_response, resp}, 1_000
      assert resp["result"]["outcome"]["outcome"] == "cancelled"

      assert {:ok, _} = Task.await(task, 2_000)
      send(handler_pid, :release_permission_handler)
      refute_receive {:permission_response, _late_response}, 200
    end

    test "$/cancel_request replies request-cancelled to pending agent requests" do
      tool_call = %{
        "toolCallId" => "tc_write",
        "toolName" => "file_write",
        "arguments" => %{"path" => "/etc/hosts"}
      }

      options = [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]

      {client, _agent} =
        start_client(
          [permission_request: {tool_call, options}],
          handler: BlockingPermissionHandler,
          handler_opts: [parent: self()]
        )

      {:ok, _} = Client.new_session(client, "/tmp")

      task =
        Task.async(fn ->
          Client.prompt(client, "sess_mock_001", "Write a file", timeout: 2_000)
        end)

      assert_receive {:blocking_permission_handler_started, handler_pid}, 500
      [{_ref, pending}] = Map.to_list(:sys.get_state(client).pending_agent_requests)
      send(client, {:transport_message, Protocol.encode_cancel_request(pending.id)})
      assert_receive {:permission_response, resp}, 1_000
      assert resp["error"]["code"] == -32_800
      assert resp["error"]["message"] == "Request cancelled"

      assert {:ok, _} = Task.await(task, 2_000)
      send(handler_pid, :release_permission_handler)
      refute_receive {:permission_response, _late_response}, 200
    end

    test "expires a client handler request and ignores its late result" do
      tool_call = %{"toolCallId" => "tc_wait", "toolName" => "file_write"}
      options = [%{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}]

      {client, _agent} =
        start_client(
          [permission_request: {tool_call, options}],
          handler: BlockingPermissionHandler,
          handler_opts: [parent: self()],
          handler_request_timeout: 20
        )

      {:ok, _} = Client.new_session(client, "/tmp")
      task = Task.async(fn -> Client.prompt(client, "sess_mock_001", "wait", timeout: 1_000) end)

      assert_receive {:blocking_permission_handler_started, handler_pid}
      assert_receive {:permission_response, response}, 500
      assert response["error"]["code"] == -32_603
      assert response["error"]["message"] == "Client handler timed out"
      assert {:ok, _} = Task.await(task, 1_000)
      assert :sys.get_state(client).pending_agent_requests == %{}

      send(handler_pid, :release_permission_handler)
      refute_receive {:permission_response, _late_response}, 100
    end
  end

  describe "pending request limits" do
    test "expires an unanswered request even while its caller remains alive" do
      {client, _agent} =
        start_client(
          [ignore_method: "session/new"],
          pending_request_timeout: 20
        )

      assert {:error, :request_timeout} = Client.new_session(client, "/tmp", timeout: 500)
      assert_receive {:ignored_request, "session/new"}

      state = :sys.get_state(client)
      assert state.pending_requests == %{}
      assert state.pending_caller_monitors == %{}
    end
  end

  describe "stream pressure limits" do
    test "receiver permits at most one unacknowledged transport frame" do
      {:ok, to_client_relay} = MessageRelay.start_link()
      {:ok, to_agent_relay} = MessageRelay.start_link()
      agent_pid = MockACPAgent.start(to_client_relay, to_agent_relay)

      {:ok, client} =
        Client.start_link(
          transport_mod: MockACPTransport,
          command: ["mock"],
          agent_pid: agent_pid,
          to_client_relay: to_client_relay,
          to_agent_relay: to_agent_relay
        )

      :ok = :sys.suspend(client)

      frame =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "test/pressure",
          "params" => %{}
        })

      for _index <- 1..50, do: MessageRelay.push(to_client_relay, frame)
      Process.sleep(20)

      assert {:message_queue_len, queued} = Process.info(client, :message_queue_len)
      assert queued <= 1
      :ok = :sys.resume(client)
    end

    test "bounds queued updates for a blocked handler" do
      {client, _agent} =
        start_client([],
          handler: BlockingUpdateHandler,
          handler_opts: [parent: self()],
          max_update_queue: 2
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      raw = session_update_frame(session_id, "queued")

      send(client, {:transport_message, raw})
      assert_receive {:blocking_update_handler_started, handler_pid, _update}

      for _index <- 1..20, do: send(client, {:transport_message, raw})
      _state = :sys.get_state(client)

      assert {:message_queue_len, queued} = Process.info(handler_pid, :message_queue_len)
      assert queued <= 2
      send(handler_pid, :release_update_handler)
    end

    test "bounds queued updates for a slow event listener" do
      listener = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(listener, :kill) end)

      {client, _agent} = start_client([], event_listener: listener, max_update_queue: 2)
      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      raw = session_update_frame(session_id, "queued")

      for _index <- 1..20, do: send(client, {:transport_message, raw})
      _state = :sys.get_state(client)

      assert {:message_queue_len, queued} = Process.info(listener, :message_queue_len)
      assert queued <= 2
    end

    test "rejects malformed and unknown session updates before dispatch" do
      {client, _agent} = start_client([], event_listener: self())
      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")

      invalid =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "session/update",
          "params" => %{
            "sessionId" => session_id,
            "update" => %{"sessionUpdate" => "unknown", "secret" => "do-not-dispatch"}
          }
        })

      send(client, {:transport_message, invalid})
      _state = :sys.get_state(client)

      refute_receive {:acp_session_update, ^session_id, _update}
    end

    test "bounds queued update bytes for a blocked handler" do
      update = %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => String.duplicate("h", 256)}
      }

      update_bytes = :erlang.external_size(update)

      {client, _agent} =
        start_client([],
          handler: BlockingUpdateHandler,
          handler_opts: [parent: self()],
          max_update_queue: 100,
          max_update_queue_bytes: update_bytes * 2
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      raw = session_update_frame(session_id, get_in(update, ["content", "text"]))

      send(client, {:transport_message, raw})
      assert_receive {:blocking_update_handler_started, handler_pid, _update}

      for _index <- 1..20, do: send(client, {:transport_message, raw})
      _state = :sys.get_state(client)

      assert {:message_queue_len, queued} = Process.info(handler_pid, :message_queue_len)
      assert queued <= 2
      send(handler_pid, :release_update_handler)
    end

    test "bounds queued update bytes for a slow event listener" do
      listener = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(listener, :kill) end)

      update = %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => String.duplicate("l", 256)}
      }

      update_bytes = :erlang.external_size(update)

      {client, _agent} =
        start_client([],
          event_listener: listener,
          max_update_queue: 100,
          max_update_queue_bytes: update_bytes * 2
        )

      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      raw = session_update_frame(session_id, get_in(update, ["content", "text"]))

      for _index <- 1..20, do: send(client, {:transport_message, raw})
      _state = :sys.get_state(client)

      assert {:message_queue_len, queued} = Process.info(listener, :message_queue_len)
      assert queued <= 2
    end
  end

  describe "DefaultHandler permission policy" do
    test "bounds retained event history" do
      {:ok, state} = DefaultHandler.init(max_events: 2)
      {:ok, state} = DefaultHandler.handle_session_update("sess", %{"n" => 1}, state)
      {:ok, state} = DefaultHandler.handle_session_update("sess", %{"n" => 2}, state)
      {:ok, state} = DefaultHandler.handle_session_update("sess", %{"n" => 3}, state)

      assert state.events == [%{"n" => 3}, %{"n" => 2}]
    end

    test "bounds retained event history by encoded bytes" do
      {:ok, state} = DefaultHandler.init(max_events: 100, max_event_bytes: 80)

      {:ok, state} =
        DefaultHandler.handle_session_update(
          "sess",
          %{"text" => String.duplicate("a", 40)},
          state
        )

      {:ok, state} =
        DefaultHandler.handle_session_update(
          "sess",
          %{"text" => String.duplicate("b", 40)},
          state
        )

      assert state.event_bytes <= 80
      assert state.events == [%{"text" => String.duplicate("b", 40)}]
    end

    test "denies by default using a reject option when available" do
      {:ok, state} = DefaultHandler.init([])

      options = [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]

      assert {:ok, outcome, _state} =
               DefaultHandler.handle_permission_request(
                 "sess",
                 %{"toolCallId" => "tool"},
                 options,
                 state
               )

      assert outcome == %{"outcome" => "selected", "optionId" => "deny"}
    end

    test "can explicitly auto-approve for trusted tests" do
      {:ok, state} = DefaultHandler.init(auto_approve_permissions: true)

      options = [
        %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]

      assert {:ok, outcome, _state} =
               DefaultHandler.handle_permission_request(
                 "sess",
                 %{"toolCallId" => "tool"},
                 options,
                 state
               )

      assert outcome == %{"outcome" => "selected", "optionId" => "allow"}
    end
  end

  describe "event listener" do
    test "receives session update messages" do
      updates = [
        %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Hello from agent"}
        }
      ]

      {:ok, to_client_relay} = MessageRelay.start_link()
      {:ok, to_agent_relay} = MessageRelay.start_link()

      agent_pid = MockACPAgent.start(to_client_relay, to_agent_relay, updates: updates)

      {:ok, client} =
        Client.start_link(
          transport_mod: MockACPTransport,
          command: ["mock"],
          agent_pid: agent_pid,
          to_client_relay: to_client_relay,
          to_agent_relay: to_agent_relay,
          event_listener: self()
        )

      {:ok, _} = Client.new_session(client, "/tmp")
      {:ok, _} = Client.prompt(client, "sess_mock_001", "Say hello")

      assert_receive {:acp_session_update, "sess_mock_001", update}, 5_000
      assert update["sessionUpdate"] == "agent_message_chunk"
      assert update["content"] == %{"type" => "text", "text" => "Hello from agent"}
    end
  end

  describe "telemetry privacy" do
    test "emits a fingerprint instead of a raw ACP session id" do
      handler_id = "acp-session-privacy-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:ex_mcp, :acp, :session, :started],
            [:ex_mcp, :acp, :prompt, :sent],
            [:ex_mcp, :acp, :prompt, :completed]
          ],
          fn event, _measurements, metadata, _config ->
            send(parent, {:acp_telemetry, event, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {client, _agent} = start_client()
      {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp")
      {:ok, _result} = Client.prompt(client, session_id, "private")

      for event <- [
            [:ex_mcp, :acp, :session, :started],
            [:ex_mcp, :acp, :prompt, :sent],
            [:ex_mcp, :acp, :prompt, :completed]
          ] do
        assert_receive {:acp_telemetry, ^event, metadata}
        refute Map.has_key?(metadata, :session_id)
        assert is_binary(metadata.session_id_hash)
        refute metadata.session_id_hash == session_id
      end
    end
  end

  describe "transport error" do
    test "transitions to disconnected after disconnect" do
      {client, _agent} = start_client()

      # Verify we start ready
      assert Client.status(client) == :ready

      # Disconnect and verify
      :ok = Client.disconnect(client)
      assert Client.status(client) == :disconnected
    end
  end

  describe "disconnect/1" do
    test "cleanly disconnects" do
      {client, _agent} = start_client()

      assert :ok = Client.disconnect(client)
      assert Client.status(client) == :disconnected
    end
  end
end
