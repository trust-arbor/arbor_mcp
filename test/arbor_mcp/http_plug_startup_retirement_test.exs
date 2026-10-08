defmodule Arbor.MCP.HttpPlugStartupRetirementTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.{Context, Runtime}

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      send(opts[:test], :retained_plug_initialized)
      {:ok, 0}
    end

    @impl true
    def handle_call_tool("count", _arguments, state) do
      {:ok,
       %{
         "content" => [],
         "structuredContent" => %{
           "count" => state,
           "source" => Context.current().application_context[:source]
         }
       }, state + 1}
    end
  end

  defmodule Router do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    forward("/mcp",
      to: Arbor.MCP.HttpPlug,
      init_opts: [
        runtime: Arbor.MCP.HttpPlugStartupRetirementTest.Runtime,
        protocol_mode: :modern_only,
        handler_opts: [source: "compiled_mount"]
      ]
    )
  end

  test "compiled mounts retain pure initialization and fail closed without a runtime" do
    Code.ensure_loaded!(HttpPlug)
    refute function_exported?(HttpPlug, :start_link, 0)
    refute function_exported?(HttpPlug, :start_link, 1)
    assert function_exported?(HttpPlug, :init, 1)
    assert function_exported?(HttpPlug, :call, 2)
    assert function_exported?(HttpPlug, :broadcast_resource_update, 1)
    refute Process.whereis(__MODULE__.Runtime)

    config = HttpPlug.init(runtime: __MODULE__.Runtime, protocol_mode: :modern_only)
    assert {^config, []} = Code.eval_quoted(Macro.escape(config))
    refute Process.whereis(__MODULE__.Runtime)

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        Router.call(request(1), Router.init([]))
      end

    assert error.reason == %HttpPlug.RuntimeWriter.AdmissionError{}
  end

  test "the retained forwarded Plug shares named runtime state across requests" do
    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test: self()],
         name: __MODULE__.Runtime,
         transport: :mounted_http,
         protocol_mode: :modern_only}
      )

    assert_receive :retained_plug_initialized, 1_000

    for {id, count} <- [{1, 0}, {2, 1}] do
      conn = Router.call(request(id), Router.init([]))
      assert conn.status == 200, conn.resp_body
      assert conn.halted

      assert %{
               "jsonrpc" => "2.0",
               "id" => ^id,
               "result" => %{
                 "structuredContent" => %{"count" => ^count, "source" => "compiled_mount"}
               }
             } = Jason.decode!(conn.resp_body)
    end

    refute_receive :retained_plug_initialized, 10
    assert Process.whereis(__MODULE__.Runtime) == root
  end

  defp request(id) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "count",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    Plug.Test.conn(:post, "/mcp", Jason.encode!(message))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
    |> Plug.Conn.put_req_header("mcp-method", "tools/call")
    |> Plug.Conn.put_req_header("mcp-name", "count")
  end
end
