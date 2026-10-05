defmodule Arbor.MCP.TestHelpers do
  @moduledoc """
  Helpers for setting up test servers and managing test infrastructure.
  """
  import ExUnit.Callbacks

  @doc """
  Ensures the `Arbor.MCP.TestServer` module is compiled and loaded.

  This function uses `Code.ensure_compiled!/1` to robustly handle the
  compilation and loading of the test server. This is necessary because
  the test server is defined in the `test/support` directory and may not
  be automatically compiled with the rest of the application, especially
  when running individual tests.
  """
  def ensure_test_server_loaded do
    Code.ensure_compiled!(Arbor.MCP.TestServer)
  end

  @doc """
  Stops `pid` on test exit, tolerating a process that is already going away.

  `if Process.alive?(pid), do: GenServer.stop(pid)` looks safe but is not: the
  process can die between the check and the call, and `GenServer.stop/1` then
  exits with that process's own exit reason (commonly `:shutdown` when a linked
  owner is tearing down), failing an otherwise passing test.
  """
  def stop_on_exit(pid) when is_pid(pid) do
    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)
  end

  @doc """
  Starts a test HTTP server on an available port.

  Returns `{:ok, server_pid, port}` or `{:error, reason}`.
  """
  def start_http_server(opts \\ []) do
    # Start ranch if it's not already running
    ensure_ranch_started()

    port = find_available_port(Keyword.get(opts, :preferred_port, 8080))

    server_opts =
      [
        transport: :http,
        port: port,
        host: "localhost",
        # Disable SSE for simpler testing
        legacy_http_sse: false
      ] ++ opts

    ensure_test_server_loaded()

    case Arbor.MCP.TestServer.start_link(server_opts) do
      {:ok, pid} ->
        # No sleep: wait_for_server_ready/1 polls the listener until it accepts.
        :ok = wait_for_server_ready(port)
        {:ok, pid, port}

      {:error, {:transport_error, {:start_server_failed, _reason}}} ->
        # Server failed to start, likely port conflict
        # Try to find another port
        retry_port = find_available_port(port + 1)

        server_opts = Keyword.put(server_opts, :port, retry_port)
        ensure_test_server_loaded()

        case Arbor.MCP.TestServer.start_link(server_opts) do
          {:ok, pid} ->
            :ok = wait_for_server_ready(retry_port)
            {:ok, pid, retry_port}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  Starts a test server with stdio transport.
  """
  def start_stdio_server(opts \\ []) do
    server_opts = [transport: :stdio] ++ opts
    ensure_test_server_loaded()
    Arbor.MCP.TestServer.start_link(server_opts)
  end

  @doc """
  Starts a test server with BEAM transport.
  """
  def start_beam_server(opts \\ []) do
    server_opts = [transport: :beam] ++ opts
    ensure_test_server_loaded()
    Arbor.MCP.TestServer.start_link(server_opts)
  end

  @doc """
  Starts a test server with the given module.
  """
  def start_test_server(server_module, opts \\ []) do
    GenServer.start_link(server_module, opts)
  end

  defmodule ApiTestServer do
    @moduledoc """
    Test server for API integration testing.

    Provides basic tools for testing MCP server functionality
    including echo and arithmetic operations.

    Note: This module may generate compiler warnings about unreachable clauses
    due to the DSL generating comprehensive pattern matches. These warnings are
    benign and can be ignored.
    """
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "api-test-server", version: "1.0.0"

    tool "echo", "Echoes the input message" do
      input_schema(%{
        "type" => "object",
        "properties" => %{"message" => %{"type" => "string"}},
        "required" => ["message"]
      })

      run(fn %{"message" => message}, state when is_binary(message) ->
        {:ok, %{content: [%{type: "text", text: "Echo: #{message}"}]}, state}
      end)
    end

    tool "add", "Adds two numbers" do
      input_schema(%{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number"},
          "b" => %{"type" => "number"}
        },
        "required" => ["a", "b"]
      })

      run(fn %{"a" => a, "b" => b}, state when is_number(a) and is_number(b) ->
        {:ok, %{content: [%{type: "text", text: "#{a} + #{b} = #{a + b}"}]}, state}
      end)
    end

    tool "greet", "Greets someone" do
      input_schema(%{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      })

      run(fn %{"name" => name}, state when is_binary(name) ->
        {:ok, %{content: [%{type: "text", text: "Hello, #{name}!"}]}, state}
      end)
    end

    resource "test://config", "Test configuration resource" do
      title("Test Config")
      mime_type("application/json")

      read(fn _params, state ->
        {:ok, %{text: Jason.encode!(%{test: true, port: 8080})}, state}
      end)
    end

    prompt "test_prompt", "A test prompt for API testing" do
      title("Test Prompt")
      arg(:message, required: true, description: "The message to process")

      render(fn arguments, state ->
        message = Map.get(arguments, "message", "default")

        {:ok,
         %{
           messages: [
             %{
               role: "user",
               content: %{type: "text", text: "Test prompt with message: #{message}"}
             }
           ]
         }, state}
      end)
    end
  end

  @doc """
  Sets up a simple test server with HTTP transport for API integration tests.

  This function is designed to be called from a `setup` block. It handles:
  - Starting the `Arbor.MCP.TestHelpers.ApiTestServer` with the HTTP transport.
  - Tearing down the server process on test exit.
  - Returning a context map with `:http_url` for the test to use.

  This helper is suitable for tests that only need to verify basic HTTP API
  interactions.

  **NOTE:** Tests using this helper should be marked with `async: false`.

  ## Example

      defmodule MyApiTest do
        use ExUnit.Case, async: false
        import Arbor.MCP.TestHelpers

        setup context do
          # The context from setup is passed to the helper
          start_test_servers_for_api(context)
        end

        test "communicates with the server", %{http_url: http_url} do
          # use http_url to connect to the server
        end
      end
  """
  def start_test_servers_for_api(context) do
    ensure_ranch_started()
    ensure_session_manager_started()

    {server_name, ranch_ref, port} = generate_server_config(context)
    server_opts = build_server_opts(server_name, ranch_ref, port)

    start_server_with_retries(server_opts, server_name, ranch_ref, port)
  end

  # Extract server configuration generation
  defp generate_server_config(context) do
    test_name = Map.get(context, :test, :default_test)
    unique_id = System.unique_integer([:positive])
    server_name = :"ApiTestServer_#{test_name}_#{unique_id}"
    ranch_ref = :"ranch_listener_#{test_name}_#{unique_id}"

    base_port = 8080 + :rand.uniform(5000)
    port = find_available_port(base_port)

    {server_name, ranch_ref, port}
  end

  # Extract server options building
  defp build_server_opts(server_name, ranch_ref, port) do
    [
      transport: :http,
      port: port,
      legacy_http_sse: false,
      name: server_name,
      ranch_ref: ranch_ref
    ]
  end

  # Main server starting logic with retries
  defp start_server_with_retries(server_opts, server_name, ranch_ref, port) do
    case ApiTestServer.start_link(server_opts) do
      {:ok, _pid} ->
        handle_successful_start(server_name, ranch_ref, port)

      {:error, {:already_started, _}} ->
        handle_already_started_error(server_opts, server_name, port)

      {:error, reason} when reason in [:eaddrinuse, :eacces, :enotfound] ->
        handle_port_binding_error(server_name, port)

      {:error, {:transport_error, {:start_server_failed, _reason}}} ->
        # Pass through transport errors
        raise "Failed to start test HTTP server due to transport error"

      {:error, reason} ->
        raise "Failed to start test HTTP server: #{inspect(reason)}"
    end
  end

  # Handle successful server start
  defp handle_successful_start(server_name, ranch_ref, port) do
    # ensure_server_ready/1 polls the listening socket; no fixed sleep needed.
    ensure_server_ready(port)
    register_cleanup(server_name, ranch_ref)
    %{http_url: "http://localhost:#{port}"}
  end

  # Handle already started error by retrying with different ranch ref
  defp handle_already_started_error(server_opts, server_name, port) do
    test_name = server_opts[:name]
    unique_id = System.unique_integer([:positive])
    retry_ranch_ref = :"ranch_listener_retry_#{test_name}_#{unique_id}"
    retry_opts = Keyword.put(server_opts, :ranch_ref, retry_ranch_ref)

    case ApiTestServer.start_link(retry_opts) do
      {:ok, _pid} ->
        ensure_server_ready(port)
        register_cleanup(server_name, retry_ranch_ref)
        %{http_url: "http://localhost:#{port}"}

      {:error, reason} ->
        raise "Failed to restart test HTTP server: #{inspect(reason)}"
    end
  end

  # Handle port binding errors by trying a different port
  defp handle_port_binding_error(_server_name, original_port) do
    retry_port = find_available_port(original_port + 1)
    server_opts = [transport: :http, port: retry_port, legacy_http_sse: false]

    case ApiTestServer.start_link(server_opts) do
      {:ok, pid} ->
        ensure_server_ready(retry_port)
        register_simple_cleanup(pid)
        %{http_url: "http://localhost:#{retry_port}"}

      {:error, reason} ->
        raise "Failed to start test HTTP server on retry: #{inspect(reason)}"
    end
  end

  # Ensure server is ready or raise error
  defp ensure_server_ready(port) do
    case wait_for_server_ready(port, 100) do
      :ok -> :ok
      {:error, reason} -> raise "Server not ready: #{inspect(reason)}"
    end
  end

  # Register cleanup for server and ranch listener.
  # `:ranch.stop_listener/1` and `GenServer.stop/3` are both synchronous, so
  # once they return the port is released — no settling sleep required.
  defp register_cleanup(server_name, ranch_ref) do
    on_exit(fn ->
      cleanup_ranch_listener(ranch_ref)
      safe_stop_process(server_name)
    end)
  end

  # Register simple cleanup for just the process
  defp register_simple_cleanup(pid) do
    on_exit(fn ->
      ref = Process.monitor(pid)
      safe_stop_process(pid, :shutdown, 500)

      # Guarantees the process is gone before the next test binds the port.
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  # Extract ranch cleanup logic
  defp cleanup_ranch_listener(ranch_ref) do
    :ranch.stop_listener(ranch_ref)
  catch
    :exit, _ -> :ok
  end

  # Private helpers

  defp ensure_ranch_started do
    case Application.ensure_all_started(:ranch) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp ensure_session_manager_started do
    # Check if SessionManager is already running
    case GenServer.whereis(Arbor.MCP.SessionManager) do
      nil ->
        # Start SessionManager if not running
        case Arbor.MCP.SessionManager.start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "Failed to start SessionManager: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp find_available_port(preferred_port, max_attempts \\ 100) do
    case :gen_tcp.listen(preferred_port, []) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        preferred_port

      {:error, :eaddrinuse} when max_attempts > 0 ->
        find_available_port(preferred_port + 1, max_attempts - 1)

      {:error, _} ->
        # Fallback or raise error if we can't find any port
        if max_attempts > 0 do
          find_available_port(preferred_port + 1, max_attempts - 1)
        else
          raise "Could not find available port after 100 attempts starting from #{preferred_port - 100}"
        end
    end
  end

  defp wait_for_server_ready(port, attempts \\ 50) do
    case :gen_tcp.connect(~c"localhost", port, []) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, :econnrefused} when attempts > 0 ->
        # Intentional bounded poll: there is no event to subscribe to for
        # "the OS accepted a bind", so we retry the connect until it succeeds.
        Process.sleep(50)
        wait_for_server_ready(port, attempts - 1)

      {:error, reason} ->
        {:error, {:server_not_ready, reason}}
    end
  end

  @doc """
  Generates a unique atom name for a process in a test.

  The generated name includes the test name and a monotonic unique integer so
  named processes do not collide across cases.
  """
  @spec unique_process_name(atom(), String.t()) :: atom()
  def unique_process_name(test, prefix) when is_atom(test) and is_binary(prefix) do
    unique_id = :erlang.unique_integer([:positive])

    test_name =
      test
      |> Atom.to_string()
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")

    "Arbor.MCP.Test.#{String.capitalize(prefix)}.#{test_name}_#{unique_id}"
    |> String.to_atom()
  end

  @doc """
  Safely stops a GenServer process, ignoring if it's already dead.

  This is a robust alternative to `GenServer.stop/1` for test teardown
  that handles race conditions where processes might die before cleanup.
  """
  def safe_stop_process(pid_or_name, reason \\ :normal, timeout \\ 5000)
      when is_pid(pid_or_name) or is_atom(pid_or_name) do
    # For atoms, we need to check if the process exists first
    should_stop =
      case pid_or_name do
        pid when is_pid(pid) -> Process.alive?(pid)
        name when is_atom(name) -> Process.whereis(name) != nil
      end

    if should_stop do
      GenServer.stop(pid_or_name, reason, timeout)
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:shutdown, _} -> :ok
    :exit, _ -> :ok
  end

  @doc """
  Wait until a condition is true, polling at short intervals.

  Replaces `Process.sleep(N)` patterns with deterministic condition checks.
  Returns `:ok` when the condition returns a truthy value, or raises after timeout.

  ## Examples

      # Wait for a process to be registered
      wait_until(fn -> Process.whereis(:my_server) end)

      # Wait for GenServer state to change
      wait_until(fn -> GenServer.call(pid, :get_status) == :ready end, timeout: 1000)

      # Wait for a message (prefer assert_receive instead)
      wait_until(fn -> match?({:ok, _}, result) end)
  """
  @spec wait_until((-> boolean() | any()), keyword()) :: :ok
  def wait_until(condition, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until(condition, interval, deadline)
  end

  defp do_wait_until(condition, interval, deadline) do
    if condition.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise ExUnit.AssertionError,
          message: "wait_until timed out after condition was not met"
      end

      # Intentional: this IS the polling primitive. Prefer assert_receive or
      # assert_event/2 when the code under test emits a message or telemetry.
      Process.sleep(interval)
      do_wait_until(condition, interval, deadline)
    end
  end

  @doc """
  Start a named GenServer, handling the case where it's already running.

  Returns the pid regardless of whether it was freshly started or already running.
  Registers an on_exit callback to stop the server after the test.

  ## Examples

      pid = start_server!(MyServer)
      pid = start_server!(MyServer, [arg1, arg2])
  """
  @spec start_server!(module(), list()) :: pid()
  def start_server!(module, args \\ []) do
    pid =
      case module.start_link(args) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    ExUnit.Callbacks.on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  @doc """
  Wait for a specific telemetry event (truly event-driven, no polling).

  Attaches a telemetry handler that forwards matching events to the test
  process, then blocks on `receive` until the event arrives or timeout.

  ## Examples

      # Wait for client connection
      {:ok, metadata} = wait_for_event([:arbor_mcp, :client, :connected])

      # Wait for tool execution with timeout
      {:ok, metadata} = wait_for_event([:arbor_mcp, :server, :tool, :called], timeout: 5000)

      # Wait and check metadata
      {:ok, %{tool_name: "echo"}} = wait_for_event([:arbor_mcp, :server, :tool, :called])

  ## Notes

  Call this BEFORE triggering the action that emits the event.
  The handler is automatically detached after receiving or timeout.
  """
  @spec wait_for_event([atom()], keyword()) :: {:ok, map()} | {:error, :timeout}
  def wait_for_event(event_name, opts \\ []) do
    test_pid = self()
    handler_id = "test_wait_#{inspect(test_pid)}_#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event_name, measurements, metadata})
      end,
      nil
    )

    timeout = Keyword.get(opts, :timeout, 1000)

    result =
      receive do
        {:telemetry_event, ^event_name, measurements, metadata} ->
          {:ok, Map.merge(measurements, metadata)}
      after
        timeout ->
          {:error, :timeout}
      end

    :telemetry.detach(handler_id)
    result
  end

  @doc """
  Assert that a telemetry event is received within the timeout.

  Like `wait_for_event/2` but raises on timeout (for use in test assertions).

  ## Examples

      # Assert connection event fires
      metadata = assert_event([:arbor_mcp, :transport, :connection, :opened])
      assert metadata.transport == :http

      # Assert with custom timeout
      metadata = assert_event([:arbor_mcp, :server, :tool, :called], timeout: 5000)
      assert metadata.tool_name == "echo"
  """
  @spec assert_event([atom()], keyword()) :: map()
  def assert_event(event_name, opts \\ []) do
    case wait_for_event(event_name, opts) do
      {:ok, metadata} ->
        metadata

      {:error, :timeout} ->
        timeout = Keyword.get(opts, :timeout, 1000)

        raise ExUnit.AssertionError,
          message:
            "Expected telemetry event #{inspect(event_name)} within #{timeout}ms, but none received"
    end
  end

  @doc """
  Refute that a telemetry event is received within the timeout.

  Useful for asserting that an action does NOT trigger a specific event.

  ## Examples

      # Verify no auth flow triggered for non-auth requests
      refute_event([:arbor_mcp, :auth, :flow, :started], timeout: 200)
  """
  @spec refute_event([atom()], keyword()) :: :ok
  def refute_event(event_name, opts \\ []) do
    case wait_for_event(event_name, Keyword.put_new(opts, :timeout, 200)) do
      {:ok, metadata} ->
        raise ExUnit.AssertionError,
          message:
            "Expected no telemetry event #{inspect(event_name)}, but received: #{inspect(metadata)}"

      {:error, :timeout} ->
        :ok
    end
  end
end
