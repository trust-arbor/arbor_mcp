defmodule Arbor.MCP.Client.Internal.ManualMRTR do
  @moduledoc false
  # Request options for a client that forwards a request for another client,
  # such as a gateway, which must leave each MRTR round to that client:
  #
  # - `mrtr: :manual` returns a validated `input_required` round to the caller
  #   as `{:input_required, %{input_requests: ..., request_state: ..., meta: ...}}`
  #   instead of answering it with the client handler.
  # - `input_responses:` and `request_state:` continue the call on its next
  #   round (`tools/call`, `resources/read` and `prompts/get`).
  # - `client_capabilities:` replaces the start capabilities in this one
  #   request's `_meta`, so the server chooses its input requests from what
  #   the downstream client declared.
  #
  # The continuation needs `mrtr: :manual`, and so do capabilities on a
  # request that can return input_required: under automatic MRTR the client's
  # own handler would answer a round that was chosen for capabilities it may
  # not have. A request that can't pause, such as `tools/list`, may declare
  # capabilities without it. All three need a 2026-07-28 connection, which
  # the client process decides when it builds the request (see
  # Arbor.MCP.Internal.RequestParams.for_request/3). `nil` leaves any of these
  # options unset, so a forwarding caller can pass the values it got from
  # downstream without filtering them first.
  #
  # The values are usually the downstream client's data, so a malformed one
  # is an `{:error, %Arbor.MCP.Error.ValidationError{}}`, not a raise. The
  # error leaves out input responses and request state, which may hold the
  # user's answers or a resumable token.

  alias Arbor.MCP.Client.Internal.InputResultSchema
  alias Arbor.MCP.Client.MRTR
  alias Arbor.MCP.Error
  alias Arbor.MCP.Protocol.ErrorCodes

  @mrtr_methods ["tools/call", "resources/read", "prompts/get"]

  @responses_shape "must map input request ids to elicitation, sampling or roots results"

  # A struct passes is_map/1 but isn't a JSON object, and may not be
  # Enumerable, so every map this module enumerates must be a plain one.
  defguardp is_plain_map(value) when is_map(value) and not is_struct(value)

  # Capabilities whose value the 2026-07-28 schema defines as an object, with
  # the members (or, for :all, every member) that must be objects too.
  @capability_objects %{
    "elicitation" => ["form", "url"],
    "sampling" => ["context", "tools"],
    "roots" => [],
    "experimental" => :all,
    "extensions" => :all
  }

  @type input_required :: Arbor.MCP.Client.Types.input_required()

  @spec manual?(keyword()) :: boolean()
  def manual?(opts), do: Keyword.get(opts, :mrtr) == :manual

  # Validates the options, puts the continuation on the request, and returns
  # the entries the client process applies when it builds the request:
  # `:client_capabilities`, and `:modern_options`, the options that only a
  # 2026-07-28 request can carry. A request without these options gets none.
  # Params pass through unchanged when no continuation is set, whatever
  # they are; Request.make_request/6 keeps its own handling of them.
  @spec prepare(String.t(), term(), keyword()) ::
          {:ok, term(), map()} | {:error, Exception.t()}
  def prepare(method, params, opts) do
    set = set_options(opts)

    with :ok <- require_manual(set, method, opts),
         :ok <- require_mrtr_method(set, method),
         :ok <- require_progress_token(method, params, opts),
         :ok <- validate_input_responses(Keyword.get(set, :input_responses), opts),
         :ok <- validate_request_state(Keyword.get(set, :request_state)),
         :ok <- validate_capabilities(Keyword.get(set, :client_capabilities)) do
      params =
        params
        |> put_present("inputResponses", Keyword.get(set, :input_responses))
        |> put_present("requestState", Keyword.get(set, :request_state))

      {:ok, params, request_meta(set, opts)}
    end
  end

  # Returns a round the caller answers itself, after the same checks that
  # automatic MRTR makes before it calls the handler: the result's shape and
  # the `:max_input_requests` and `:max_mrtr_bytes` limits here, then the era
  # and the declared capabilities in the client process. `:max_mrtr_rounds`
  # doesn't apply: the caller runs the rounds. The round's `_meta` is part of
  # the result the byte limit covers.
  @spec input_required(GenServer.server(), String.t(), map(), keyword(), integer()) ::
          {:input_required, input_required()} | {:error, term()}
  def input_required(client, method, result, opts, deadline) do
    with {:ok, input_requests, request_state} <- MRTR.validate_result(method, result, opts),
         {:ok, meta} <- result_meta(result),
         :ok <-
           check_round(client, input_requests, Keyword.get(opts, :client_capabilities), deadline) do
      {:input_required,
       %{input_requests: input_requests, request_state: request_state, meta: meta}}
    end
  end

  # Automatic MRTR never reads the round's `_meta`. Handed to the caller, it
  # must at least be the object the schema defines.
  defp result_meta(result) do
    case Map.get(result, "_meta", Map.get(result, :_meta)) do
      nil ->
        {:ok, nil}

      meta when is_plain_map(meta) ->
        {:ok, meta}

      _invalid ->
        {:error,
         Error.protocol_error(
           ErrorCodes.invalid_params(),
           "input_required _meta must be an object"
         )}
    end
  end

  defp check_round(client, input_requests, capabilities, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        GenServer.call(client, {:check_manual_mrtr, input_requests, capabilities}, remaining)

      _expired ->
        {:error, :timeout}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
  end

  defp set_options(opts) do
    [:input_responses, :request_state, :client_capabilities]
    |> Enum.map(&{&1, Keyword.get(opts, &1)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp require_manual(set, method, opts) do
    case Enum.find(set, fn {key, _value} -> needs_manual?(key, method) end) do
      {key, _value} ->
        if manual?(opts),
          do: :ok,
          else: {:error, Error.validation_error(key, nil, "requires mrtr: :manual")}

      nil ->
        :ok
    end
  end

  # Capabilities on a request that can't return input_required never reach
  # the client handler: there is no round for it to answer.
  defp needs_manual?(:client_capabilities, method), do: method in @mrtr_methods
  defp needs_manual?(_continuation, _method), do: true

  # The token the client adds for reset_timeout_on_progress or progress_to
  # differs on every round, and a server that binds requestState to all of
  # `_meta` rejects the next round. arbor_mcp leaves the token out of its
  # binding; another server may not.
  defp require_progress_token(method, params, opts) do
    cond do
      not manual?(opts) or method not in @mrtr_methods or progress_token?(params) ->
        :ok

      Keyword.get(opts, :reset_timeout_on_progress) == true ->
        missing_progress_token("reset_timeout_on_progress")

      Keyword.get(opts, :progress_to) != nil ->
        missing_progress_token("progress_to")

      true ->
        :ok
    end
  end

  defp missing_progress_token(option) do
    {:error,
     Error.validation_error(
       :progress_token,
       nil,
       "manual MRTR with #{option} needs an explicit :progress_token"
     )}
  end

  defp progress_token?(%{"_meta" => meta}) when is_map(meta),
    do: not is_nil(Map.get(meta, "progressToken") || Map.get(meta, :progressToken))

  defp progress_token?(_params), do: false

  defp require_mrtr_method(set, method) do
    case Keyword.take(set, [:input_responses, :request_state]) do
      [{key, _value} | _rest] when method not in @mrtr_methods ->
        {:error,
         Error.validation_error(
           key,
           nil,
           "is only valid for " <> Enum.join(@mrtr_methods, ", ") <> ", not #{method}"
         )}

      _valid ->
        :ok
    end
  end

  defp validate_input_responses(nil, _opts), do: :ok

  # A cheap first pass rejects anything that isn't a map of ids to plain maps,
  # structs included. The same byte limit that automatic MRTR puts on the
  # handler's responses follows, and then each response, as it will go out
  # on the wire, is checked against the schema.
  defp validate_input_responses(responses, opts) when is_plain_map(responses) do
    maximum = MRTR.max_bytes(opts)

    if Enum.all?(responses, &response_entry?/1) do
      case Jason.encode(responses) do
        {:ok, encoded} when byte_size(encoded) <= maximum ->
          validate_input_results(Jason.decode!(encoded))

        {:ok, _encoded} ->
          invalid_responses("exceed the MRTR byte limit of #{maximum} (:max_mrtr_bytes)")

        {:error, _reason} ->
          invalid_responses("must be JSON encodable")
      end
    else
      invalid_responses(@responses_shape)
    end
  end

  defp validate_input_responses(_responses, _opts), do: invalid_responses(@responses_shape)

  defp response_entry?({id, response}),
    do: is_binary(id) and byte_size(id) > 0 and is_plain_map(response)

  # The client keeps nothing between rounds, so it can't tell which input
  # request an id answered: a response is valid if it is any of the results
  # the 2026-07-28 schema defines for an input request. The error names the
  # id but never the response.
  defp validate_input_results(responses) do
    responses
    |> Enum.sort()
    |> Enum.find(fn {_id, response} -> not InputResultSchema.valid?(response) end)
    |> case do
      nil ->
        :ok

      {id, _response} ->
        invalid_responses(
          "#{inspect(id, printable_limit: 64)} is not an elicitation, sampling or roots " <>
            "result of the MCP 2026-07-28 schema"
        )
    end
  end

  defp invalid_responses(reason),
    do: {:error, Error.validation_error(:input_responses, nil, reason)}

  defp validate_request_state(nil), do: :ok
  defp validate_request_state(state) when is_binary(state), do: :ok

  defp validate_request_state(_state),
    do: {:error, Error.validation_error(:request_state, nil, "must be a string")}

  defp validate_capabilities(nil), do: :ok

  defp validate_capabilities(capabilities) when is_plain_map(capabilities) do
    cond do
      not Enum.all?(capabilities, &capability_entry?/1) ->
        invalid_capabilities(
          capabilities,
          "must be a capabilities object whose known capabilities are objects"
        )

      not match?({:ok, _encoded}, Jason.encode(capabilities)) ->
        invalid_capabilities(capabilities, "must be JSON encodable")

      true ->
        :ok
    end
  end

  defp validate_capabilities(capabilities),
    do: invalid_capabilities(capabilities, "must be a capabilities object")

  defp capability_entry?({key, value}) when is_atom(key) and not is_nil(key),
    do: capability_entry?({Atom.to_string(key), value})

  defp capability_entry?({key, value}) when is_binary(key) and byte_size(key) > 0 do
    case Map.fetch(@capability_objects, key) do
      :error -> true
      {:ok, _members} when not is_plain_map(value) -> false
      {:ok, :all} -> Enum.all?(value, fn {_member, setting} -> is_plain_map(setting) end)
      {:ok, members} -> Enum.all?(members, &object_member?(value, &1))
    end
  end

  defp capability_entry?(_entry), do: false

  defp object_member?(value, member) do
    case member_value(value, member) do
      :error -> true
      {:ok, setting} -> is_plain_map(setting)
    end
  end

  defp member_value(map, member) do
    with :error <- Map.fetch(map, member) do
      Enum.find_value(map, :error, fn
        {key, setting} when is_atom(key) and not is_nil(key) ->
          if Atom.to_string(key) == member, do: {:ok, setting}

        _other ->
          nil
      end)
    end
  end

  defp invalid_capabilities(capabilities, reason),
    do: {:error, Error.validation_error(:client_capabilities, capabilities, reason)}

  # A forwarding request answers for one downstream client, so it neither
  # reads nor fills the response cache, which the client's own callers share:
  # an answer chosen for that client's capabilities must not reach them, and
  # theirs must not answer it.
  defp request_meta(set, opts) do
    meta =
      if set == [] and not manual?(opts),
        do: %{},
        else: %{cache_mode: :bypass}

    meta =
      case Keyword.keys(set) do
        [] -> meta
        modern_options -> Map.put(meta, :modern_options, modern_options)
      end

    case Keyword.fetch(set, :client_capabilities) do
      {:ok, capabilities} -> Map.put(meta, :client_capabilities, capabilities)
      :error -> meta
    end
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)
end
