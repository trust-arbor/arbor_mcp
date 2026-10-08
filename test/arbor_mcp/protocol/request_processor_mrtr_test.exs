defmodule Arbor.MCP.Protocol.RequestProcessorMRTRTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.RequestProcessor
  alias Arbor.MCP.Server.Context

  @key :binary.copy(<<11>>, 32)

  defmodule Handler do
    def get_server_info_from_opts, do: %{"name" => "mrtr", "version" => "1"}
    def get_capabilities, do: %{}

    def handle_call_tool("direct", _arguments, state) do
      case Context.input_responses() do
        nil ->
          {:input_required,
           %{
             "approval" => %{
               "method" => "elicitation/create",
               "params" => %{"message" => "Approve", "requestedSchema" => %{}}
             }
           }, %{"source" => "request-processor"}, state}

        %{"approval" => %{"action" => "accept"}} ->
          {:ok, %{content: [%{type: "text", text: Context.request_state()["source"]}]}, state}
      end
    end
  end

  test "direct request processor supports sealed MRTR retries" do
    state = %{
      __module__: Handler,
      protocol_mode: :modern_only,
      request_state: [active_key_id: "direct", keys: %{"direct" => @key}]
    }

    assert {:response, %{"result" => interim}, state} =
             RequestProcessor.process(request(1, params()), state)

    retry_params =
      params()
      |> Map.put("inputResponses", %{"approval" => %{"action" => "accept"}})
      |> Map.put("requestState", interim["requestState"])

    assert {:response, %{"result" => result}, _state} =
             RequestProcessor.process(request(2, retry_params), state)

    assert result["resultType"] == "complete"
    assert result["content"] == [%{"type" => "text", "text" => "request-processor"}]
  end

  defp request(id, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params}
  end

  defp params do
    %{
      "name" => "direct",
      "arguments" => %{},
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
      }
    }
  end
end
