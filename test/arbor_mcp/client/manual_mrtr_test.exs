defmodule Arbor.MCP.Client.ManualMRTRTest do
  # A client that forwards requests for another client, such as a gateway,
  # leaves each MRTR round to that client: `mrtr: :manual` returns the round
  # as `{:input_required, ...}`, `input_responses:` and `request_state:`
  # continue the call, and `client_capabilities:` declares that client's
  # capabilities for one request.
  #
  # The first part runs against arbor_mcp servers, over modern Streamable
  # HTTP (a Runtime-mounted HttpPlug on Bandit) and over the in-process test
  # transport. The second part scripts the server's replies to check exactly
  # what the client sends and how it validates what it gets.
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.Internal.InputResultSchema
  alias Arbor.MCP.Error.{ProtocolError, ValidationError}
  alias Arbor.MCP.Server.{Context, HandlerServer, Runtime}

  @key :binary.copy(<<7>>, 32)
  @caps_key "io.modelcontextprotocol/clientCapabilities"
  @form %{"elicitation" => %{"form" => %{}}}
  @name_schema %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
  @elicitation %{
    "name" => %{
      "method" => "elicitation/create",
      "params" => %{"message" => "What should we call you?", "requestedSchema" => @name_schema}
    }
  }

  defmodule AppHandler do
    use Arbor.MCP.Server.Handler

    @name_schema %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def handle_list_tools(_cursor, state) do
      send(state.test_pid, {:app_list, Context.current().client_capabilities})

      tools =
        for name <- ~w(ask choose context),
            do: %{name: name, description: name, inputSchema: %{"type" => "object"}}

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("ask", _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          {:ok, %{content: [%{type: "text", text: "Welcome, #{name(responses)}"}]}, state}
      end
    end

    # A server picks its input from the capabilities of the request it is
    # answering: a summary when the client can sample, else a question.
    def handle_call_tool("choose", _arguments, state) do
      if Map.has_key?(Context.current().client_capabilities || %{}, "sampling") do
        sample = %{
          "method" => "sampling/createMessage",
          "params" => %{
            "messages" => [
              %{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize"}}
            ],
            "maxTokens" => 10
          }
        }

        {:input_required, %{"summary" => sample}, state}
      else
        {:input_required, name_request(), state}
      end
    end

    def handle_call_tool("context", _arguments, state) do
      context = Context.current()

      send(
        state.test_pid,
        {:app_context, context.era, context.client_capabilities, Context.input_responses(),
         Context.request_state()}
      )

      {:ok, %{content: [%{type: "text", text: "seen"}]}, state}
    end

    @impl true
    def handle_list_prompts(_cursor, state),
      do: {:ok, [%{name: "greeting", description: "Greets a named person"}], nil, state}

    @impl true
    def handle_get_prompt("greeting", _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          message = %{role: "user", content: %{type: "text", text: "Greet #{name(responses)}"}}
          {:ok, %{messages: [message]}, state}
      end
    end

    @impl true
    def handle_list_resources(_cursor, state),
      do: {:ok, [%{uri: "memo://note", name: "note"}], nil, state}

    @impl true
    def handle_read_resource("memo://note", state) do
      case Context.input_responses() do
        nil ->
          {:input_required, name_request(), %{"step" => 1}, state}

        responses ->
          send(state.test_pid, {:app_retry, responses, Context.request_state()})
          text = "A note for #{name(responses)}"
          {:ok, %{contents: [%{uri: "memo://note", mimeType: "text/plain", text: text}]}, state}
      end
    end

    defp name_request do
      %{
        "name" => %{
          "method" => "elicitation/create",
          "params" => %{
            "message" => "What should we call you?",
            "requestedSchema" => @name_schema
          }
        }
      }
    end

    defp name(responses), do: get_in(responses, ["name", "content", "name"])
  end

  # The gateway from "Forwarding clients" in docs/CONFIGURATION.md, without
  # its progress relay (progress_to_test.exs runs the whole example): an
  # arbor_mcp server whose tools forward to an upstream server and whose
  # downstream client answers the upstream rounds.
  defmodule GatewayHandler do
    use Arbor.MCP.Server.Handler

    alias Arbor.MCP.Server.Context

    @impl true
    def init(opts), do: {:ok, %{upstream: Keyword.fetch!(opts, :upstream)}}

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "ask", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool(name, arguments, state) do
      sealed = Context.request_state() || %{}

      opts = [
        mrtr: :manual,
        client_capabilities: Context.current().client_capabilities,
        input_responses: Context.input_responses(),
        request_state: sealed["upstream"],
        format: :map
      ]

      case Arbor.MCP.Client.call_tool(state.upstream, name, arguments, opts) do
        {:input_required, %{input_requests: requests, request_state: upstream}} ->
          {:input_required, requests, %{"upstream" => upstream}, state}

        {:ok, result} ->
          {:ok, result, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts),
      do: {:ok, %{owner: Keyword.fetch!(opts, :owner), name: Keyword.get(opts, :name, "Lin")}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not used", state}

    @impl true
    def handle_elicitation_create(message, _schema, state) do
      send(state.owner, {:elicited, message})
      {:ok, %{"action" => "accept", "content" => %{"name" => state.name}}, state}
    end
  end

  # Answers each request with the next scripted result and reports what it
  # was sent.
  defmodule ScriptedTransport do
    def send_message(encoded, state) do
      request = Jason.decode!(encoded)
      send(state.owner, {:wire, request})

      {result, results} =
        case state.results do
          [result | rest] -> {result, rest}
          [] -> {%{"resultType" => "complete", "content" => []}, []}
        end

      response = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
      {:ok, %{state | results: results}, Jason.encode!(response)}
    end
  end

  @tom %{"name" => %{"action" => "accept", "content" => %{"name" => "Tom"}}}
  @responses_shape "must map input request ids to elicitation, sampling or roots results"
  @cached_tools %{
    "resultType" => "complete",
    "tools" => [],
    "ttlMs" => 60_000,
    "cacheScope" => "private"
  }

  for transport <- [:http, :test] do
    describe "mrtr: :manual against an arbor_mcp server (#{transport})" do
      @describetag transport: transport

      test "returns the round as {:input_required, ...} without calling the client handler",
           %{transport: transport} do
        client = connect(transport)

        for format <- [:map, :struct] do
          assert {:input_required,
                  %{
                    input_requests: %{
                      "name" => %{
                        "method" => "elicitation/create",
                        "params" => %{"message" => "What should we call you?"}
                      }
                    },
                    request_state: request_state
                  } = round} = Client.call_tool(client, "ask", %{}, mrtr: :manual, format: format)

          assert is_binary(request_state)
          assert Map.has_key?(round, :meta)
        end

        refute_received {:elicited, _message}
        refute_received {:app_retry, _responses, _state}
      end

      test "input_responses and request_state continue the call to its result",
           %{transport: transport} do
        client = connect(transport)

        assert {:input_required, %{request_state: request_state}} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"}, mrtr: :manual)

        assert {:ok, result} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"},
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: request_state,
                   format: :map
                 )

        assert result["resultType"] == "complete"
        assert result["content"] == [%{"type" => "text", "text" => "Welcome, Tom"}]
        assert_received {:app_retry, @tom, %{"step" => 1}}
        refute_received {:elicited, _message}
      end

      test "prompts/get and resources/read run manual rounds the same way",
           %{transport: transport} do
        client = connect(transport)

        assert {:input_required, %{input_requests: %{"name" => _}, request_state: state}} =
                 Client.get_prompt(client, "greeting", %{}, mrtr: :manual)

        assert {:ok, %{"messages" => [message]}} =
                 Client.get_prompt(client, "greeting", %{},
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: state,
                   format: :map
                 )

        assert message["content"]["text"] == "Greet Tom"
        assert_received {:app_retry, @tom, %{"step" => 1}}

        assert {:input_required, %{input_requests: %{"name" => _}, request_state: state}} =
                 Client.read_resource(client, "memo://note", mrtr: :manual)

        assert {:ok, %{"contents" => [%{"text" => "A note for Tom"}]}} =
                 Client.read_resource(client, "memo://note",
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: state,
                   format: :map
                 )

        assert_received {:app_retry, @tom, %{"step" => 1}}
        refute_received {:elicited, _message}
      end

      test "an explicit timeout covers each round on its own", %{transport: transport} do
        client = connect(transport)

        assert {:input_required, %{request_state: state}} =
                 Client.call_tool(client, "ask", %{}, mrtr: :manual, timeout: 5_000)

        assert {:ok, %{"content" => [%{"text" => "Welcome, Tom"}]}} =
                 Client.call_tool(client, "ask", %{},
                   mrtr: :manual,
                   input_responses: @tom,
                   request_state: state,
                   timeout: 5_000,
                   format: :map
                 )
      end

      test "client_capabilities replace the start capabilities in that request only",
           %{transport: transport} do
        started = %{"elicitation" => %{"form" => %{}, "url" => %{}}, "sampling" => %{}}
        client = connect(transport, capabilities: started)

        assert {:ok, _result} =
                 Client.call_tool(client, "context", %{},
                   mrtr: :manual,
                   client_capabilities: @form,
                   format: :map
                 )

        assert_received {:app_context, :modern, @form, nil, nil}

        assert {:ok, _result} = Client.call_tool(client, "context", %{}, format: :map)
        assert_received {:app_context, :modern, ^started, nil, nil}
      end

      test "a request that can't pause declares capabilities without mrtr: :manual",
           %{transport: transport} do
        client = connect(transport, capabilities: Map.put(@form, "sampling", %{}))

        assert {:ok, _tools} = Client.list_tools(client, client_capabilities: @form)
        assert_received {:app_list, @form}

        assert {:error, %ValidationError{reason: "requires mrtr: :manual"}} =
                 Client.call_tool(client, "context", %{}, client_capabilities: @form)

        refute_received {:app_context, _era, _capabilities, _responses, _state}
      end

      test "the server chooses its input from the request's capabilities",
           %{transport: transport} do
        client = connect(transport, capabilities: Map.put(@form, "sampling", %{}))

        assert {:input_required, %{input_requests: %{"summary" => %{"method" => method}}}} =
                 Client.call_tool(client, "choose", %{}, mrtr: :manual)

        assert method == "sampling/createMessage"

        assert {:input_required, %{input_requests: %{"name" => %{"method" => method}}}} =
                 Client.call_tool(client, "choose", %{},
                   mrtr: :manual,
                   client_capabilities: @form
                 )

        assert method == "elicitation/create"
      end

      # An arbor_mcp server binds requestState to the request's params, _meta
      # included, and to the capabilities it declared.
      test "every round repeats the arguments, capabilities and progress token",
           %{transport: transport} do
        client = connect(transport)

        round = [
          mrtr: :manual,
          client_capabilities: @form,
          progress_token: "upstream-1",
          format: :map
        ]

        assert {:input_required, %{request_state: state}} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"}, round)

        retry = round ++ [input_responses: @tom, request_state: state]

        for {arguments, changed} <- [
              {%{"topic" => "other"}, retry},
              {%{"topic" => "intro"}, Keyword.put(retry, :progress_token, "upstream-2")},
              {%{"topic" => "intro"},
               Keyword.put(retry, :client_capabilities, Map.put(@form, "roots", %{}))}
            ] do
          assert {:error,
                  %{"code" => -32_602, "data" => %{"reason" => "request_state_binding_mismatch"}}} =
                   Client.call_tool(client, "ask", arguments, changed)
        end

        refute_received {:app_retry, _responses, _state}

        assert {:ok, %{"content" => [%{"text" => "Welcome, Tom"}]}} =
                 Client.call_tool(client, "ask", %{"topic" => "intro"}, retry)
      end

      test "automatic MRTR is unchanged", %{transport: transport} do
        client = connect(transport)

        for opts <- [[], [mrtr: :auto], [mrtr: nil]] do
          assert {:ok, %{"resultType" => "complete", "content" => [%{"text" => "Welcome, Lin"}]}} =
                   Client.call_tool(client, "ask", %{}, [format: :map] ++ opts)

          assert_received {:elicited, "What should we call you?"}
          assert_received {:app_retry, %{"name" => _}, %{"step" => 1}}
        end
      end

      test "nil leaves every option unset", %{transport: transport} do
        client = connect(transport)

        for mrtr <- [nil, :auto, :manual] do
          assert {:ok, %{"content" => [%{"text" => "seen"}]}} =
                   Client.call_tool(client, "context", %{},
                     format: :map,
                     mrtr: mrtr,
                     input_responses: nil,
                     request_state: nil,
                     client_capabilities: nil
                   )

          assert_received {:app_context, :modern, @form, nil, nil}
        end
      end
    end
  end

  describe "a gateway" do
    for mode <- [:modern_only, :legacy_only] do
      test "hands the upstream rounds to its downstream client (#{mode} downstream)" do
        # Were the gateway's own client to answer, the call would greet Gate.
        upstream = connect(:http, handler: {ClientHandler, [owner: self(), name: "Gate"]})

        gateway =
          start_supervised!(
            {HandlerServer,
             handler: GatewayHandler,
             handler_args: [upstream: upstream],
             transport: :test,
             protocol_mode: unquote(mode),
             mrtr: true,
             request_state: [active_key_id: "gateway", keys: %{"gateway" => @key}]},
            id: make_ref()
          )

        downstream =
          start_client(transport: :test, server: gateway, protocol_mode: unquote(mode))

        assert {:ok, %{"content" => [%{"text" => "Welcome, Lin"}]}} =
                 Client.call_tool(downstream, "ask", %{"topic" => "intro"}, format: :map)

        # The downstream client answered, and only it.
        assert_received {:elicited, "What should we call you?"}
        refute_received {:elicited, _message}
        assert_received {:app_retry, %{"name" => %{"content" => %{"name" => "Lin"}}}, _state}
      end
    end
  end

  describe "on a legacy connection" do
    for transport <- [:http, :test] do
      test "client_capabilities and the continuation are refused before anything is sent (#{transport})" do
        client = connect(unquote(transport), protocol_mode: :legacy_only)

        for {key, value} <- [
              client_capabilities: @form,
              input_responses: @tom,
              request_state: "state"
            ] do
          assert {:error, %ValidationError{field: ^key, reason: reason}} =
                   Client.call_tool(client, "context", %{}, [mrtr: :manual] ++ [{key, value}])

          assert reason =~ "requires MCP 2026-07-28, but the connection settled on 2025-"
        end

        refute_received {:app_context, _era, _capabilities, _responses, _state}
      end
    end

    # A legacy server asks with server-to-client requests, which the client
    # handler answers: there is no round to hand back.
    test "mrtr: :manual leaves the server's input requests to the client handler" do
      client = connect(:test, protocol_mode: :legacy_only)

      assert {:ok, %{"content" => [%{"text" => "Welcome, Lin"}]}} =
               Client.call_tool(client, "ask", %{}, mrtr: :manual, format: :map)

      assert_received {:elicited, "What should we call you?"}
    end
  end

  describe "the returned round is validated as automatic MRTR validates it" do
    for {name, result, message} <- [
          {"inputRequests that is not an object", %{"inputRequests" => [], "requestState" => "s"},
           "inputRequests must be an object"},
          {"a requestState that is not a string",
           %{"inputRequests" => @elicitation, "requestState" => 1},
           "requestState must be a string"},
          {"neither inputRequests nor requestState", %{},
           "input_required must contain inputRequests or requestState"},
          {"an input method MRTR doesn't define",
           %{"inputRequests" => %{"x" => %{"method" => "tools/call", "params" => %{}}}},
           "Invalid MRTR input request"}
        ] do
      test "#{name} is an error in both modes" do
        result = Map.put(unquote(Macro.escape(result)), "resultType", "input_required")

        for mrtr <- [:auto, :manual] do
          client = scripted([result])

          assert {:error, %ProtocolError{code: -32_602, message: unquote(message)}} =
                   Client.call_tool(client, "ask", %{}, mrtr: mrtr, format: :map)
        end
      end
    end

    test "the input request and byte limits apply in both modes" do
      round = input_required(@elicitation)

      for mrtr <- [:auto, :manual] do
        assert {:error, %ProtocolError{message: "MRTR input request limit exceeded"}} =
                 Client.call_tool(scripted([round]), "ask", %{},
                   mrtr: mrtr,
                   max_input_requests: 0
                 )

        assert {:error, %ProtocolError{message: "MRTR byte limit exceeded"}} =
                 Client.call_tool(scripted([round]), "ask", %{}, mrtr: mrtr, max_mrtr_bytes: 16)
      end
    end

    test "an input request the request declared no capability for is an error in both modes" do
      round =
        input_required(%{"summary" => %{"method" => "sampling/createMessage", "params" => %{}}})

      errors =
        for mrtr <- [:auto, :manual] do
          assert {:error, %ProtocolError{code: -32_021} = error} =
                   Client.call_tool(scripted([round]), "ask", %{}, mrtr: mrtr)

          error
        end

      assert [same, same] = errors
      assert same.data == %{"requiredCapabilities" => %{"sampling" => %{}}}

      # Declared for this request, the same round is the caller's to answer.
      assert {:input_required, %{input_requests: %{"summary" => _}}} =
               Client.call_tool(scripted([round]), "ask", %{},
                 mrtr: :manual,
                 client_capabilities: %{"sampling" => %{}}
               )

      # A URL elicitation needs `elicitation.url`, which @form doesn't declare.
      url = %{
        "method" => "elicitation/create",
        "params" => %{"mode" => "url", "message" => "Sign in", "url" => "https://example.test"}
      }

      assert {:error, %ProtocolError{code: -32_021}} =
               Client.call_tool(scripted([input_required(%{"login" => url})]), "ask", %{},
                 mrtr: :manual
               )
    end

    test "an input_required result on a legacy connection is an error in both modes" do
      for mrtr <- [:auto, :manual] do
        client = scripted([input_required(@elicitation)], protocol_version: "2025-06-18")

        assert {:error, %ProtocolError{message: "MRTR requires MCP 2026-07-28"}} =
                 Client.call_tool(client, "ask", %{}, mrtr: mrtr)
      end

      refute_received {:elicited, _message}
    end

    test "a valid round comes back the same in both formats" do
      for format <- [:map, :struct] do
        assert {:input_required,
                %{input_requests: @elicitation, request_state: "sealed", meta: nil}} =
                 Client.call_tool(scripted([input_required(@elicitation)]), "ask", %{},
                   mrtr: :manual,
                   format: format
                 )
      end

      # requestState is optional when there are input requests.
      round = Map.delete(input_required(@elicitation), "requestState")

      assert {:input_required, %{input_requests: @elicitation, request_state: nil}} =
               Client.call_tool(scripted([round]), "ask", %{}, mrtr: :manual)
    end

    test "the round's _meta comes back as meta, within the byte limit" do
      meta = %{"io.example/trace" => "abc", "note" => %{"step" => 1}}
      round = Map.put(input_required(@elicitation), "_meta", meta)

      for format <- [:map, :struct] do
        assert {:input_required, %{meta: ^meta, input_requests: @elicitation}} =
                 Client.call_tool(scripted([round]), "ask", %{}, mrtr: :manual, format: format)
      end

      # The byte limit counts the _meta: this round fits only without it.
      limit = byte_size(Jason.encode!(input_required(@elicitation))) + 1
      big = Map.put(input_required(@elicitation), "_meta", %{"pad" => String.duplicate("x", 64)})

      assert {:input_required, _round} =
               Client.call_tool(scripted([input_required(@elicitation)]), "ask", %{},
                 mrtr: :manual,
                 max_mrtr_bytes: limit
               )

      assert {:error, %ProtocolError{message: "MRTR byte limit exceeded"}} =
               Client.call_tool(scripted([big]), "ask", %{}, mrtr: :manual, max_mrtr_bytes: limit)
    end

    test "a _meta that is not an object is an error" do
      round = Map.put(input_required(@elicitation), "_meta", "trace")

      assert {:error,
              %ProtocolError{code: -32_602, message: "input_required _meta must be an object"}} =
               Client.call_tool(scripted([round]), "ask", %{}, mrtr: :manual)
    end
  end

  # A forwarding request answers for one downstream client; the cache is the
  # client's own callers'.
  describe "the response cache" do
    test "a result fetched with client_capabilities never answers a default caller" do
      client = scripted([@cached_tools, @cached_tools])

      assert {:ok, _tools} = Client.list_tools(client, client_capabilities: %{"sampling" => %{}})
      assert_received {:wire, %{"method" => "tools/list"}}

      assert {:ok, _tools} = Client.list_tools(client)
      assert_received {:wire, %{"method" => "tools/list", "params" => %{"_meta" => meta}}}
      assert meta[@caps_key] == @form
    end

    test "a cached default result never answers a request with client_capabilities" do
      client = scripted([@cached_tools, @cached_tools])

      assert {:ok, _tools} = Client.list_tools(client)
      assert_received {:wire, %{"method" => "tools/list"}}

      # The default caller is answered from the cache.
      assert {:ok, _tools} = Client.list_tools(client)
      refute_received {:wire, _request}

      assert {:ok, _tools} = Client.list_tools(client, client_capabilities: %{"sampling" => %{}})
      assert_received {:wire, %{"method" => "tools/list", "params" => %{"_meta" => meta}}}
      assert meta[@caps_key] == %{"sampling" => %{}}
    end

    test "mrtr: :manual bypasses it as well, whatever :cache_mode says" do
      note = %{
        "resultType" => "complete",
        "contents" => [%{"uri" => "memo://note", "text" => "note"}],
        "ttlMs" => 60_000,
        "cacheScope" => "private"
      }

      client = scripted([note, note, note])

      assert {:ok, _note} =
               Client.read_resource(client, "memo://note", mrtr: :manual, cache_mode: :use)

      assert_received {:wire, %{"method" => "resources/read"}}

      # The manual read didn't fill the cache...
      assert {:ok, _note} = Client.read_resource(client, "memo://note")
      assert_received {:wire, %{"method" => "resources/read"}}

      # ...and the default read's cached result doesn't answer a manual one.
      assert {:ok, _note} = Client.read_resource(client, "memo://note", mrtr: :manual)
      assert_received {:wire, %{"method" => "resources/read"}}
    end
  end

  describe "telemetry" do
    setup do
      id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        id,
        [[:arbor_mcp, :client, :mrtr, :round], [:arbor_mcp, :client, :mrtr, :failure]],
        &__MODULE__.forward_mrtr_telemetry/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "a manual round reports the automatic events with mode: :manual" do
      assert {:input_required, _round} =
               Client.call_tool(scripted([input_required(@elicitation)]), "ask", %{},
                 mrtr: :manual
               )

      assert_received {:mrtr_telemetry, [:arbor_mcp, :client, :mrtr, :round],
                       %{round: 1, input_requests: 1}, metadata}

      assert metadata == %{method: "tools/call", mode: :manual}

      # The automatic path reports the same event, with mode: :auto.
      assert {:ok, _result} =
               Client.call_tool(scripted([input_required(@elicitation)]), "ask", %{},
                 format: :map
               )

      assert_received {:mrtr_telemetry, [:arbor_mcp, :client, :mrtr, :round],
                       %{round: 1, input_requests: 1}, %{method: "tools/call", mode: :auto}}

      refute_received {:mrtr_telemetry, _event, _measurements, _metadata}
    end

    test "a manual round that fails its checks reports a failure class" do
      sample = %{"summary" => %{"method" => "sampling/createMessage", "params" => %{}}}

      for {client, reason} <- [
            {scripted([input_required(sample)]), :missing_capability},
            {scripted([%{"resultType" => "input_required"}]), :protocol_error},
            {scripted([input_required(@elicitation)], protocol_version: "2025-06-18"),
             :protocol_error}
          ] do
        assert {:error, %ProtocolError{}} = Client.call_tool(client, "ask", %{}, mrtr: :manual)

        assert_received {:mrtr_telemetry, [:arbor_mcp, :client, :mrtr, :failure], %{round: 0},
                         metadata}

        assert metadata == %{method: "tools/call", reason: reason, mode: :manual}
      end

      assert {:error, _reason} =
               Client.call_tool(scripted([input_required(sample)]), "ask", %{}, mrtr: :auto)

      assert_received {:mrtr_telemetry, [:arbor_mcp, :client, :mrtr, :failure], %{round: 0},
                       %{method: "tools/call", reason: :missing_capability, mode: :auto}}
    end
  end

  describe "request options" do
    test "the continuation and the capabilities reach the wire as given" do
      client = scripted([])
      capabilities = %{"elicitation" => %{"form" => %{}}, "extensions" => %{"x/y" => %{}}}

      assert {:ok, _result} =
               Client.call_tool(client, "ask", %{"topic" => "intro"},
                 mrtr: :manual,
                 input_responses: @tom,
                 request_state: "sealed",
                 client_capabilities: capabilities,
                 format: :map
               )

      assert_received {:wire, %{"method" => "tools/call", "params" => params}}
      assert params["arguments"] == %{"topic" => "intro"}
      assert params["inputResponses"] == @tom
      assert params["requestState"] == "sealed"
      assert params["_meta"][@caps_key] == capabilities
    end

    test "nil options are unset" do
      client = scripted([])

      assert {:ok, _result} =
               Client.call_tool(client, "ask", %{},
                 mrtr: nil,
                 input_responses: nil,
                 request_state: nil,
                 client_capabilities: nil,
                 format: :map
               )

      assert_received {:wire, %{"params" => params}}
      refute Map.has_key?(params, "inputResponses")
      refute Map.has_key?(params, "requestState")
      assert params["_meta"][@caps_key] == @form
    end

    test "client_capabilities and the continuation need mrtr: :manual" do
      client = scripted([])

      operations = [
        &Client.call_tool(client, "ask", %{}, &1),
        &Client.get_prompt(client, "greeting", %{}, &1),
        &Client.read_resource(client, "memo://note", &1)
      ]

      for operation <- operations,
          mrtr <- [[], [mrtr: nil], [mrtr: :auto]],
          {key, value} <- [
            client_capabilities: @form,
            input_responses: @tom,
            request_state: "sealed"
          ] do
        assert {:error, %ValidationError{field: ^key, reason: "requires mrtr: :manual"}} =
                 operation.([{key, value} | mrtr])
      end

      refute_received {:wire, _request}
    end

    test "a request that can't return input_required takes client_capabilities without it" do
      tools = %{
        "resultType" => "complete",
        "tools" => [],
        "ttlMs" => 0,
        "cacheScope" => "private"
      }

      completion = %{"resultType" => "complete", "completion" => %{"values" => []}}
      client = scripted([tools, completion])
      capabilities = %{"sampling" => %{}}

      assert {:ok, _tools} = Client.list_tools(client, client_capabilities: capabilities)
      assert_received {:wire, %{"method" => "tools/list", "params" => %{"_meta" => meta}}}
      assert meta[@caps_key] == capabilities

      ref = %{"type" => "ref/prompt", "name" => "greeting"}
      argument = %{"name" => "name", "value" => "T"}
      opts = [client_capabilities: capabilities]
      assert {:ok, _completion} = Client.complete(client, ref, argument, opts)

      assert_received {:wire,
                       %{"method" => "completion/complete", "params" => %{"_meta" => meta}}}

      assert meta[@caps_key] == capabilities

      # Still a 2026-07-28 option.
      legacy = scripted([], protocol_version: "2025-06-18")

      assert {:error, %ValidationError{field: :client_capabilities, reason: reason}} =
               Client.list_tools(legacy, client_capabilities: capabilities)

      assert reason =~ "requires MCP 2026-07-28"
      refute_received {:wire, _request}
    end

    test "manual rounds with reset_timeout_on_progress need an explicit progress token" do
      client = scripted([])
      reason = "manual MRTR with reset_timeout_on_progress needs an explicit :progress_token"
      round = [mrtr: :manual, reset_timeout_on_progress: true, timeout: 5_000]

      for operation <- [
            &Client.call_tool(client, "ask", %{}, &1),
            &Client.get_prompt(client, "greeting", %{}, &1),
            &Client.read_resource(client, "memo://note", &1)
          ] do
        assert {:error, %ValidationError{field: :progress_token, reason: ^reason}} =
                 operation.(round)
      end

      refute_received {:wire, _request}

      # A token the caller chose is the same on every round.
      for token_opts <- [[progress_token: "up-1"], [meta: %{"progressToken" => "up-1"}]] do
        for _round <- 1..2 do
          assert {:ok, _result} = Client.call_tool(client, "ask", %{}, round ++ token_opts)
          assert_received {:wire, %{"params" => %{"_meta" => %{"progressToken" => "up-1"}}}}
        end
      end

      # Automatic MRTR keeps one generated token for all its rounds, and a
      # request that can't pause has no rounds.
      assert {:ok, _result} =
               Client.call_tool(client, "ask", %{},
                 reset_timeout_on_progress: true,
                 timeout: 5_000
               )

      assert_received {:wire, %{"params" => %{"_meta" => %{"progressToken" => "progress-" <> _}}}}
    end

    test "a continuation is only valid for the operations that can return input_required" do
      tools = %{
        "resultType" => "complete",
        "tools" => [],
        "ttlMs" => 0,
        "cacheScope" => "private"
      }

      client = scripted([tools])

      assert {:error, %ValidationError{field: :input_responses, reason: reason}} =
               Client.list_tools(client, mrtr: :manual, input_responses: @tom)

      assert reason == "is only valid for tools/call, resources/read, prompts/get, not tools/list"

      assert {:error, %ValidationError{field: :request_state}} =
               Client.list_prompts(client, mrtr: :manual, request_state: "sealed")

      refute_received {:wire, _request}

      # Capabilities may go on any modern request, with mrtr: :manual or not.
      assert {:ok, _result} = Client.list_tools(client, mrtr: :manual, client_capabilities: @form)
      assert_received {:wire, %{"method" => "tools/list", "params" => %{"_meta" => meta}}}
      assert meta[@caps_key] == @form
    end

    test "malformed values are refused before anything is sent" do
      client = scripted([])

      for {key, value, reason} <- [
            {:input_responses, [], @responses_shape},
            {:input_responses, %{"name" => "accept"}, @responses_shape},
            {:input_responses, %{"" => %{"action" => "decline"}}, @responses_shape},
            {:input_responses, %{name: %{"action" => "decline"}}, @responses_shape},
            {:input_responses, %{"name" => %{"action" => "accept", "_meta" => %{"p" => self()}}},
             "must be JSON encodable"},
            {:request_state, 1, "must be a string"},
            {:client_capabilities, [], "must be a capabilities object"},
            {:client_capabilities, %{"elicitation" => true},
             "must be a capabilities object whose known capabilities are objects"},
            {:client_capabilities, %{elicitation: %{form: true}},
             "must be a capabilities object whose known capabilities are objects"},
            {:client_capabilities, %{"extensions" => %{"x/y" => 1}},
             "must be a capabilities object whose known capabilities are objects"},
            {:client_capabilities, %{"custom" => self()}, "must be JSON encodable"}
          ] do
        assert {:error, %ValidationError{field: ^key, reason: ^reason}} =
                 Client.call_tool(client, "ask", %{}, [{:mrtr, :manual}, {key, value}])
      end

      refute_received {:wire, _request}
    end

    test "each input response must be an elicitation, sampling or roots result" do
      client = scripted([])

      text = %{"type" => "text", "text" => "Short."}

      valid = [
        %{"action" => "decline"},
        %{action: "cancel"},
        %{
          "action" => "accept",
          "content" => %{"n" => "Tom", "age" => 3, "ok" => true, "t" => ["a"]}
        },
        %{"role" => "assistant", "model" => "m", "content" => text},
        %{"role" => "assistant", "model" => "m", "content" => [text], "stopReason" => "endTurn"},
        %{"roots" => [%{"uri" => "file:///work", "name" => "work"}]},
        %{"roots" => []}
      ]

      for response <- valid do
        assert {:ok, _result} =
                 Client.call_tool(client, "ask", %{},
                   mrtr: :manual,
                   input_responses: %{"id" => response},
                   format: :map
                 )

        assert_received {:wire, %{"params" => %{"inputResponses" => %{"id" => _response}}}}
      end

      sampled = %{"role" => "assistant", "model" => "m", "content" => text}

      invalid = [
        # A response wrapped in a JSON-RPC result, as a reviewer found.
        %{"result" => %{"action" => "accept"}},
        %{},
        %{"action" => "maybe"},
        %{"action" => "accept", "content" => "Tom"},
        %{"action" => "accept", "content" => %{"name" => %{"first" => "Tom"}}},
        %{"role" => "robot", "model" => "m", "content" => text},
        %{"role" => "assistant", "content" => text},
        %{"role" => "assistant", "model" => "m", "content" => %{"text" => "Short."}},
        %{"role" => "assistant", "model" => "m", "content" => [text, "Short."]},
        %{"roots" => "file:///work"},
        %{"roots" => [%{"name" => "work"}]},
        # The second review's cases, which a check of names and types alone
        # let through: the schema's required members, its block types,
        # nested tool results, typed optional fields and integer content.
        %{sampled | "content" => %{"type" => "text"}},
        %{sampled | "content" => %{"type" => "video", "uri" => "x"}},
        %{
          sampled
          | "content" => [%{"type" => "tool_result", "toolUseId" => "t", "content" => "x"}]
        },
        Map.put(sampled, "stopReason", 123),
        Map.put(sampled, "_meta", false),
        %{"roots" => [%{"uri" => "file:///work", "name" => 123}]},
        %{"action" => "accept", "content" => %{"age" => 1.5}}
      ]

      for response <- invalid do
        assert {:error, %ValidationError{field: :input_responses, value: nil, reason: reason}} =
                 Client.call_tool(client, "ask", %{},
                   mrtr: :manual,
                   input_responses: %{"id" => response}
                 )

        assert reason ==
                 ~s("id" is not an elicitation, sampling or roots result of the MCP 2026-07-28 schema)
      end

      refute_received {:wire, _request}
    end

    test "the input-result schema is the one in docs/mcp-specs/2026-07-28" do
      definitions =
        "../../../docs/mcp-specs/2026-07-28/schema.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("$defs")

      embedded = InputResultSchema.definitions()
      assert InputResultSchema.results() -- Map.keys(embedded) == []

      assert embedded ==
               Map.take(definitions, referenced(InputResultSchema.results(), definitions))
    end

    # A forwarding handler must never crash on what it was given: a struct is
    # a map but not a JSON object, and most aren't Enumerable.
    test "structs are refused at every level, never enumerated" do
      client = scripted([])

      for {key, value} <- [
            input_responses: %URI{},
            input_responses: %{"id" => %URI{}},
            input_responses: %{"id" => %{"action" => "accept", "content" => %URI{}}},
            input_responses: %{"id" => %{"roots" => [%URI{}]}},
            input_responses: %{"id" => %{"role" => "user", "model" => "m", "content" => %URI{}}},
            client_capabilities: %URI{},
            client_capabilities: %{"elicitation" => %URI{}},
            client_capabilities: %{"extensions" => %URI{}},
            client_capabilities: %{"elicitation" => %{"form" => %URI{}}},
            client_capabilities: %{"extensions" => %{"x/y" => %URI{}}},
            client_capabilities: %{"custom" => %URI{}}
          ] do
        assert {:error, %ValidationError{field: ^key}} =
                 Client.call_tool(client, "ask", %{}, [{:mrtr, :manual}, {key, value}])
      end

      refute_received {:wire, _request}
    end

    test "input_responses are held to :max_mrtr_bytes" do
      client = scripted([])

      assert {:error, %ValidationError{field: :input_responses, reason: reason}} =
               Client.call_tool(client, "ask", %{},
                 mrtr: :manual,
                 input_responses: @tom,
                 max_mrtr_bytes: 16
               )

      assert reason == "exceed the MRTR byte limit of 16 (:max_mrtr_bytes)"
      refute_received {:wire, _request}
    end

    test "the errors don't carry the input responses or the request state" do
      client = scripted([])

      for {key, value} <- [input_responses: %{"name" => "secret"}, request_state: %{"s" => 1}] do
        assert {:error, %ValidationError{value: nil}} =
                 Client.call_tool(client, "ask", %{}, [{:mrtr, :manual}, {key, value}])
      end

      assert {:error, %ValidationError{value: nil}} =
               Client.call_tool(client, "ask", %{}, input_responses: %{"name" => %{}})
    end

    test "mrtr must be :auto or :manual" do
      client = scripted([])

      assert_raise ArgumentError, "mrtr must be :auto or :manual", fn ->
        Client.call_tool(client, "ask", %{}, mrtr: :later)
      end
    end

    test "a legacy request with client_capabilities is refused, not answered from the cache" do
      note = %{"contents" => [%{"uri" => "memo://note", "text" => "cached"}]}

      client =
        scripted([note],
          protocol_version: "2025-06-18",
          client: [default_cache_ttl_ms: 60_000]
        )

      assert {:ok, ^note} = Client.read_resource(client, "memo://note", format: :map)
      assert_received {:wire, %{"method" => "resources/read"}}

      assert {:error, %ValidationError{field: :client_capabilities}} =
               Client.read_resource(client, "memo://note",
                 mrtr: :manual,
                 client_capabilities: @form
               )

      # The cache still answers the same read without the option.
      assert {:ok, ^note} = Client.read_resource(client, "memo://note", format: :map)
      refute_received {:wire, _request}
    end

    test "a request without the options carries nothing new to a legacy server" do
      client = scripted([], protocol_version: "2025-06-18")

      assert {:ok, _result} = Client.call_tool(client, "ask", %{}, mrtr: :manual, format: :map)
      assert_received {:wire, %{"params" => params}}
      refute Map.has_key?(params, "_meta")

      assert {:error, %ValidationError{field: :client_capabilities}} =
               Client.call_tool(client, "ask", %{}, mrtr: :manual, client_capabilities: @form)

      refute_received {:wire, _request}
    end
  end

  # Every definition the named ones reach through `$ref`, themselves included.
  defp referenced(names, definitions, seen \\ MapSet.new())
  defp referenced([], _definitions, seen), do: MapSet.to_list(seen)

  defp referenced([name | rest], definitions, seen) do
    if MapSet.member?(seen, name) do
      referenced(rest, definitions, seen)
    else
      refs = definitions |> Map.fetch!(name) |> refs()
      referenced(refs ++ rest, definitions, MapSet.put(seen, name))
    end
  end

  defp refs(%{"$ref" => "#/$defs/" <> name} = schema),
    do: [name | refs(Map.delete(schema, "$ref"))]

  defp refs(schema) when is_map(schema), do: Enum.flat_map(Map.values(schema), &refs/1)
  defp refs(schemas) when is_list(schemas), do: Enum.flat_map(schemas, &refs/1)
  defp refs(_value), do: []

  def forward_mrtr_telemetry(event, measurements, metadata, test_pid) do
    # The events run in the calling process; other tests' calls aren't ours.
    if self() == test_pid, do: send(test_pid, {:mrtr_telemetry, event, measurements, metadata})
  end

  # Servers

  defp connect(transport, opts \\ [])

  defp connect(:http, opts) do
    url = start_http_app()
    {mode, opts} = Keyword.pop(opts, :protocol_mode, :modern_only)

    start_client(
      [
        transport: :http,
        url: url,
        protocol_mode: mode,
        use_sse: false,
        security: %{origin: nil}
      ] ++ opts
    )
  end

  defp connect(:test, opts) do
    {mode, opts} = Keyword.pop(opts, :protocol_mode, :modern_only)

    server =
      start_supervised!(
        {HandlerServer,
         handler: AppHandler,
         handler_args: [test_pid: self()],
         transport: :test,
         protocol_mode: mode,
         mrtr: true,
         request_state: [active_key_id: "manual", keys: %{"manual" => @key}]},
        id: make_ref()
      )

    start_client([transport: :test, server: server, protocol_mode: mode] ++ opts)
  end

  defp start_http_app do
    runtime =
      start_supervised!(
        {Runtime,
         handler: AppHandler, handler_args: [test_pid: self()], transport: :mounted_http},
        id: make_ref()
      )

    plug_opts = [
      runtime: runtime,
      path: "/mcp",
      protocol_mode: :prefer_modern,
      request_state: [active_key_id: "manual", keys: %{"manual" => @key}],
      principal_id: "gateway-test"
    ]

    listener =
      start_supervised!(
        {Bandit,
         plug: {Arbor.MCP.HttpPlug, plug_opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp start_client(opts) do
    defaults = [
      capabilities: @form,
      handler: {ClientHandler, [owner: self()]},
      health_check_interval: nil,
      reconnect: false
    ]

    {:ok, client} = Client.start_link(Keyword.merge(defaults, opts))

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    client
  end

  # A ready client whose server answers with `results`, one per request.
  defp scripted(results, opts \\ []) do
    owner = self()
    version = Keyword.get(opts, :protocol_version, "2026-07-28")

    client_opts =
      [
        _skip_connect: true,
        handler: {ClientHandler, [owner: owner]},
        capabilities: @form,
        health_check_interval: nil
      ] ++ Keyword.get(opts, :client, [])

    client = start_supervised!({Client, client_opts}, id: make_ref())

    :sys.replace_state(client, fn state ->
      %{
        state
        | transport_mod: ScriptedTransport,
          transport_state: %{owner: owner, results: results},
          protocol_version: version,
          connection_status: :ready,
          initialized: true
      }
    end)

    client
  end

  defp input_required(input_requests) do
    %{
      "resultType" => "input_required",
      "inputRequests" => input_requests,
      "requestState" => "sealed"
    }
  end
end
