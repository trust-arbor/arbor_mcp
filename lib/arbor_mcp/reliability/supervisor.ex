defmodule Arbor.MCP.Reliability.Supervisor do
  @moduledoc """
  Supervisor for reliability components in ArborMCP.

  Manages circuit breakers, health checks, and provides
  integrated reliability features for MCP clients and servers.

  ## Usage

      # Add to your supervision tree
      children = [
        {Arbor.MCP.Reliability.Supervisor, name: MyApp.Reliability}
      ]

      # Or start manually
      {:ok, sup} = Arbor.MCP.Reliability.Supervisor.start_link()

      # Create reliability-enhanced client
      {:ok, client} = Arbor.MCP.Reliability.Supervisor.create_reliable_client(
        sup,
        transport: :stdio,
        circuit_breaker: [
          failure_threshold: 5,
          reset_timeout: 30_000
        ],
        retry: [
          max_attempts: 3,
          backoff_factor: 2
        ],
        health_check: [
          check_interval: 60_000,
          failure_threshold: 3
        ]
      )
  """

  use Supervisor

  alias Arbor.MCP.Reliability.{HealthCheck, Retry}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    # Create unique names based on a unique identifier
    unique_id = :erlang.unique_integer([:positive])
    supervisor_id = Keyword.get(opts, :name, :"#{__MODULE__}_#{unique_id}")

    children = [
      # Dynamic supervisor for circuit breakers
      {DynamicSupervisor,
       strategy: :one_for_one, name: circuit_breaker_supervisor(supervisor_id)},

      # Dynamic supervisor for health checks
      {DynamicSupervisor, strategy: :one_for_one, name: health_check_supervisor(supervisor_id)},

      # Registry for tracking reliability components
      {Registry, keys: :unique, name: reliability_registry(supervisor_id)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Creates a reliability-enhanced MCP client.

  This wraps a standard MCP client with circuit breaker, retry logic,
  and health monitoring.

  ## Options

  - `:transport` - Transport configuration for the client
  - `:circuit_breaker` - Circuit breaker options (optional)
  - `:retry` - Retry configuration (optional)
  - `:health_check` - Health check configuration (optional)
  - `:max_concurrency` - Maximum concurrently executing requests through the
    wrapper (optional, default: 100)
  """
  @spec create_reliable_client(Supervisor.supervisor(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def create_reliable_client(supervisor \\ __MODULE__, opts) do
    # Verify supervisor is valid
    with :ok <- verify_supervisor(supervisor) do
      client_id = Keyword.get(opts, :id, generate_client_id())
      transport_opts = Keyword.take(opts, [:transport, :transports])

      # Store original trap_exit setting to restore later
      original_trap_exit = Process.flag(:trap_exit, true)

      try do
        result =
          case Arbor.MCP.Client.start_link(transport_opts) do
            {:ok, client_pid} ->
              # Keep trap_exit enabled until after we check for EXIT messages
              case maybe_start_circuit_breaker(supervisor, client_id, opts) do
                {:ok, breaker_pid} ->
                  case maybe_start_health_check(supervisor, client_id, client_pid, opts) do
                    {:ok, health_pid} ->
                      create_wrapper_and_cleanup(
                        supervisor,
                        client_id,
                        client_pid,
                        breaker_pid,
                        health_pid,
                        opts
                      )

                    error ->
                      # health check failed
                      cleanup_pids([client_pid, breaker_pid])
                      error
                  end

                error ->
                  # circuit breaker failed
                  cleanup_pids([client_pid])
                  error
              end

            error ->
              # client failed
              error
          end

        # Handle any EXIT messages from client startup failures
        final_result =
          receive do
            {:EXIT, _pid, {:transport_connect_failed, reason}} ->
              {:error, {:transport_connect_failed, reason}}

            {:EXIT, _pid, {:initialize_error, reason}} ->
              {:error, {:initialize_error, reason}}

            {:EXIT, _pid, reason} ->
              {:error, {:client_start_failed, reason}}
          after
            0 -> result
          end

        final_result
      after
        # Always restore original trap_exit setting, regardless of success or failure
        Process.flag(:trap_exit, original_trap_exit)
      end
    end
  end

  defp verify_supervisor(supervisor) when is_atom(supervisor) do
    case Process.whereis(supervisor) do
      nil -> {:error, {:supervisor_not_found, supervisor}}
      _pid -> :ok
    end
  end

  defp verify_supervisor(supervisor) when is_pid(supervisor) do
    if Process.alive?(supervisor) do
      :ok
    else
      {:error, {:supervisor_not_alive, supervisor}}
    end
  end

  defp create_wrapper_and_cleanup(
         supervisor,
         client_id,
         client_pid,
         breaker_pid,
         health_pid,
         opts
       ) do
    base_wrapper_opts = [
      client: client_pid,
      circuit_breaker: breaker_pid,
      retry_opts: Keyword.get(opts, :retry, []),
      health_check: health_pid
    ]

    wrapper_opts = base_wrapper_opts ++ Keyword.take(opts, [:max_concurrency])

    wrapper_spec = %{
      id: {:reliable_client_wrapper, client_id},
      start: {__MODULE__.ClientWrapper, :start_link, [wrapper_opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(find_circuit_breaker_supervisor(supervisor), wrapper_spec) do
      {:ok, wrapper_pid} ->
        {:ok, wrapper_pid}

      error ->
        # Clean up on wrapper start failure
        cleanup_pids([client_pid, breaker_pid, health_pid])
        error
    end
  end

  defp cleanup_pids(pids) do
    Enum.each(pids, fn pid ->
      if pid && is_pid(pid) do
        GenServer.stop(pid)
      end
    end)
  end

  defp maybe_start_circuit_breaker(supervisor, _client_id, opts) do
    case Keyword.get(opts, :circuit_breaker) do
      nil ->
        {:ok, nil}

      breaker_opts ->
        breaker_opts =
          Keyword.put(
            breaker_opts,
            :name,
            {:via, Registry,
             {find_reliability_registry(supervisor),
              {:circuit_breaker, Keyword.get(opts, :id, generate_client_id())}}}
          )

        spec = %{
          id: {:circuit_breaker, :erlang.unique_integer()},
          start: {Arbor.MCP.Reliability.CircuitBreaker, :start_link, [breaker_opts]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(find_circuit_breaker_supervisor(supervisor), spec) do
          {:ok, pid} -> {:ok, pid}
          error -> error
        end
    end
  end

  defp maybe_start_health_check(supervisor, client_id, target_pid, opts) do
    case Keyword.get(opts, :health_check) do
      nil ->
        {:ok, nil}

      health_opts ->
        health_opts =
          health_opts
          |> Keyword.put(
            :name,
            {:via, Registry, {find_reliability_registry(supervisor), {:health_check, client_id}}}
          )
          |> Keyword.put(:target, target_pid)
          |> Keyword.put_new(:check_fn, HealthCheck.mcp_client_check_fn())

        spec = %{
          id: {:health_check, :erlang.unique_integer()},
          start: {HealthCheck, :start_link, [health_opts]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(find_health_check_supervisor(supervisor), spec) do
          {:ok, pid} -> {:ok, pid}
          error -> error
        end
    end
  end

  @doc false
  def circuit_breaker_supervisor(supervisor_name \\ __MODULE__) do
    Module.concat([supervisor_name, CircuitBreakerSupervisor])
  end

  defp health_check_supervisor(supervisor_name \\ __MODULE__) do
    Module.concat([supervisor_name, HealthCheckSupervisor])
  end

  defp reliability_registry(supervisor_name \\ __MODULE__) do
    Module.concat([supervisor_name, Registry])
  end

  # Helper functions to find child supervisor names from a running supervisor
  @doc false
  def find_circuit_breaker_supervisor(supervisor) do
    children = Supervisor.which_children(supervisor)

    # Look for CircuitBreakerSupervisor by name pattern rather than exact match
    cb_supervisor =
      Enum.find_value(children, fn
        {name, pid, :supervisor, [DynamicSupervisor]} when is_pid(pid) ->
          # Check if the name ends with CircuitBreakerSupervisor
          name_str = Atom.to_string(name)

          if String.ends_with?(name_str, "CircuitBreakerSupervisor") do
            pid
          else
            nil
          end

        _ ->
          nil
      end)

    # Always return a PID - if not found in children, this indicates a problem
    case cb_supervisor do
      pid when is_pid(pid) ->
        pid

      nil ->
        # If we can't find it in children, it means the supervisor structure is wrong
        # This should not happen in a properly initialized supervisor
        raise """
        Could not find circuit breaker supervisor in children of #{inspect(supervisor)}.
        Available children: #{inspect(Enum.map(children, fn {name, _pid, _type, _modules} -> name end))}
        Looking for DynamicSupervisor with name ending in 'CircuitBreakerSupervisor'.

        This indicates the reliability supervisor was not properly initialized.
        """
    end
  catch
    :exit, {:noproc, _} ->
      # Supervisor is not running, return the default
      circuit_breaker_supervisor()
  end

  defp find_health_check_supervisor(supervisor) do
    children = Supervisor.which_children(supervisor)

    # Look for HealthCheckSupervisor by name pattern rather than exact match
    hc_supervisor =
      Enum.find_value(children, fn
        {name, pid, :supervisor, [DynamicSupervisor]} when is_pid(pid) ->
          # Check if the name ends with HealthCheckSupervisor
          name_str = Atom.to_string(name)

          if String.ends_with?(name_str, "HealthCheckSupervisor") do
            pid
          else
            nil
          end

        _ ->
          nil
      end)

    # Only return if found, otherwise fall back to name calculation
    hc_supervisor || get_health_check_supervisor_name(supervisor)
  catch
    :exit, {:noproc, _} ->
      # Supervisor is not running, return the default
      health_check_supervisor()
  end

  defp find_reliability_registry(supervisor) do
    children = Supervisor.which_children(supervisor)

    # Look for Registry by name pattern rather than exact match
    registry =
      Enum.find_value(children, fn
        {name, pid, :worker, [Registry]} when is_pid(pid) ->
          # Check if the name ends with Registry
          name_str = Atom.to_string(name)

          if String.ends_with?(name_str, "Registry") do
            pid
          else
            nil
          end

        _ ->
          nil
      end)

    # Only return if found, otherwise fall back to name calculation
    registry || get_reliability_registry_name(supervisor)
  catch
    :exit, {:noproc, _} ->
      # Supervisor is not running, return the default
      reliability_registry()
  end

  # Helper functions to get the correct child names based on supervisor
  @doc false
  def get_circuit_breaker_supervisor_name(supervisor) when is_pid(supervisor) do
    # Try to get the registered name of the supervisor
    case Process.info(supervisor, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        circuit_breaker_supervisor(name)

      _ ->
        # No registered name, use default
        circuit_breaker_supervisor()
    end
  end

  @doc false
  def get_circuit_breaker_supervisor_name(supervisor) when is_atom(supervisor) do
    circuit_breaker_supervisor(supervisor)
  end

  defp get_health_check_supervisor_name(supervisor) when is_pid(supervisor) do
    # Try to get the registered name of the supervisor
    case Process.info(supervisor, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        health_check_supervisor(name)

      _ ->
        # No registered name, use default
        health_check_supervisor()
    end
  end

  defp get_health_check_supervisor_name(supervisor) when is_atom(supervisor) do
    health_check_supervisor(supervisor)
  end

  defp get_reliability_registry_name(supervisor) when is_pid(supervisor) do
    # Try to get the registered name of the supervisor
    case Process.info(supervisor, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        reliability_registry(name)

      _ ->
        # No registered name, use default
        reliability_registry()
    end
  end

  defp get_reliability_registry_name(supervisor) when is_atom(supervisor) do
    reliability_registry(supervisor)
  end

  defp generate_client_id do
    "client_#{:erlang.unique_integer([:positive])}"
  end
end

defmodule Arbor.MCP.Reliability.Supervisor.ClientWrapper do
  @moduledoc """
  Wrapper process that integrates reliability features for MCP clients.

  This process intercepts calls to the underlying client and applies:
  - Circuit breaker protection
  - Retry logic with exponential backoff
  - Health monitoring integration
  - A bound on concurrently in-flight requests

  ## Options

  - `:client` - the wrapped `Arbor.MCP.Client` pid (required)
  - `:circuit_breaker` - circuit breaker pid, or `nil` to disable
  - `:retry_opts` - retry policy passed to `Arbor.MCP.Reliability.Retry`
  - `:max_concurrency` - maximum requests executing at once (default: 100).
    Calls beyond the limit are rejected with `{:error, :too_many_requests}`
    instead of spawning unbounded work against a struggling server.
  """

  use GenServer

  alias Arbor.MCP.Reliability.CircuitBreaker
  alias Arbor.MCP.Reliability.Retry

  @default_max_concurrency 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      circuit_breaker: Keyword.get(opts, :circuit_breaker),
      retry_opts: Keyword.get(opts, :retry_opts, []),
      health_check: Keyword.get(opts, :health_check),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      # in-flight request tasks: monitor ref => caller
      pending: %{}
    }

    # Monitor the underlying client
    Process.monitor(state.client)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:call_tool, tool_name, args, opts}, from, state) do
    execute_with_reliability(
      fn -> Arbor.MCP.Client.call_tool(state.client, tool_name, args, opts) end,
      from,
      state
    )
  end

  def handle_call({:list_tools, opts}, from, state) do
    execute_with_reliability(
      fn -> Arbor.MCP.Client.list_tools(state.client, opts) end,
      from,
      state
    )
  end

  def handle_call({:list_resources, opts}, from, state) do
    execute_with_reliability(
      fn -> Arbor.MCP.Client.list_resources(state.client, opts) end,
      from,
      state
    )
  end

  def handle_call({:read_resource, uri, opts}, from, state) do
    execute_with_reliability(
      fn -> Arbor.MCP.Client.read_resource(state.client, uri, opts) end,
      from,
      state
    )
  end

  def handle_call({:list_prompts, opts}, from, state) do
    execute_with_reliability(
      fn -> Arbor.MCP.Client.list_prompts(state.client, opts) end,
      from,
      state
    )
  end

  def handle_call({:get_prompt, name, args, opts}, from, state) do
    execute_with_reliability(
      fn -> Arbor.MCP.Client.get_prompt(state.client, name, args, opts) end,
      from,
      state
    )
  end

  # Forward other calls directly
  def handle_call(request, from, state) do
    execute_with_reliability(
      fn -> GenServer.call(state.client, request) end,
      from,
      state
    )
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{client: pid} = state) do
    # Client process died
    {:stop, {:client_died, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending, ref) do
      {nil, _pending} ->
        {:noreply, state}

      {from, pending} ->
        # The request task died before replying; make sure the caller is not
        # left hanging until its call timeout.
        if reason != :normal do
          GenServer.reply(from, {:error, {:request_task_exit, reason}})
        end

        {:noreply, %{state | pending: pending}}
    end
  end

  # Runs the request in an unlinked, monitored process, applying retry and —
  # when configured — the circuit breaker, so the wrapper survives request
  # crashes and callers always get a reply. Concurrency is capped so a
  # struggling server cannot be met with an unbounded fan-out of retrying
  # processes.
  defp execute_with_reliability(fun, from, state) do
    if map_size(state.pending) >= state.max_concurrency do
      {:reply, {:error, :too_many_requests}, state}
    else
      spawn_request(fun, from, state)
    end
  end

  defp spawn_request(fun, from, state) do
    breaker = state.circuit_breaker
    retry_opts = Retry.mcp_defaults(state.retry_opts)

    {_pid, ref} =
      spawn_monitor(fn ->
        wrapped = fn -> Retry.with_retry(fun, retry_opts) end

        result =
          if breaker do
            CircuitBreaker.call(breaker, wrapped, :infinity)
          else
            wrapped.()
          end

        GenServer.reply(from, result)
      end)

    {:noreply, %{state | pending: Map.put(state.pending, ref, from)}}
  end
end

defmodule Arbor.MCP.Reliability do
  @moduledoc """
  Convenience functions for reliability features.

  This module provides easy access to reliability patterns
  without manual setup.

  ## Examples

      # Wrap a function with retry logic
      Arbor.MCP.Reliability.with_retry(fn ->
        Arbor.MCP.Client.call_tool(client, "risky_tool", %{})
      end)

      # Create a circuit-breaker protected function
      protected_call = Arbor.MCP.Reliability.protect(fn ->
        external_service_call()
      end, failure_threshold: 5)

      # Use the protected function
      protected_call.()
  """

  alias Arbor.MCP.Reliability.Retry

  defdelegate with_retry(fun, opts \\ []), to: Retry

  # Helper functions for protect/2 to reduce cyclomatic complexity

  defp find_or_create_circuit_breaker_supervisor do
    case Process.whereis(Arbor.MCP.Reliability.Supervisor) do
      nil ->
        create_temporary_supervisor()

      sup_pid ->
        Arbor.MCP.Reliability.Supervisor.find_circuit_breaker_supervisor(sup_pid)
    end
  end

  defp create_temporary_supervisor do
    temp_name = :"#{__MODULE__}_#{System.unique_integer([:positive])}_temp"
    {:ok, temp_sup} = Arbor.MCP.Reliability.Supervisor.start_link(name: temp_name)
    # Give it time to start children
    Process.sleep(150)

    find_circuit_breaker_from_temp_supervisor(temp_sup, temp_name)
  end

  defp find_circuit_breaker_from_temp_supervisor(temp_sup, temp_name) do
    children = Supervisor.which_children(temp_sup)
    expected_name = Arbor.MCP.Reliability.Supervisor.get_circuit_breaker_supervisor_name(temp_sup)

    case find_circuit_breaker_pid_from_children(children, expected_name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        fallback_circuit_breaker_lookup(expected_name, temp_name)
    end
  end

  defp find_circuit_breaker_pid_from_children(children, expected_name) do
    Enum.find_value(children, fn
      {^expected_name, pid, :supervisor, [DynamicSupervisor]} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp fallback_circuit_breaker_lookup(expected_name, temp_name) do
    case Process.whereis(expected_name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        # Last resort: return the expected name (this will likely fail but is better than crashing)
        Arbor.MCP.Reliability.Supervisor.circuit_breaker_supervisor(temp_name)
    end
  end

  defp get_or_create_circuit_breaker(cb_supervisor, cb_opts) do
    case cb_opts[:name] do
      nil ->
        create_anonymous_circuit_breaker(cb_supervisor, cb_opts)

      name ->
        get_or_create_named_circuit_breaker(cb_supervisor, cb_opts, name)
    end
  end

  defp create_anonymous_circuit_breaker(cb_supervisor, cb_opts) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        cb_supervisor,
        {Arbor.MCP.Reliability.CircuitBreaker, cb_opts}
      )

    pid
  end

  defp get_or_create_named_circuit_breaker(cb_supervisor, cb_opts, name) do
    case Process.whereis(name) do
      nil ->
        start_named_circuit_breaker(cb_supervisor, cb_opts, name)

      pid ->
        pid
    end
  end

  defp start_named_circuit_breaker(cb_supervisor, cb_opts, name) do
    case DynamicSupervisor.start_child(
           cb_supervisor,
           {Arbor.MCP.Reliability.CircuitBreaker, Keyword.put(cb_opts, :name, name)}
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp create_protected_function(fun, breaker_pid, cb_opts, retry_opts) do
    fn args ->
      cb_timeout = Keyword.get(cb_opts, :timeout, 5000)

      # Execute through circuit breaker
      case Arbor.MCP.Reliability.CircuitBreaker.call(
             breaker_pid,
             fn -> execute_with_retry(fun, args, retry_opts) end,
             cb_timeout
           ) do
        {:error, :circuit_open} = error ->
          error

        other ->
          other
      end
    end
  end

  @doc """
  Creates a circuit breaker and retry-protected version of a function.

  The function will be protected by a circuit breaker and retried
  according to the specified options on failure.

  ## Options

  - `:name` - Name for the circuit breaker process
  - `:failure_threshold` - Number of failures before circuit opens (default: 5)
  - `:success_threshold` - Number of successes to close circuit (default: 2)
  - `:timeout` - Timeout for each call (default: 5000)
  - `:reset_timeout` - Time before attempting to close open circuit (default: 30000)
  - Plus all retry options from `Arbor.MCP.Reliability.Retry.mcp_defaults/1`
  """
  @spec protect(function(), keyword()) :: function()
  def protect(fun, opts \\ []) when is_function(fun) do
    # Extract circuit breaker specific options
    {cb_opts, retry_opts} =
      Keyword.split(opts, [
        :name,
        :failure_threshold,
        :success_threshold,
        :timeout,
        :reset_timeout
      ])

    # Find or create circuit breaker supervisor
    cb_supervisor = find_or_create_circuit_breaker_supervisor()

    # Create or get circuit breaker
    breaker_pid = get_or_create_circuit_breaker(cb_supervisor, cb_opts)

    # Return a function that uses both circuit breaker and retry
    create_protected_function(fun, breaker_pid, cb_opts, retry_opts)
  end

  defp execute_with_retry(fun, args, retry_opts) do
    Retry.with_retry(
      fn ->
        # Determine function arity and call appropriately
        case :erlang.fun_info(fun)[:arity] do
          0 -> fun.()
          1 when is_list(args) and length(args) == 1 -> fun.(hd(args))
          # If args is not a list, pass it directly
          1 -> fun.(args)
          _ when is_list(args) -> apply(fun, args)
          # Fallback
          _ -> fun.(args)
        end
      end,
      Retry.mcp_defaults(retry_opts)
    )
  end
end
