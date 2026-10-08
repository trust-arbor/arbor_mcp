defmodule Arbor.MCP.Integration.UrlElicitationCompleteTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Context, HandlerServer}

  @key :binary.copy(<<64>>, 32)

  defmodule ServerHandler do
    use Arbor.MCP.Server.Handler

    def init(args) when is_list(args), do: {:ok, Map.new(args)}
    def init(args) when is_map(args), do: {:ok, args}

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(_cursor, state) do
      tool = %{
        name: "login",
        description: "URL elicit then complete",
        inputSchema: %{type: "object", properties: %{}}
      }

      {:ok, [tool], nil, state}
    end

    @impl true
    def handle_call_tool("login", _arguments, state) do
      case Context.input_responses() do
        nil ->
          requests = %{
            "login" =>
              Server.elicit(%{
                message: "Sign in to continue",
                mode: "url",
                url: "https://auth.example.com/login"
              })
          }

          {:input_required, requests, state}

        %{"login" => _} ->
          {:ok, %{content: [%{type: "text", text: "signed in"}]}, state}
      end
    end

    def handle_call_tool(_name, _arguments, state), do: {:error, "unknown tool", state}

    @impl true
    def handle_elicitation_complete(elicitation_id, state) do
      send(state.test_pid, {:elicitation_complete, elicitation_id})
      {:ok, Map.put(state, :completed, elicitation_id)}
    end
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
    def handle_url_elicitation(message, url, elicitation_id, state) do
      send(state.owner, {:url_elicitation, message, url, elicitation_id})
      {:ok, %{"action" => "accept", "content" => %{"authenticated" => true}}, state}
    end
  end

  test "URL elicit /4 sees generated id and complete notify delivers it" do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ServerHandler,
        handler_args: [test_pid: self()],
        transport: :test,
        protocol_mode: :modern_only,
        mrtr: true,
        request_state: [active_key_id: "integration", keys: %{"integration" => @key}]
      )

    Arbor.MCP.TestHelpers.stop_on_exit(server)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :modern_only,
        capabilities: %{"elicitation" => %{"form" => %{}, "url" => %{}}},
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

    assert {:ok, result} = Client.call_tool(client, "login", %{}, format: :map)
    assert result["resultType"] == "complete"
    assert result["content"] == [%{"type" => "text", "text" => "signed in"}]

    assert_receive {:url_elicitation, "Sign in to continue", "https://auth.example.com/login",
                    elicitation_id}

    assert is_binary(elicitation_id)
    assert String.starts_with?(elicitation_id, "elicit-")

    :ok =
      Client.notify(client, "notifications/elicitation/complete", %{
        "elicitationId" => elicitation_id
      })

    assert_receive {:elicitation_complete, ^elicitation_id}, 1_000
  end
end
