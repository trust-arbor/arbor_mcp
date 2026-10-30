defmodule Arbor.MCP.Protocol.Elicitation do
  @moduledoc false

  # Validates `elicitation/create` params against the protocol's pinned
  # ElicitRequestParams schema, within the caller's deadline. Running out of
  # time is not the same as bad params, so validate/2 reports the two apart
  # (see its doc), and every caller reports a timeout as one.

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.Runtime.{Deadline, OutputCodec}

  @type error ::
          :invalid_elicitation_params
          | {:elicitation_validation_timeout, non_neg_integer() | :infinity}

  # Exact ElicitRequestParams and its transitive definitions from the pinned
  # 2026-07-28 primary schema. Includes legacy form/URL parameter shapes.
  @external_resource Path.join(__DIR__, "elicitation_schema.json")
  @schema @external_resource |> File.read!() |> Jason.decode!()

  # Keyed by the schema, so a recompiled module doesn't find a stale one.
  @compiled_key {__MODULE__, :erlang.phash2(@schema)}

  # The instance is bounded below and the schema is ours, so validation
  # gets more time than the default for untrusted schemas: on a busy
  # machine 100 ms failed real elicitations.
  @validation_timeout_ms 1_000

  @doc """
  Validates `elicitation/create` params before `deadline`.

  Returns `{:ok, normalized}` with the params as they go on the wire, or:

    * `{:error, :invalid_elicitation_params}` when the params break the
      ElicitRequestParams schema or its size and depth limits. The request
      was bad.
    * `{:error, {:elicitation_validation_timeout, budget_ms}}` when the
      deadline, or schema validation's own #{@validation_timeout_ms} ms
      limit, ended validation first, so nothing is known about the params.
      `budget_ms` is the time the deadline left when validation began: `0`
      means it had already passed, and `:infinity` that only the schema
      limit applied.
  """
  @spec validate(term(), Deadline.t()) :: {:ok, map()} | {:error, error()}
  def validate(params, deadline) do
    budget = Deadline.remaining(deadline)

    with :ok <- open(deadline, budget),
         {:ok, schema} <- compiled_schema(budget),
         {:ok, normalized} <- prepare(params, deadline, budget),
         # What's left once the schema and request are ready.
         :ok <- open(deadline, budget),
         :ok <- check_schema(normalized, schema, Deadline.remaining(deadline), budget),
         :ok <- open(deadline, budget) do
      {:ok, normalized}
    end
  end

  @doc """
  `validate/2` for a legacy server-to-client elicitation.

  A validation that ran out of time is `{:error, :timeout}`, which is what
  the reverse request reports when its deadline expires later on.
  """
  @spec validate_reverse(term(), Deadline.t()) ::
          {:ok, map()} | {:error, :timeout | :invalid_elicitation_params}
  def validate_reverse(params, deadline) do
    case validate(params, deadline) do
      {:ok, _normalized} = ok -> ok
      {:error, :invalid_elicitation_params} = invalid -> invalid
      {:error, {:elicitation_validation_timeout, _budget_ms}} -> {:error, :timeout}
    end
  end

  defp open(deadline, budget) do
    if Deadline.remaining(deadline) == 0, do: timeout(budget), else: :ok
  end

  defp prepare(params, deadline, budget) do
    case OutputCodec.prepare(params,
           codec: :protocol,
           deadline: deadline,
           max_frame_bytes: 65_536,
           max_term_bytes: 65_536
         ) do
      {:ok, prepared} -> {:ok, Jason.decode!(prepared.wire)}
      {:error, :output_expired} -> timeout(budget)
      {:error, _invalid} -> invalid()
    end
  end

  defp check_schema(normalized, schema, remaining, budget) do
    case SchemaPolicy.validate(normalized, schema,
           max_instance_bytes: 65_536,
           max_instance_depth: 32,
           validation_timeout_ms: min(@validation_timeout_ms, remaining)
         ) do
      :ok -> :ok
      {:error, {:schema_validation_timeout, _limit_ms}} -> timeout(budget)
      {:error, _invalid} -> invalid()
    end
  end

  # Compiled once, rather than for each request under its deadline.
  defp compiled_schema(budget) do
    case :persistent_term.get(@compiled_key, nil) do
      nil -> compile_schema(budget)
      compiled -> {:ok, compiled}
    end
  end

  defp compile_schema(budget) do
    case SchemaPolicy.compile(@schema) do
      {:ok, compiled} ->
        :persistent_term.put(@compiled_key, compiled)
        {:ok, compiled}

      {:error, {:schema_resolution_timeout, _limit_ms}} ->
        timeout(budget)

      {:error, _reason} ->
        invalid()
    end
  end

  defp timeout(budget), do: {:error, {:elicitation_validation_timeout, budget}}
  defp invalid, do: {:error, :invalid_elicitation_params}
end
