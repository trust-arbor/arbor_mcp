defmodule Arbor.MCP.Protocol.InitializeCharacterizationTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.RequestProcessor

  defmodule RequestProcessorServer do
    def get_server_info_from_opts do
      %{"name" => "request-processor", "version" => "1.0.0"}
    end

    def get_capabilities, do: %{"source" => "request-processor"}
  end

  defmodule MessageProcessorHandler do
    use Arbor.MCP.Server.Handler

    @impl GenServer
    def init(_args), do: {:ok, %{}}

    @impl Arbor.MCP.Server.Handler
    def handle_initialize(params, state) do
      {:ok,
       %{
         protocolVersion: params["protocolVersion"],
         serverInfo: %{name: "message-processor", version: "1.0.0"},
         capabilities: %{source: "message-processor"}
       }, state}
    end
  end

  defmodule DefaultHandler do
    use Arbor.MCP.Server.Handler

    @impl GenServer
    def init(_args), do: {:ok, %{}}
  end

  defmodule DSLServer do
    @behaviour Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "dsl-server", version: "1.0.0"

    @impl Arbor.MCP.Server.Handler
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    @impl Arbor.MCP.Server.Handler
    def handle_call_tool(_name, _arguments, state), do: {:error, "Tool not found", state}
  end

  test "retained initialize implementations match the committed historical golden" do
    fixture_path = Path.expand("../../fixtures/protocol/initialize_results.term", __DIR__)

    {expected, _binding} =
      fixture_path
      |> File.read!()
      |> Code.eval_string([], file: fixture_path)

    actual =
      VersionRegistry.supported_versions()
      |> Enum.map(&{&1, initialize_results(&1)})
      |> Map.new()
      |> Map.put("omitted", initialize_results(nil))

    expected =
      Map.new(expected, fn {version, results} -> {version, Map.delete(results, :http_server)} end)

    assert actual == expected
  end

  defp initialize_results(version) do
    params =
      %{
        "capabilities" => %{},
        "clientInfo" => %{"name" => "fixture-client", "version" => "1.0.0"}
      }
      |> maybe_put_version(version)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => params
    }

    %{
      request_processor: request_processor_result(request),
      message_processor: message_processor_result(request),
      server_handler: handler_result(params),
      server_dsl: dsl_result(params)
    }
  end

  defp request_processor_result(request) do
    state = %{__module__: RequestProcessorServer}
    {:response, response, _state} = RequestProcessor.process(request, state)
    response["result"]
  end

  defp message_processor_result(request) do
    request
    |> Arbor.MCP.MessageProcessor.new()
    |> Arbor.MCP.MessageProcessor.process(%{handler: MessageProcessorHandler})
    |> Map.fetch!(:response)
    |> Map.fetch!("result")
  end

  defp handler_result(params) do
    {:ok, result, _state} = DefaultHandler.handle_initialize(params, %{})
    result
  end

  defp dsl_result(params) do
    {:ok, result, _state} = DSLServer.handle_initialize(params, %{})
    result
  end

  defp maybe_put_version(params, nil), do: params
  defp maybe_put_version(params, version), do: Map.put(params, "protocolVersion", version)
end
