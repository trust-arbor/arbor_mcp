defmodule Arbor.MCP.Integration.MRTRRoundTripTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.{Context, HandlerServer}

  @key :binary.copy(<<64>>, 32)

  defmodule ServerHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(_cursor, state) do
      tool = %{
        name: "onboard",
        description: "Collect a name before completing",
        inputSchema: %{type: "object", properties: %{}}
      }

      {:ok, [tool], nil, state}
    end

    @impl true
    def handle_call_tool("onboard", _arguments, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "name" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "What should we call you?",
                "requestedSchema" => %{"type" => "object"}
              }
            }
          }

          {:input_required, requests, %{"prefix" => "Welcome"}, state}

        %{"name" => %{"content" => %{"name" => name}}} ->
          {:ok,
           %{
             content: [
               %{type: "text", text: "#{Context.request_state()["prefix"]}, #{name}"}
             ]
           }, state}
      end
    end

    def handle_call_tool(_name, _arguments, state), do: {:error, "unknown tool", state}
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not configured", state}

    @impl true
    def handle_elicitation_create(message, _schema, state) do
      send(state.owner, {:mrtr_elicitation, message})
      {:ok, %{"action" => "accept", "content" => %{"name" => "Lin"}}, state}
    end
  end

  test "modern client and handler server complete an elicitation-driven tool call" do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ServerHandler,
        transport: :test,
        protocol_mode: :modern_only,
        mrtr: true,
        request_state: [active_key_id: "integration", keys: %{"integration" => @key}]
      )

    on_exit(fn -> Arbor.MCP.TestHelpers.safe_stop_process(server) end)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :modern_only,
        capabilities: %{"elicitation" => %{"form" => %{}}},
        handler: {ClientHandler, [owner: self()]},
        health_check_interval: nil
      )

    on_exit(fn ->
      try do
        Client.disconnect(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert {:ok, result} = Client.call_tool(client, "onboard", %{}, format: :map)
    assert result["resultType"] == "complete"
    assert result["content"] == [%{"type" => "text", "text" => "Welcome, Lin"}]
    assert_receive {:mrtr_elicitation, "What should we call you?"}
  end
end
