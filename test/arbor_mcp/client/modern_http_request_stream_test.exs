defmodule Arbor.MCP.Client.ModernHTTPRequestStreamTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Server.{Context, Runtime}

  defmodule ServerHandler do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:request_stream_handler_initialized, self()})

      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         attempts: Keyword.fetch!(opts, :attempts)
       }}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      tools = [
        %{
          name: "streaming",
          description: "Emits request-scoped events",
          inputSchema: %{"type" => "object"}
        },
        %{
          name: "blocking",
          description: "Waits until its request stream is cancelled",
          inputSchema: %{"type" => "object"}
        },
        %{
          name: "logging",
          description: "Attempts a request-scoped log message",
          inputSchema: %{"type" => "object"}
        },
        %{
          name: "flaky",
          description: "Breaks its first response stream",
          inputSchema: %{"type" => "object"}
        }
      ]

      {:ok, tools, nil, state}
    end

    @impl true
    def handle_call_tool("streaming", _arguments, state) do
      send(state.test_pid, {:server_handler_started, self()})

      :ok = Context.report_progress(25, 100, "quarter")
      :ok = Context.send_log_message(:info, "still working", %{"step" => 1})
      :ok = Context.report_progress(100, 100, "complete")

      {:ok, %{content: [%{type: "text", text: "done"}]}, state}
    end

    def handle_call_tool("blocking", _arguments, state) do
      send(state.test_pid, {:server_handler_started, self()})

      receive do
        :release -> {:ok, %{content: [%{type: "text", text: "released"}]}, state}
      end
    end

    def handle_call_tool("logging", _arguments, state) do
      result = Context.send_log_message(:info, "requested log")
      send(state.test_pid, {:server_log_result, result})
      {:ok, %{content: [%{type: "text", text: "done"}]}, state}
    end

    def handle_call_tool("flaky", arguments, state) do
      token = Context.progress_token()

      attempt =
        Agent.get_and_update(state.attempts, fn attempts ->
          next = Map.get(attempts, token, 0) + 1
          {next, Map.put(attempts, token, next)}
        end)

      context = Context.current()
      send(state.test_pid, {:flaky_attempt, token, attempt, context.request_id, arguments})

      if attempt == 1 do
        :ok = Context.report_progress(1, 2, "first attempt")
        Process.exit(Map.fetch!(context.application_context, :socket), :kill)
        Process.sleep(:infinity)
      else
        {:ok, %{content: [%{type: "text", text: "retried"}]}, state}
      end
    end
  end

  defmodule ClientHandler do
    @behaviour Arbor.MCP.Client.Handler

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
    port = free_port()
    ranch_ref = {:modern_http_request_stream_test, System.unique_integer([:positive])}
    attempts = start_supervised!({Agent, fn -> %{} end})

    runtime =
      start_supervised!(
        {Runtime,
         handler: ServerHandler,
         handler_args: [test_pid: self(), attempts: attempts],
         transport: :mounted_http}
      )

    assert_receive {:request_stream_handler_initialized, _scheduler}, 1_000

    {:ok, _pid} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [
          runtime: runtime,
          handler_opts: fn _conn -> %{socket: self()} end,
          path: "/mcp",
          protocol_mode: :modern_only,
          allowed_origins: ["http://127.0.0.1:#{port}"]
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ranch_ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ranch_ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        protocol_mode: :modern_only,
        protocol_version: "2026-07-28",
        use_sse: false,
        health_check_interval: nil,
        stream_idle_timeout: 2_000,
        handler: {ClientHandler, [test_pid: self()]}
      )

    on_exit(fn ->
      if Process.alive?(client) do
        try do
          Client.disconnect(client)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, client: client, attempts: attempts}
  end

  test "delivers only related notifications before the final response", %{client: client} do
    task =
      Task.async(fn ->
        Client.call_tool(client, "streaming", %{},
          progress_token: "request-stream-1",
          meta: %{"io.modelcontextprotocol/logLevel" => "debug"},
          timeout: 2_000,
          format: :map
        )
      end)

    assert_receive {:server_handler_started, handler_pid}, 1_000
    assert is_pid(handler_pid)

    assert_receive {:client_progress, request_id,
                    %{
                      "progressToken" => "request-stream-1",
                      "progress" => 25,
                      "total" => 100,
                      "message" => "quarter"
                    }},
                   1_000

    assert is_integer(request_id)

    assert_receive {:client_log, ^request_id,
                    %{
                      "level" => "info",
                      "data" => %{"step" => 1, "message" => "still working"}
                    } = log_params},
                   1_000

    refute Map.has_key?(log_params, "_meta")

    assert_receive {:client_progress, ^request_id,
                    %{
                      "progressToken" => "request-stream-1",
                      "progress" => 100,
                      "total" => 100,
                      "message" => "complete"
                    }},
                   1_000

    assert {:ok, %{"content" => [%{"text" => "done", "type" => "text"}]}} =
             Task.await(task, 2_000)

    refute_receive {:client_progress, _request_id, _params}, 50
    refute_receive {:client_log, _request_id, _params}, 50
  end

  test "closing one request stream cancels its Runtime callback task", %{client: client} do
    task =
      Task.async(fn ->
        Client.call_tool(client, "blocking", %{},
          progress_token: "request-stream-cancel",
          timeout: 5_000,
          format: :map
        )
      end)

    assert_receive {:server_handler_started, handler_pid}, 1_000
    handler_ref = Process.monitor(handler_pid)

    assert [request_id] = Client.get_pending_requests(client)
    assert :ok = Client.send_cancelled(client, request_id, "test cancellation")
    assert {:error, :cancelled} = Task.await(task, 1_000)
    assert_receive {:DOWN, ^handler_ref, :process, ^handler_pid, _reason}, 2_000

    assert [] = Client.get_pending_requests(client)
  end

  test "log delivery requires per-request opt-in and honors the minimum level", %{client: client} do
    assert {:ok, _result} =
             Client.call_tool(client, "logging", %{},
               progress_token: "no-log-opt-in",
               timeout: 2_000,
               format: :map
             )

    assert_receive {:server_log_result, {:error, :logging_not_requested}}, 1_000
    refute_receive {:client_log, _request_id, _params}, 50

    assert {:ok, _result} =
             Client.call_tool(client, "logging", %{},
               meta: %{"io.modelcontextprotocol/logLevel" => "error"},
               timeout: 2_000,
               format: :map
             )

    assert_receive {:server_log_result, :ok}, 1_000
    refute_receive {:client_log, _request_id, _params}, 50

    task =
      Task.async(fn ->
        Client.call_tool(client, "logging", %{},
          meta: %{"io.modelcontextprotocol/logLevel" => "debug"},
          timeout: 2_000,
          format: :map
        )
      end)

    assert_receive {:client_log, request_id,
                    %{
                      "level" => "info",
                      "data" => "requested log"
                    }},
                   1_000

    assert is_integer(request_id)

    assert_receive {:server_log_result, :ok}, 1_000
    assert {:ok, _result} = Task.await(task, 2_000)
  end

  test "an ambiguous broken stream retries once with a new JSON-RPC id", %{client: client} do
    task =
      Task.async(fn ->
        Client.call_tool(client, "flaky", %{"value" => 7},
          progress_token: "retry-default",
          timeout: 3_000,
          http_stream_retry_delay: 0,
          format: :map
        )
      end)

    assert_receive {:flaky_attempt, "retry-default", 1, first_id, first_arguments}, 1_000
    assert_receive {:client_progress, ^first_id, %{"progress" => 1}}, 1_000
    assert_receive {:flaky_attempt, "retry-default", 2, second_id, second_arguments}, 2_000

    assert first_id != second_id
    assert first_arguments == second_arguments

    assert {:ok, %{"content" => [%{"text" => "retried"}]}} = Task.await(task, 2_000)
  end

  test "safe-only does not reissue an unattested tool after an ambiguous break", %{client: client} do
    assert {:error, %Arbor.MCP.Error.TransportError{reason: :outcome_unknown}} =
             Client.call_tool(client, "flaky", %{},
               progress_token: "retry-safe-only",
               timeout: 2_000,
               http_stream_retry: :safe_only,
               format: :map
             )

    assert_receive {:flaky_attempt, "retry-safe-only", 1, _request_id, _arguments}, 1_000
    refute_receive {:flaky_attempt, "retry-safe-only", 2, _request_id, _arguments}, 100
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
