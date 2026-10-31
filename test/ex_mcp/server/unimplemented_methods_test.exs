defmodule ExMCP.Server.UnimplementedMethodsTest do
  @moduledoc """
  A handler built with `use ExMCP.Server.Handler` answers each optional
  method it doesn't serve with JSON-RPC -32601 Method not found (#180), as
  the 2026-07-28 schema asks for a method behind a capability the server did
  not advertise. Over modern Streamable HTTP that error goes out with HTTP
  404, as for an unknown method.
  """

  use ExUnit.Case, async: true

  alias ExMCP.{Client, HttpPlug, MessageProcessor}
  alias ExMCP.Error.ProtocolError
  alias ExMCP.Server.Dispatch

  defmodule ToolsOnly do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool("echo", _args, state),
      do: {:ok, %{content: [%{type: "text", text: "ok"}]}, state}

    # As a gateway answers when its upstream doesn't implement a method.
    def handle_call_tool("forwarded", _args, state),
      do: {:error, ExMCP.Error.protocol_error(-32601, "Method not found: tools/call"), state}
  end

  defmodule TaskStore do
    @moduledoc false
    use ExMCP.Server.Handler, tasks: :store
  end

  @modern "2026-07-28"
  @legacy "2025-06-18"

  @completion %{
    "ref" => %{"type" => "ref/prompt", "name" => "p"},
    "argument" => %{"name" => "a", "value" => "b"}
  }

  # Optional methods of either era, none of which ToolsOnly serves.
  @both_eras [
    {"resources/list", %{}},
    {"resources/templates/list", %{}},
    {"resources/read", %{"uri" => "memo://x"}},
    {"prompts/list", %{}},
    {"prompts/get", %{"name" => "p"}},
    {"completion/complete", @completion}
  ]

  @legacy_only [
    {"resources/subscribe", %{"uri" => "memo://x"}},
    {"resources/unsubscribe", %{"uri" => "memo://x"}},
    {"roots/list", %{}},
    {"tasks/get", %{"taskId" => "t"}},
    {"tasks/result", %{"taskId" => "t"}},
    {"tasks/list", %{}},
    {"tasks/cancel", %{"taskId" => "t"}}
  ]

  # Reached with the Tasks extension declared, so they get to the handler.
  @modern_tasks [
    {"tasks/get", %{"taskId" => "t"}},
    {"tasks/cancel", %{"taskId" => "t"}},
    {"tasks/update", %{"taskId" => "t", "inputResponses" => %{}}}
  ]

  @tasks_capabilities %{"extensions" => %{"io.modelcontextprotocol/tasks" => %{}}}

  defp meta(capabilities) do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => capabilities
    }
  end

  defp request(method, params, id \\ 1),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp modern(method, params, capabilities \\ %{}),
    do: request(method, Map.put(params, "_meta", meta(capabilities)))

  defp dispatch(request, handler \\ ToolsOnly) do
    {:ok, state} = handler.init([])
    assert {:response, response, ^state} = Dispatch.dispatch(request, handler, state, [])
    # As the client would read it.
    response |> Jason.encode!() |> Jason.decode!()
  end

  defp assert_method_not_found(response, method) do
    assert %{"error" => %{"code" => -32601, "message" => message}} = response
    assert message == "Method not found: #{method}"
  end

  describe "Dispatch" do
    test "legacy requests for methods the handler doesn't serve are -32601" do
      for {method, params} <- @both_eras ++ @legacy_only do
        method |> request(params) |> dispatch() |> assert_method_not_found(method)
      end
    end

    test "modern requests for methods the handler doesn't serve are -32601" do
      for {method, params} <- @both_eras do
        method |> modern(params) |> dispatch() |> assert_method_not_found(method)
      end

      for {method, params} <- @modern_tasks do
        method
        |> modern(params, @tasks_capabilities)
        |> dispatch()
        |> assert_method_not_found(method)
      end
    end

    test "the task store serves no legacy task method" do
      for method <- ["tasks/get", "tasks/cancel"] do
        method
        |> request(%{"taskId" => "t"})
        |> dispatch(TaskStore)
        |> assert_method_not_found(method)
      end
    end

    test "a callback that calls super gets the -32601 reason" do
      assert {:error, %ProtocolError{code: -32601, message: "Method not found: prompts/list"},
              :state} = ToolsOnly.handle_list_prompts(nil, :state)
    end
  end

  # A server that serves a capability answers the parts of it a handler
  # leaves out as the TypeScript SDK's McpServer does: an empty list or
  # completion, not -32601.
  describe "served capabilities" do
    defmodule Scaffold do
      @moduledoc false
      use ExMCP.Server.Handler
      # 1.x has no DSL completer generator: advertise and implement it explicitly.
      def __server_capabilities__, do: %{resources: %{}, prompts: %{}, completions: %{}}

      def handle_complete(%{"name" => "scaffold"}, %{"name" => "language"}, state),
        do: {:ok, %{"completion" => %{"values" => ["elixir", "erlang"]}}, state}

      def handle_complete(ref, argument, state), do: super(ref, argument, state)
    end

    defmodule TemplatesOnly do
      @moduledoc false
      use ExMCP.Server.Handler
      def __server_capabilities__, do: %{resources: %{}}
    end

    # Declares resources itself and serves only their list.
    defmodule DeclaredResources do
      @moduledoc false
      use ExMCP.Server.Handler

      def __server_capabilities__, do: %{resources: %{}}

      @impl true
      def handle_list_resources(_cursor, state),
        do: {:ok, [%{uri: "mem://a", name: "a"}], nil, state}
    end

    defp complete(argument, value) do
      request("completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "scaffold"},
        "argument" => %{"name" => argument, "value" => value}
      })
    end

    test "an argument without a completer completes to nothing" do
      assert %{"result" => %{"completion" => %{"values" => [], "hasMore" => false}}} =
               "name" |> complete("my") |> dispatch(Scaffold)

      assert %{"result" => %{"completion" => %{"values" => ["elixir", "erlang"]}}} =
               "language" |> complete("e") |> dispatch(Scaffold)

      assert %{"result" => %{"resultType" => "complete", "completion" => %{"values" => []}}} =
               "completion/complete"
               |> modern(%{
                 "ref" => %{"type" => "ref/prompt", "name" => "scaffold"},
                 "argument" => %{"name" => "name", "value" => "my"}
               })
               |> dispatch(Scaffold)
    end

    test "resources without templates list no templates, and templates no resources" do
      for request <- [
            request("resources/templates/list", %{}),
            modern("resources/templates/list", %{})
          ] do
        assert %{"result" => %{"resourceTemplates" => []}} = dispatch(request, Scaffold)
      end

      for request <- [request("resources/list", %{}), modern("resources/list", %{})] do
        assert %{"result" => %{"resources" => []}} = dispatch(request, TemplatesOnly)
      end

      assert %{"result" => %{"resourceTemplates" => []}} =
               "resources/templates/list" |> request(%{}) |> dispatch(DeclaredResources)

      assert %{"error" => %{"code" => -32602, "message" => "Resource not found: mem://b"}} =
               "resources/read" |> request(%{"uri" => "mem://b"}) |> dispatch(DeclaredResources)
    end

    test "a capability the server doesn't serve stays -32601" do
      # Scaffold serves prompts, resources and completions, but no tasks.
      "tasks/get"
      |> request(%{"taskId" => "t"})
      |> dispatch(Scaffold)
      |> assert_method_not_found("tasks/get")

      # TemplatesOnly serves no prompts.
      "prompts/list"
      |> request(%{})
      |> dispatch(TemplatesOnly)
      |> assert_method_not_found("prompts/list")
    end

    test "the MessageProcessor path answers the same" do
      conn =
        "resources/templates/list"
        |> modern(%{})
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: Scaffold})

      refute Map.has_key?(conn.assigns, :http_status)
      assert %{"result" => %{"resourceTemplates" => []}} = conn.response

      conn =
        "name"
        |> complete("my")
        |> MessageProcessor.new()
        |> MessageProcessor.process(%{handler: Scaffold})

      assert %{"result" => %{"completion" => %{"values" => []}}} = conn.response
    end
  end

  describe "mounted HTTP" do
    setup do
      %{
        opts:
          HttpPlug.init(
            handler: ToolsOnly,
            path: "/mcp",
            protocol_mode: :prefer_modern,
            allowed_origins: :any
          )
      }
    end

    defp http_client(mode) do
      opts =
        HttpPlug.init(
          handler: ToolsOnly,
          path: "/mcp",
          protocol_mode: mode,
          allowed_origins: :any
        )

      bypass = Bypass.open()
      Bypass.stub(bypass, "POST", "/mcp", &HttpPlug.call(&1, opts))
      Bypass.stub(bypass, "DELETE", "/mcp", &HttpPlug.call(&1, opts))

      start_supervised!(
        {Client,
         transport: :http,
         url: "http://127.0.0.1:#{bypass.port}/mcp",
         protocol_mode: mode,
         use_sse: false,
         health_check_interval: nil,
         reconnect: false}
      )
    end

    defp post(body, headers, opts) do
      headers
      |> Enum.reduce(Plug.Test.conn(:post, "/mcp", Jason.encode!(body)), fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> HttpPlug.call(opts)
    end

    test "a modern request is answered with 404 and -32601", %{opts: opts} do
      for {method, params} <-
            [{"resources/list", %{}}, {"prompts/list", %{}}] ++
              [{"completion/complete", @completion}] do
        conn =
          post(
            modern(method, params),
            [{"mcp-protocol-version", @modern}, {"mcp-method", method}],
            opts
          )

        assert conn.status == 404
        conn.resp_body |> Jason.decode!() |> assert_method_not_found(method)
      end
    end

    test "a modern request with a progress token is still answered with 404 and -32601", %{
      opts: opts
    } do
      # The token selects an event stream, but nothing went out before the
      # final response, so it can still carry the status.
      request = modern("prompts/list", %{})
      request = put_in(request, ["params", "_meta", "progressToken"], "p")

      conn =
        post(request, [{"mcp-protocol-version", @modern}, {"mcp-method", "prompts/list"}], opts)

      assert conn.status == 404
      assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      conn.resp_body |> Jason.decode!() |> assert_method_not_found("prompts/list")
    end

    test "a modern request for a named entry is answered with 404 and -32601", %{opts: opts} do
      conn =
        post(
          modern("prompts/get", %{"name" => "p"}),
          [{"mcp-protocol-version", @modern}, {"mcp-method", "prompts/get"}, {"mcp-name", "p"}],
          opts
        )

      assert conn.status == 404
      conn.resp_body |> Jason.decode!() |> assert_method_not_found("prompts/get")
    end

    test "a legacy client gets the JSON-RPC error over HTTP" do
      client = http_client(:legacy_only)

      assert {:error, %{"code" => -32601, "message" => "Method not found: prompts/list"}} =
               Client.list_prompts(client, format: :map)

      assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = Client.list_tools(client, format: :map)
    end

    test "a modern client gets the JSON-RPC error out of the 404 over HTTP" do
      client = http_client(:modern_only)

      assert {:error, %{"code" => -32601, "message" => "Method not found: prompts/list"}} =
               Client.list_prompts(client, format: :map)

      # A request stream, which a progress token opens, reads it the same way.
      assert {:error, %{"code" => -32601, "message" => "Method not found: tools/call"}} =
               Client.call_tool(client, "forwarded", %{}, progress_token: "p", format: :map)

      assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = Client.list_tools(client, format: :map)
      assert :sys.get_state(client).connection_status == :ready
    end

    test "a legacy request keeps 200", %{opts: opts} do
      init =
        post(
          request(
            "initialize",
            %{
              "protocolVersion" => @legacy,
              "capabilities" => %{},
              "clientInfo" => %{"name" => "test", "version" => "1"}
            },
            99
          ),
          [],
          opts
        )

      [session] = Plug.Conn.get_resp_header(init, "mcp-session-id")

      post(
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        [{"mcp-session-id", session}, {"mcp-protocol-version", @legacy}],
        opts
      )

      conn =
        post(
          request("prompts/list", %{}),
          [{"mcp-protocol-version", @legacy}, {"mcp-session-id", session}],
          opts
        )

      assert conn.status == 200
      conn.resp_body |> Jason.decode!() |> assert_method_not_found("prompts/list")
    end
  end

  describe "MessageProcessor" do
    defp process(request) do
      request
      |> MessageProcessor.new()
      |> MessageProcessor.process(%{handler: ToolsOnly})
    end

    test "a modern request is marked for HTTP 404" do
      conn = process(modern("prompts/list", %{}))

      assert conn.assigns[:http_status] == 404
      assert_method_not_found(conn.response, "prompts/list")
    end

    test "a legacy request carries no HTTP status of its own" do
      conn = process(request("resources/list", %{}))

      refute Map.has_key?(conn.assigns, :http_status)
      assert_method_not_found(conn.response, "resources/list")
    end
  end
end
