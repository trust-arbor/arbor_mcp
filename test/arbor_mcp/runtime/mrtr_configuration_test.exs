defmodule Arbor.MCP.Server.Runtime.MRTRConfigurationTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.{Context, Runtime}
  alias Arbor.MCP.Server.Runtime.Config

  @ring [active_key_id: "test", keys: %{"test" => :binary.copy(<<42>>, 32)}]

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    def init(opts) do
      if owner = opts[:owner], do: send(owner, :handler_initialized)
      {:ok, %{}}
    end

    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "ask", inputSchema: %{type: "object"}}], nil, state}

    def handle_call_tool("ask", _arguments, state) do
      if Context.input_responses() do
        {:ok, %{content: [%{type: "text", text: Context.request_state()["step"]}]}, state}
      else
        request = %{
          "name" => %{
            "method" => "elicitation/create",
            "params" => %{
              "message" => "Name?",
              "requestedSchema" => %{"type" => "object", "properties" => %{}}
            }
          }
        }

        {:input_required, request, %{"step" => "resumed"}, state}
      end
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_mcp, :request_state)
    Application.delete_env(:arbor_mcp, :request_state)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :request_state, value)
        :error -> Application.delete_env(:arbor_mcp, :request_state)
      end
    end)
  end

  test "every transport validates an explicitly enabled MRTR ring" do
    for transport <- [:mounted_http, :http, :test, :beam, :stdio] do
      assert {:error, {:mrtr_configuration_error, :request_state_not_configured}} =
               Config.new(handler: Handler, transport: transport, mrtr: true)
    end
  end

  test "invalid MRTR configuration is rejected before the handler starts" do
    assert {:error, {:mrtr_configuration_error, :request_state_not_configured}} =
             Runtime.start_link(
               handler: Handler,
               handler_args: [owner: self()],
               transport: :mounted_http,
               mrtr: true
             )

    refute_received :handler_initialized
  end

  test "retains explicit rings and validates nested owned HTTP MRTR options" do
    assert {:ok, config} =
             Config.new(
               handler: Handler,
               transport: :mounted_http,
               mrtr: true,
               request_state: @ring
             )

    assert config.dispatch_opts[:request_state] == @ring

    assert {:error, {:mrtr_configuration_error, :request_state_not_configured}} =
             Config.new(handler: Handler, transport: :http, http: [mrtr: true])

    assert {:ok, nested} =
             Config.new(
               handler: Handler,
               transport: :http,
               http: [mrtr: true, request_state: @ring]
             )

    assert nested.dispatch_opts[:request_state] == @ring
  end

  test "unknown Runtime options are rejected without returning their values" do
    assert {:error, {:unknown_runtime_options, [:mrtr_typo]}} =
             Config.new(handler: Handler, mrtr_typo: "private-option-value")
  end

  test "a named mount can compile before its Runtime and key ring are available" do
    assert %{runtime: __MODULE__} = HttpPlug.init(runtime: __MODULE__, mrtr: true)
  end

  test "mounted HTTP seals and resumes with the Runtime's explicit ring" do
    runtime =
      start_supervised!(
        {Runtime, handler: Handler, transport: :mounted_http, mrtr: true, request_state: @ring}
      )

    mount =
      HttpPlug.init(runtime: runtime, protocol_mode: :modern_only, principal_id: "test-user")

    params = %{
      "name" => "ask",
      "arguments" => %{},
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{"form" => %{}}}
      }
    }

    first = post(mount, params, 1)
    assert first["result"]["resultType"] == "input_required"
    token = first["result"]["requestState"]
    assert is_binary(token)

    retry =
      Map.merge(params, %{
        "requestState" => token,
        "inputResponses" => %{"name" => %{"action" => "accept", "content" => %{}}}
      })

    assert %{"result" => %{"content" => [%{"text" => "resumed"}]}} = post(mount, retry, 2)
  end

  defp post(mount, params, id) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => params
      })

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
      |> Plug.Conn.put_req_header("mcp-method", "tools/call")
      |> Plug.Conn.put_req_header("mcp-name", "ask")
      |> HttpPlug.call(mount)

    Jason.decode!(conn.resp_body)
  end
end
