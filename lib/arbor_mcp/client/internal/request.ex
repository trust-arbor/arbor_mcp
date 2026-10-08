defmodule Arbor.MCP.Client.Internal.Request do
  @moduledoc false
  alias Arbor.MCP.Client.MRTR
  alias Arbor.MCP.Error
  alias Arbor.MCP.Protocol.ErrorCodes
  alias Arbor.MCP.Reliability.Retry
  alias Arbor.MCP.Response
  @default_max_mrtr_rounds 8

  defp format_response(response, :struct, opts) do
    # Use the proper Response.from_raw_response/2 constructor
    response_opts = [
      tool_name: Keyword.get(opts, :tool_name),
      request_id: Keyword.get(opts, :request_id),
      server_info: Keyword.get(opts, :server_info)
    ]

    structured_response = Response.from_raw_response(response, response_opts)
    {:ok, structured_response}
  end

  # Issues a single GenServer.call per request in the common path. Default
  # timeout and retry policy are resolved by the client process from its own
  # state instead of dedicated pre-flight calls:
  #
  # - Explicit :timeout opts are enforced caller-side via the GenServer.call
  #   timeout (explicit opts win).
  # - Without an explicit timeout, the client process schedules its own
  #   default-timeout timer for the request and replies {:error, :timeout};
  #   the call itself waits without a caller-side deadline (the call monitor
  #   still detects a dead client).
  # - The default retry policy is only fetched (one extra call) after a
  #   failed first attempt, so successful requests never pay for it.
  @spec make_request(Arbor.MCP.Client.t(), String.t(), map(), keyword(), pos_integer()) ::
          {:ok, any()} | {:error, any()}
  def make_request(client, method, params, opts, default_timeout) do
    stream_retry_mode = Keyword.get(opts, :http_stream_retry, :at_least_once)

    case validate_http_stream_retry_mode(client, stream_retry_mode) do
      :ok ->
        do_make_request(
          client,
          method,
          params,
          opts,
          default_timeout,
          stream_retry_mode
        )

      {:error, _reason} = error ->
        handle_request_result(error, opts)
    end
  end

  defp do_make_request(client, method, params, opts, default_timeout, stream_retry_mode) do
    started_at = System.monotonic_time(:millisecond)
    explicit_timeout = Keyword.get(opts, :timeout)
    retry_policy = Keyword.get(opts, :retry_policy, :use_default)
    scope_ref = make_ref()

    result =
      if explicit_timeout do
        deadline = started_at + explicit_timeout

        control = %{
          deadline: deadline,
          scope_ref: scope_ref,
          stream_retry_mode: stream_retry_mode
        }

        do_mrtr_request(
          client,
          method,
          params,
          params,
          opts,
          retry_policy,
          0,
          control
        )
      else
        first_operation = fn -> request_once(client, method, params, nil) end

        retry_operation = fn ->
          deadline = started_at + fetch_default_timeout(client, default_timeout)

          with {:ok, remaining} <- remaining_timeout(deadline) do
            request_once(client, method, params, remaining)
          end
        end

        case execute_with_stream_retry(
               first_operation,
               retry_operation,
               client,
               retry_policy,
               method,
               opts,
               stream_retry_mode,
               fn -> started_at + fetch_default_timeout(client, default_timeout) end
             ) do
          {:ok, result} = complete_or_extension ->
            if MRTR.input_required?(result) do
              deadline = started_at + fetch_default_timeout(client)

              control = %{
                deadline: deadline,
                scope_ref: scope_ref,
                stream_retry_mode: stream_retry_mode
              }

              continue_mrtr(
                client,
                method,
                params,
                result,
                opts,
                retry_policy,
                0,
                control
              )
            else
              complete_or_extension
            end

          other ->
            other
        end
      end

    if result == {:error, :timeout},
      do: GenServer.cast(client, {:cancel_mrtr_scope, scope_ref})

    handle_request_result(result, opts)
  end

  defp do_mrtr_request(
         client,
         method,
         original_params,
         round_params,
         opts,
         retry_policy,
         round,
         control
       ) do
    operation = fn ->
      with {:ok, remaining} <- remaining_timeout(control.deadline) do
        request_once(client, method, round_params, remaining)
      end
    end

    case execute_with_stream_retry(
           operation,
           operation,
           client,
           retry_policy,
           method,
           opts,
           control.stream_retry_mode,
           fn -> control.deadline end
         ) do
      {:ok, result} = complete_or_extension ->
        if MRTR.input_required?(result) do
          continue_mrtr(
            client,
            method,
            original_params,
            result,
            opts,
            retry_policy,
            round,
            control
          )
        else
          complete_or_extension
        end

      other ->
        other
    end
  end

  defp continue_mrtr(
         client,
         method,
         original_params,
         result,
         opts,
         retry_policy,
         round,
         control
       ) do
    maximum = Keyword.get(opts, :max_mrtr_rounds, @default_max_mrtr_rounds)

    outcome =
      if round >= maximum do
        {:error,
         Error.protocol_error(
           ErrorCodes.invalid_params(),
           "MRTR round limit exceeded",
           %{"maximum" => maximum}
         )}
      else
        with {:ok, input_requests, request_state} <- MRTR.validate_result(method, result, opts),
             {:ok, remaining} <- remaining_timeout(control.deadline),
             {:ok, input_responses} <-
               fulfill_mrtr(client, input_requests, opts, remaining, control.scope_ref) do
          next_round = round + 1

          :telemetry.execute(
            [:arbor_mcp, :client, :mrtr, :round],
            %{round: next_round, input_requests: map_size(input_requests)},
            %{method: mrtr_method_class(method)}
          )

          retry_params = MRTR.retry_params(original_params, input_responses, request_state)

          do_mrtr_request(
            client,
            method,
            original_params,
            retry_params,
            opts,
            retry_policy,
            next_round,
            control
          )
        end
      end

    case outcome do
      {:error, reason} = error ->
        :telemetry.execute(
          [:arbor_mcp, :client, :mrtr, :failure],
          %{round: round},
          %{
            method: mrtr_method_class(method),
            reason: client_mrtr_failure_class(reason, round, maximum)
          }
        )

        error

      other ->
        other
    end
  end

  defp mrtr_method_class(method) when method in ["tools/call", "resources/read", "prompts/get"],
    do: method

  defp mrtr_method_class(_method), do: :unknown

  defp client_mrtr_failure_class(_reason, round, maximum) when round >= maximum,
    do: :round_limit

  defp client_mrtr_failure_class(:timeout, _round, _maximum), do: :timeout

  defp client_mrtr_failure_class(%Error.ProtocolError{code: -32_021}, _round, _maximum),
    do: :missing_capability

  defp client_mrtr_failure_class(%Error.ProtocolError{}, _round, _maximum),
    do: :protocol_error

  defp client_mrtr_failure_class(_reason, _round, _maximum), do: :input_fulfillment_failed

  # The absolute deadline travels with the request so the client does not
  # send it after the caller has given up (see RequestHandler.handle_request/5).
  defp request_once(client, method, params, timeout) when is_integer(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    meta = %{timeout: timeout, deadline: deadline}
    GenServer.call(client, {:request, method, params, meta}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp request_once(client, method, params, nil) do
    GenServer.call(client, {:request, method, params, %{timeout: nil}}, :infinity)
  end

  defp fulfill_mrtr(client, input_requests, opts, timeout, scope_ref) do
    GenServer.call(client, {:fulfill_mrtr, input_requests, opts, scope_ref}, timeout)
  catch
    :exit, {:timeout, _} ->
      GenServer.cast(client, {:cancel_mrtr_scope, scope_ref})
      {:error, :timeout}
  end

  defp remaining_timeout(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, :timeout}
    end
  end

  defp execute_with_retry_policy(operation, client, retry_policy) do
    case retry_policy do
      :use_default ->
        execute_with_lazy_default_retry(operation, client)

      false ->
        operation.()

      [] ->
        operation.()

      policy when is_list(policy) ->
        Retry.with_retry(operation, Retry.mcp_defaults(policy))
    end
  end

  defp execute_with_stream_retry(
         operation,
         retry_operation,
         client,
         retry_policy,
         method,
         opts,
         stream_retry_mode,
         deadline_fun
       ) do
    operation
    |> execute_with_retry_policy(client, retry_policy)
    |> maybe_retry_broken_stream(
      retry_operation,
      method,
      opts,
      stream_retry_mode,
      deadline_fun
    )
  end

  defp maybe_retry_broken_stream(
         {:error, %Error.TransportError{reason: :response_stream_broken} = error},
         retry_operation,
         method,
         opts,
         stream_retry_mode,
         deadline_fun
       ) do
    if stream_retry_allowed?(stream_retry_mode, method, opts) do
      delay = http_stream_retry_delay(opts)
      deadline = deadline_fun.()

      case wait_for_stream_retry(delay, deadline) do
        :ok ->
          :telemetry.execute(
            [:arbor_mcp, :client, :http, :request, :retry],
            %{attempt: 2},
            %{method: method, mode: stream_retry_mode, delivery: :at_least_once}
          )

          case retry_operation.() do
            {:error, %Error.TransportError{reason: :response_stream_broken} = second_error} ->
              outcome_unknown(method, stream_retry_mode, 2, second_error)

            result ->
              result
          end

        {:error, :timeout} ->
          {:error, :timeout}
      end
    else
      outcome_unknown(method, stream_retry_mode, 1, error)
    end
  end

  defp maybe_retry_broken_stream(result, _retry, _method, _opts, _mode, _deadline),
    do: result

  defp stream_retry_allowed?(:at_least_once, _method, _opts), do: true

  defp stream_retry_allowed?(:safe_only, method, opts) do
    intrinsically_safe_method?(method) or Keyword.get(opts, :retry_safe, false) == true
  end

  defp intrinsically_safe_method?(method) do
    method in [
      "server/discover",
      "tools/list",
      "resources/list",
      "resources/templates/list",
      "resources/read",
      "prompts/list",
      "prompts/get",
      "completion/complete"
    ]
  end

  defp http_stream_retry_delay(opts) do
    case Keyword.get(opts, :http_stream_retry_delay, 200) do
      delay when is_integer(delay) and delay >= 0 -> delay
      _invalid -> 200
    end
  end

  defp wait_for_stream_retry(delay, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > delay ->
        if delay > 0, do: Process.sleep(delay)
        :ok

      _expired ->
        {:error, :timeout}
    end
  end

  defp outcome_unknown(method, mode, attempts, error) do
    {:error,
     Error.transport_error(:http, :outcome_unknown, %{
       method: method,
       retry_mode: mode,
       attempts: attempts,
       cause: error.details,
       message:
         "The response stream broke after delivery; the server may have completed the request."
     })}
  end

  defp validate_http_stream_retry_mode(_client, :at_least_once), do: :ok

  defp validate_http_stream_retry_mode(client, :safe_only) do
    if conformance_mode?(client) do
      {:error,
       Error.validation_error(
         :http_stream_retry,
         :safe_only,
         "safe_only is non-conforming and unavailable in conformance mode"
       )}
    else
      :ok
    end
  end

  defp validate_http_stream_retry_mode(_client, mode) do
    {:error,
     Error.validation_error(
       :http_stream_retry,
       mode,
       "expected :at_least_once or :safe_only"
     )}
  end

  defp conformance_mode?(client) do
    GenServer.call(client, :conformance_mode?, 5_000) == true
  catch
    :exit, _reason -> false
  end

  # First attempt runs without any pre-flight calls; the client's default
  # retry policy is only fetched when that attempt fails.
  defp execute_with_lazy_default_retry(operation, client) do
    case operation.() do
      {:error, reason} = error ->
        retry_remaining_attempts(operation, client, reason, error)

      result ->
        result
    end
  end

  defp retry_remaining_attempts(operation, client, reason, original_error) do
    case fetch_default_retry_policy(client) do
      [] ->
        original_error

      policy ->
        retry_opts = Retry.mcp_defaults(policy)
        should_retry? = Keyword.fetch!(retry_opts, :should_retry?)
        max_attempts = Keyword.get(retry_opts, :max_attempts, 0)

        if max_attempts > 1 and should_retry?.(reason) do
          # The first attempt already ran; honor its backoff delay, then run
          # the remaining attempts through the shared retry infrastructure.
          Process.sleep(Retry.calculate_delay(1, retry_opts))
          Retry.with_retry(operation, Keyword.put(retry_opts, :max_attempts, max_attempts - 1))
        else
          original_error
        end
    end
  end

  defp fetch_default_retry_policy(client) do
    case GenServer.call(client, :get_default_retry_policy, 5_000) do
      {:ok, policy} when is_list(policy) -> policy
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp fetch_default_timeout(client, fallback \\ 5_000) do
    case GenServer.call(client, :get_default_timeout, 5_000) do
      {:ok, timeout} when is_integer(timeout) and timeout > 0 -> timeout
      _other -> fallback
    end
  catch
    :exit, _reason -> fallback
  end

  defp handle_request_result({:ok, response}, opts) do
    case Keyword.get(opts, :format, :struct) do
      :map -> {:ok, response}
      format -> format_response(response, format, opts)
    end
  end

  defp handle_request_result({:error, %{__struct__: mod}} = error, _opts)
       when mod in [
              Error.ProtocolError,
              Error.TransportError,
              Error.ToolError,
              Error.ResourceError,
              Error.ValidationError
            ] do
    # Already an Arbor.MCP.Error struct, return as-is
    error
  end

  # A failed send carries the transport's reason as a term. The :map format
  # keeps the map (with its message text); :struct gives a TransportError.
  defp handle_request_result({:error, %{type: :transport_error, reason: reason} = error}, opts) do
    case Keyword.get(opts, :format, :struct) do
      :map ->
        {:error, error}

      _struct ->
        {:error,
         Error.transport_error(Map.get(error, :transport), reason, %{
           message: Map.get(error, :message)
         })}
    end
  end

  defp handle_request_result({:error, error_data}, opts) when is_map(error_data) do
    case Keyword.get(opts, :format, :struct) do
      :map ->
        # Return error data as map when format is :map
        {:error, error_data}

      _ ->
        # Convert JSON-RPC errors to ProtocolError for client responses
        code = Map.get(error_data, "code")
        message = Map.get(error_data, "message", "Unknown error")
        data = Map.get(error_data, "data")

        # For JSON-RPC standard errors, return ProtocolError
        error_struct =
          if code && code >= -32768 && code <= -32000 do
            %Error.ProtocolError{
              code: code,
              message: message,
              data: data
            }
          else
            # For non-standard errors, use the helper function for compatibility
            Error.from_json_rpc_error(error_data, request_id: Keyword.get(opts, :request_id))
          end

        {:error, error_struct}
    end
  end

  defp handle_request_result({:error, :not_connected}, _opts) do
    # Preserve :not_connected atom for backward compatibility
    {:error, :not_connected}
  end

  defp handle_request_result({:error, :timeout}, opts) do
    case Keyword.get(opts, :format, :struct) do
      :map ->
        # Return timeout as atom when format is :map
        {:error, :timeout}

      _ ->
        # Convert timeout to proper Arbor.MCP.Error
        {:error,
         %Error.ProtocolError{
           code: -32603,
           message: "Request timeout",
           data: nil
         }}
    end
  end

  defp handle_request_result(error, _opts), do: error
end
