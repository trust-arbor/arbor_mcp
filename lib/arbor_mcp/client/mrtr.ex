defmodule Arbor.MCP.Client.MRTR do
  @moduledoc false

  alias Arbor.MCP.Client.{InputDispatcher, Lifetime}
  alias Arbor.MCP.Error
  alias Arbor.MCP.Protocol.ErrorCodes

  @supported_methods ["tools/call", "resources/read", "prompts/get"]
  @default_max_input_requests 16
  @default_max_bytes 1_048_576
  @max_input_concurrency 16

  @spec input_required?(term()) :: boolean()
  def input_required?(result) when is_map(result) do
    value(result, "resultType") == "input_required"
  end

  def input_required?(_result), do: false

  @spec validate_result(String.t(), map(), keyword()) ::
          {:ok, map(), String.t() | nil} | {:error, Error.ProtocolError.t()}
  def validate_result(original_method, result, opts \\ []) do
    with :ok <- validate_original_method(original_method),
         {:ok, input_requests} <- fetch_input_requests(result),
         {:ok, request_state} <- fetch_request_state(result),
         :ok <- require_continuation(input_requests, request_state),
         :ok <- validate_request_count(input_requests, opts),
         :ok <- validate_size(result, opts),
         :ok <- validate_input_requests(input_requests) do
      {:ok, input_requests, request_state}
    end
  end

  @spec fulfill(map(), module() | :none, term(), map(), keyword()) ::
          {:ok, map(), term()} | {:error, term(), term()}
  def fulfill(input_requests, handler, handler_state, capabilities, opts \\ []) do
    result =
      case input_concurrency(handler) do
        {:ok, 1} ->
          fulfill_sequential(input_requests, handler, handler_state, capabilities)

        {:ok, concurrency} ->
          fulfill_concurrently(
            input_requests,
            handler,
            handler_state,
            capabilities,
            concurrency
          )

        {:error, reason} ->
          {:error, reason, handler_state}
      end

    with {:ok, responses, new_state} <- result,
         :ok <- validate_response_ids(input_requests, responses),
         :ok <- validate_size(responses, opts) do
      {:ok, responses, new_state}
    else
      {:error, reason, new_state} -> {:error, reason, new_state}
      {:error, reason} -> {:error, reason, handler_state}
    end
  end

  defp fulfill_sequential(input_requests, handler, handler_state, capabilities) do
    input_requests
    |> Enum.sort_by(fn {id, _request} -> id end)
    |> Enum.reduce_while({:ok, %{}, handler_state}, fn {id, request},
                                                       {:ok, responses, current_state} ->
      case dispatch(request, handler, current_state, capabilities) do
        {:ok, response, new_state} ->
          {:cont, {:ok, Map.put(responses, id, response), new_state}}

        {:error, reason, new_state} ->
          {:halt, {:error, reason, new_state}}
      end
    end)
  end

  defp fulfill_concurrently(input_requests, handler, handler_state, capabilities, concurrency) do
    input_requests
    |> Enum.sort_by(fn {id, _request} -> id end)
    |> Lifetime.async_stream(
      fn {id, request} ->
        {id, dispatch_captured(request, handler, handler_state, capabilities)}
      end,
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, %{}, handler_state}, fn
      {:ok, {id, {:ok, response, new_state}}}, {:ok, responses, original_state} ->
        if new_state === original_state do
          {:cont, {:ok, Map.put(responses, id, response), original_state}}
        else
          {:halt, {:error, concurrent_state_error(id), original_state}}
        end

      {:ok, {id, {:error, reason, new_state}}}, {:ok, _responses, original_state} ->
        if new_state === original_state do
          {:halt, {:error, reason, original_state}}
        else
          {:halt, {:error, concurrent_state_error(id), original_state}}
        end

      {:exit, reason}, {:ok, _responses, original_state} ->
        {:halt,
         {:error, error("Concurrent MRTR input callback exited", %{"reason" => inspect(reason)}),
          original_state}}
    end)
  end

  # Capture callback failures before Task.Supervised emits a native report.
  # The private result retains the original detail for the trusted fulfillment
  # owner; RequestHandler continues returning its fixed public protocol error.
  # A converted failure completes this native Task normally, with the same
  # parent, callback process, pre-effect reservation and async-stream bound.
  defp dispatch_captured(request, handler, handler_state, capabilities) do
    dispatch(request, handler, handler_state, capabilities)
  rescue
    error -> {:error, {:client_handler_raised, error, __STACKTRACE__}, handler_state}
  catch
    kind, value -> {:error, {:client_handler_caught, {kind, value}}, handler_state}
  end

  defp dispatch(request, handler, handler_state, capabilities) do
    method = value(request, "method")
    params = value(request, "params") || %{}

    InputDispatcher.dispatch(
      method,
      params,
      handler,
      handler_state,
      capabilities,
      require_capability: true
    )
  end

  defp input_concurrency(:none), do: {:ok, 1}

  defp input_concurrency(handler) when is_atom(handler) do
    if callback?(handler, :mrtr_input_concurrency, 0) do
      case handler.mrtr_input_concurrency() do
        concurrency when concurrency in 2..@max_input_concurrency ->
          {:ok, concurrency}

        concurrency ->
          {:error,
           error("Invalid MRTR input concurrency", %{
             "maximum" => @max_input_concurrency,
             "value" => inspect(concurrency)
           })}
      end
    else
      {:ok, 1}
    end
  end

  defp concurrent_state_error(id) do
    error("Parallel MRTR input callbacks must not update handler state", %{
      "inputRequestId" => id
    })
  end

  defp callback?(handler, function, arity) do
    function_exported?(handler, function, arity) or
      (Code.ensure_loaded?(handler) and function_exported?(handler, function, arity))
  end

  @spec retry_params(map(), map(), String.t() | nil) :: map()
  def retry_params(original_params, input_responses, request_state) do
    original_params
    |> Map.put("inputResponses", input_responses)
    |> maybe_put_request_state(request_state)
  end

  defp fetch_input_requests(result) do
    case fetch(result, "inputRequests") do
      :error -> {:ok, %{}}
      {:ok, requests} when is_map(requests) -> {:ok, stringify_id_keys(requests)}
      {:ok, _other} -> {:error, error("inputRequests must be an object")}
    end
  end

  defp fetch_request_state(result) do
    case fetch(result, "requestState") do
      :error -> {:ok, nil}
      {:ok, state} when is_binary(state) -> {:ok, state}
      {:ok, _other} -> {:error, error("requestState must be a string")}
    end
  end

  defp require_continuation(input_requests, nil) when map_size(input_requests) == 0,
    do: {:error, error("input_required must contain inputRequests or requestState")}

  defp require_continuation(_input_requests, _request_state), do: :ok

  defp validate_original_method(method) when method in @supported_methods, do: :ok

  defp validate_original_method(method) do
    {:error, error("input_required is not valid for this method", %{"method" => method})}
  end

  defp validate_request_count(requests, opts) do
    maximum = Keyword.get(opts, :max_input_requests, @default_max_input_requests)

    if map_size(requests) <= maximum,
      do: :ok,
      else: {:error, error("MRTR input request limit exceeded", %{"maximum" => maximum})}
  end

  defp validate_input_requests(requests) do
    Enum.reduce_while(requests, :ok, fn
      {id, request}, :ok when is_binary(id) and byte_size(id) > 0 and is_map(request) ->
        method = value(request, "method")
        params = value(request, "params") || %{}

        if method in ["elicitation/create", "sampling/createMessage", "roots/list"] and
             is_map(params) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            error("Invalid MRTR input request", %{"inputRequestId" => id, "method" => method})}}
        end

      {id, _request}, :ok ->
        {:halt, {:error, error("Invalid MRTR input request", %{"inputRequestId" => id})}}
    end)
  end

  defp validate_response_ids(requests, responses) do
    requested = requests |> Map.keys() |> Enum.sort()
    returned = responses |> Map.keys() |> Enum.sort()

    if requested == returned,
      do: :ok,
      else: {:error, error("inputResponses keys do not match inputRequests")}
  end

  defp validate_size(value, opts) do
    maximum = Keyword.get(opts, :max_mrtr_bytes, @default_max_bytes)

    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= maximum -> :ok
      {:ok, _encoded} -> {:error, error("MRTR byte limit exceeded", %{"maximum" => maximum})}
      {:error, _reason} -> {:error, error("MRTR payload is not JSON encodable")}
    end
  end

  defp stringify_id_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_put_request_state(params, nil), do: Map.delete(params, "requestState")
  defp maybe_put_request_state(params, state), do: Map.put(params, "requestState", state)

  defp fetch(map, key) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.get(map, atom_key)}
      true -> :error
    end
  rescue
    ArgumentError -> if Map.has_key?(map, key), do: {:ok, Map.get(map, key)}, else: :error
  end

  defp value(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp error(message, data \\ nil) do
    Error.protocol_error(ErrorCodes.invalid_params(), message, data)
  end
end
