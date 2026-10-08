defmodule Arbor.MCP.MessageProcessorMRTRTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.MessageProcessor
  alias Arbor.MCP.Server.Context

  @key :binary.copy(<<23>>, 32)

  defmodule Handler do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_call_tool("http-mrtr", _arguments, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "approval" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "Approve HTTP operation",
                "requestedSchema" => %{"type" => "object"}
              }
            }
          }

          {:input_required, requests, %{"transport" => "http"}, state}

        %{"approval" => %{"action" => "accept"}} ->
          {:ok,
           %{
             content: [
               %{type: "text", text: "resumed:" <> Context.request_state()["transport"]}
             ]
           }, state}
      end
    end

    def handle_call_tool(_name, _arguments, state), do: {:error, "unknown", state}
  end

  test "the handler-process bridge preserves verified MRTR context" do
    first = process(request(1, params()))
    interim = first.response["result"]

    assert interim["resultType"] == "input_required"
    assert is_binary(interim["requestState"])

    retry_params =
      params()
      |> Map.put("inputResponses", %{"approval" => %{"action" => "accept"}})
      |> Map.put("requestState", interim["requestState"])

    second = process(request(2, retry_params))

    assert second.response["result"]["resultType"] == "complete"

    assert second.response["result"]["content"] == [
             %{"type" => "text", "text" => "resumed:http"}
           ]
  end

  defp process(request) do
    request
    |> MessageProcessor.new(transport: :http)
    |> MessageProcessor.process(%{
      handler: Handler,
      handler_opts: [],
      protocol_mode: :modern_only,
      request_state: [active_key_id: "http", keys: %{"http" => @key}],
      endpoint: "/mcp"
    })
  end

  defp request(id, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params}
  end

  defp params do
    %{
      "name" => "http-mrtr",
      "arguments" => %{},
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
      }
    }
  end
end
