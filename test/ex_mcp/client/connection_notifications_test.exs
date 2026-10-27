defmodule ExMCP.Client.ConnectionNotificationsTest do
  @moduledoc """
  Progress and log notifications reach the client's handler on every
  transport, not only on modern HTTP request streams.
  """

  use ExUnit.Case, async: false

  alias ExMCP.Client
  alias ExMCP.Server.HandlerServer

  defmodule ServerHandler do
    @moduledoc false
    use ExMCP.Server.Handler

    @impl true
    def init(opts), do: {:ok, %{test_pid: Keyword.get(opts, :test_pid)}}

    @impl true
    def handle_initialize(_params, state) do
      {:ok,
       %{
         protocolVersion: "2025-06-18",
         serverInfo: %{name: "notifications", version: "0"},
         capabilities: %{tools: %{}, logging: %{}}
       }, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{name: "work", inputSchema: %{type: "object"}},
        %{name: "wait", inputSchema: %{type: "object"}},
        %{name: "log", inputSchema: %{type: "object"}}
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("work", args, state) do
      token = get_in(args, ["_meta", "progressToken"])

      if client = Process.whereis(:test_notifications_client) do
        send(
          client,
          {:transport_message,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "method" => "notifications/progress",
             "params" => %{"progressToken" => token, "progress" => 1, "total" => 2}
           })}
        )
      end

      {:ok, %{content: [%{type: "text", text: "done"}]}, state}
    end

    def handle_call_tool("wait", _args, state) do
      send(state.test_pid, {:tool_waiting, self()})
      receive do: (:release -> :ok)
      {:ok, %{content: [%{type: "text", text: "released"}]}, state}
    end

    def handle_call_tool("log", _args, state) do
      if client = Process.whereis(:test_notifications_client) do
        send(
          client,
          {:transport_message,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "method" => "notifications/message",
             "params" => %{"level" => "info", "data" => %{"message" => "routine"}}
           })}
        )

        send(
          client,
          {:transport_message,
           Jason.encode!(%{
             "jsonrpc" => "2.0",
             "method" => "notifications/message",
             "params" => %{"level" => "error", "data" => %{"message" => "serious"}}
           })}
        )
      end

      {:ok, %{content: [%{type: "text", text: "logged"}]}, state}
    end
  end

  defmodule ClientHandler do
    @moduledoc false
    @behaviour ExMCP.Client.Handler

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test_pid)}

    @impl true
    def handle_progress(request_id, params, test_pid) do
      send(test_pid, {:client_progress, request_id, params})
      {:ok, test_pid}
    end

    @impl true
    def handle_log_message(request_id, params, test_pid) do
      send(test_pid, {:client_log, request_id, params})
      {:ok, test_pid}
    end

    @impl true
    def handle_ping(state), do: {:ok, %{}, state}

    @impl true
    def handle_list_roots(state), do: {:ok, [], state}

    @impl true
    def handle_create_message(_params, state), do: {:error, "not supported", state}
  end

  setup do
    {:ok, server} =
      HandlerServer.start_link(
        handler: ServerHandler,
        handler_args: [test_pid: self()],
        transport: :test
      )

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: :legacy_only,
        health_check_interval: nil,
        handler: {ClientHandler, [test_pid: self()]}
      )

    if Process.whereis(:test_notifications_client) do
      Process.unregister(:test_notifications_client)
    end

    Process.register(client, :test_notifications_client)

    on_exit(fn ->
      if Process.whereis(:test_notifications_client) do
        Process.unregister(:test_notifications_client)
      end
    end)

    %{client: client}
  end

  test "progress reaches the handler with the id of the request it reports on", %{
    client: client
  } do
    assert {:ok, _} = Client.call_tool(client, "work", %{}, progress_token: "job-1")

    assert_receive {:client_progress, request_id,
                    %{"progressToken" => "job-1", "progress" => 1, "total" => 2}}

    refute is_nil(request_id)
  end

  test "a progress token a pending request carries is refused", %{client: client} do
    first = Task.async(fn -> Client.call_tool(client, "wait", %{}, progress_token: "shared") end)
    assert_receive {:tool_waiting, worker}, 1_000

    # Progress names its request only by token, so sharing it would misroute.
    assert {:error,
            %ExMCP.Error.TransportError{
              reason: :not_sent,
              details: %{cause: :duplicate_progress_token}
            }} = Client.call_tool(client, "work", %{}, progress_token: "shared")

    send(worker, :release)
    assert {:ok, _} = Task.await(first)

    # Free again once the first request settled.
    assert {:ok, _} = Client.call_tool(client, "work", %{}, progress_token: "shared")
  end

  test "connection-level log messages reach the handler without a request id", %{
    client: client
  } do
    assert {:ok, _} = Client.call_tool(client, "log", %{})
    assert_receive {:client_log, nil, %{"level" => "info"}}
    assert_receive {:client_log, nil, %{"level" => "error"}}
  end
end
