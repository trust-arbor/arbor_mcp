defmodule Arbor.MCP.Reliability.Retry do
  @moduledoc """
  Retry logic with exponential backoff for MCP operations.

  Provides configurable retry strategies to handle transient failures
  in distributed systems. Supports exponential backoff with jitter
  to prevent thundering herd problems.

  ## Usage

      # Simple retry with defaults
      Retry.with_retry(fn ->
        Arbor.MCP.Client.call_tool(client, "tool", %{})
      end)

      # Custom configuration
      Retry.with_retry(
        fn -> risky_operation() end,
        max_attempts: 5,
        initial_delay: 100,
        max_delay: 10_000,
        backoff_factor: 2,
        jitter: true
      )

      # With custom retry condition
      Retry.with_retry(
        fn -> http_request() end,
        should_retry?: fn
          {:error, %{status: status}} when status in 500..599 -> true
          {:error, :timeout} -> true
          _ -> false
        end
      )

  ## Strategies

  - **Exponential backoff**: Delay increases exponentially with each attempt
  - **Jitter**: Random variation to prevent synchronized retries
  - **Circuit breaker integration**: Can be combined with circuit breakers
  """

  require Logger

  @default_max_attempts 3
  @default_initial_delay 100
  @default_max_delay 5000
  @default_backoff_factor 2

  @type retry_opts :: [
          max_attempts: pos_integer(),
          initial_delay: pos_integer(),
          max_delay: pos_integer(),
          backoff_factor: number(),
          jitter: boolean(),
          should_retry?: (any() -> boolean()),
          on_retry: (pos_integer(), any() -> any())
        ]

  @doc """
  Executes a function with retry logic.

  ## Options

  - `:max_attempts` - Maximum number of attempts (default: 3)
  - `:initial_delay` - Initial delay in ms (default: 100)
  - `:max_delay` - Maximum delay in ms (default: 5000)
  - `:backoff_factor` - Multiplier for exponential backoff (default: 2)
  - `:jitter` - Add randomization to delays (default: true)
  - `:should_retry?` - Function to determine if retry should occur (default: retry on any error)
  - `:on_retry` - Callback function called before each retry with (attempt, error)

  ## Returns

  - `{:ok, result}` if operation succeeds
  - `{:error, reason}` if all retries are exhausted, where `reason` is the
    last underlying error unchanged — callers see the same error shape with
    or without a retry policy

  ## Exceptions

  Only transport-level exceptions (`Arbor.MCP.Error.TransportError`) are treated
  as retryable errors. All other exceptions are re-raised so bugs are not
  silently converted into retry loops. Exits (e.g. from `GenServer.call/3`)
  and throws are caught and treated as `{:error, {:exit, reason}}` /
  `{:error, {:throw, value}}`.
  """
  @spec with_retry(function(), retry_opts()) :: {:ok, any()} | {:error, any()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    config = build_config(opts)
    execute_with_retry(fun, 1, nil, config)
  end

  @doc """
  Executes a function with linear retry (fixed delay).

  ## Options

  - `:max_attempts` - Maximum number of attempts (default: 3)
  - `:delay` - Fixed delay between attempts in ms (default: 1000)
  - `:should_retry?` - Function to determine if retry should occur
  - `:on_retry` - Callback function called before each retry
  """
  @spec with_linear_retry(function(), keyword()) :: {:ok, any()} | {:error, any()}
  def with_linear_retry(fun, opts \\ []) when is_function(fun, 0) do
    delay = Keyword.get(opts, :delay, 1000)

    opts =
      Keyword.merge(opts,
        initial_delay: delay,
        max_delay: delay,
        backoff_factor: 1,
        jitter: false
      )

    with_retry(fun, opts)
  end

  @doc """
  Creates a retry-wrapped version of a function.

  Useful for wrapping functions that should always be retried.

  ## Example

      retryable_call = Retry.wrap(fn -> unstable_api_call() end, max_attempts: 5)

      # Later...
      result = retryable_call.()
  """
  @spec wrap(function(), retry_opts()) :: function()
  def wrap(fun, opts \\ []) when is_function(fun, 0) do
    fn -> with_retry(fun, opts) end
  end

  @doc """
  Executes multiple operations with retry, stopping on first success.

  Useful for fallback scenarios where you have multiple ways to achieve
  the same result.

  ## Example

      Retry.with_fallback([
        fn -> primary_service_call() end,
        fn -> secondary_service_call() end,
        fn -> fallback_local_data() end
      ])
  """
  @spec with_fallback([function()], retry_opts()) :: {:ok, any()} | {:error, :all_failed}
  def with_fallback(functions, opts \\ []) when is_list(functions) do
    Enum.reduce_while(functions, {:error, :all_failed}, fn fun, _acc ->
      case with_retry(fun, opts) do
        {:ok, result} -> {:halt, {:ok, result}}
        {:error, _} -> {:cont, {:error, :all_failed}}
      end
    end)
  end

  @doc """
  Calculates the delay for a given attempt using exponential backoff.

  Useful for custom retry implementations.
  """
  @spec calculate_delay(pos_integer(), keyword()) :: pos_integer()
  def calculate_delay(attempt, opts \\ []) do
    initial_delay = Keyword.get(opts, :initial_delay, @default_initial_delay)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)
    backoff_factor = Keyword.get(opts, :backoff_factor, @default_backoff_factor)
    jitter = Keyword.get(opts, :jitter, true)

    base_delay = initial_delay * :math.pow(backoff_factor, attempt - 1)
    delay = min(round(base_delay), max_delay)

    if jitter do
      add_jitter(delay)
    else
      delay
    end
  end

  ## Private Functions

  defp build_config(opts) do
    %{
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      initial_delay: Keyword.get(opts, :initial_delay, @default_initial_delay),
      max_delay: Keyword.get(opts, :max_delay, @default_max_delay),
      backoff_factor: Keyword.get(opts, :backoff_factor, @default_backoff_factor),
      jitter: Keyword.get(opts, :jitter, true),
      should_retry?: Keyword.get(opts, :should_retry?, &default_should_retry?/1),
      on_retry: Keyword.get(opts, :on_retry, &default_on_retry/2)
    }
  end

  defp execute_with_retry(fun, attempt, last_error, config) do
    if attempt > config.max_attempts do
      Logger.warning("Retry exhausted after #{config.max_attempts} attempts")
      # Return the last underlying error unchanged so callers see the same
      # error shape with or without a retry policy.
      {:error, last_error}
    else
      case execute_function(fun) do
        {:ok, _result} = success ->
          if attempt > 1 do
            Logger.info("Operation succeeded after #{attempt} attempts")
          end

          success

        {:error, reason} = error ->
          if config.should_retry?.(reason) and attempt < config.max_attempts do
            delay = calculate_delay(attempt, Map.to_list(config))

            Logger.debug("Attempt #{attempt} failed: #{inspect(reason)}, retrying in #{delay}ms")
            config.on_retry.(attempt, reason)

            Process.sleep(delay)
            execute_with_retry(fun, attempt + 1, reason, config)
          else
            if attempt >= config.max_attempts do
              Logger.warning("Retry exhausted after #{attempt} attempts: #{inspect(reason)}")
            else
              Logger.debug("Error not retryable: #{inspect(reason)}")
            end

            error
          end

        other ->
          # Handle non-standard returns
          Logger.warning("Unexpected return value: #{inspect(other)}")
          {:error, {:unexpected_return, other}}
      end
    end
  end

  # Only exceptions that signal a (potentially transient) transport problem
  # are converted into retryable errors; everything else is a bug and is
  # re-raised. Exits (dead/unresponsive processes) and throws are still
  # captured as error tuples.
  defp execute_function(fun) do
    fun.()
  rescue
    e in [Arbor.MCP.Error.TransportError] ->
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  defp default_should_retry?(_error), do: true

  defp default_on_retry(_attempt, _error), do: :ok

  defp add_jitter(delay) do
    # Add ±25% jitter. Guard the range so :rand.uniform/1 is never called
    # with 0 (it raises) when delay < 4ms.
    jitter_range = max(div(delay, 4), 1)
    delay + :rand.uniform(jitter_range * 2) - jitter_range
  end

  @doc """
  Retry configuration specifically for MCP operations.

  Returns retry options optimized for MCP protocol operations.
  """
  @spec mcp_defaults(keyword()) :: keyword()
  def mcp_defaults(overrides \\ []) do
    defaults = [
      max_attempts: 3,
      initial_delay: 200,
      max_delay: 5000,
      backoff_factor: 2,
      jitter: true,
      should_retry?: &mcp_should_retry?/1
    ]

    Keyword.merge(defaults, overrides)
  end

  @doc """
  Merges client default retry policy with operation-specific overrides.

  Operation-specific values take precedence over client defaults.

  ## Examples

      iex> Arbor.MCP.Reliability.Retry.merge_policies(
      ...>   [max_attempts: 5, initial_delay: 100],
      ...>   [max_attempts: 3]
      ...> )
      [max_attempts: 3, initial_delay: 100]
  """
  @spec merge_policies(keyword(), keyword()) :: keyword()
  def merge_policies(client_defaults, operation_overrides) do
    Keyword.merge(client_defaults, operation_overrides)
  end

  defp mcp_should_retry?(error) do
    cond do
      network_error?(error) -> true
      transport_error?(error) -> true
      server_error?(error) -> true
      rate_limit_error?(error) -> true
      client_error?(error) -> false
      true -> false
    end
  end

  defp network_error?(error) do
    error in [
      :timeout,
      :closed,
      {:error, :closed},
      {:error, :timeout},
      {:error, :econnrefused},
      {:error, :ehostunreach},
      {:error, :enetunreach}
    ]
  end

  defp transport_error?({:transport_error, _}), do: true
  defp transport_error?(_), do: false

  defp server_error?(%{"error" => %{"code" => code}}) when code in -32099..-32000, do: true
  defp server_error?(_), do: false

  defp rate_limit_error?({:error, :rate_limited}), do: true
  defp rate_limit_error?(%{"error" => %{"code" => -32029}}), do: true
  defp rate_limit_error?(_), do: false

  defp client_error?(%{"error" => %{"code" => code}}) when code in -32700..-32600, do: true
  defp client_error?(_), do: false
end
