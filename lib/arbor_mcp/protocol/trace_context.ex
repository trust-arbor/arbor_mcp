defmodule Arbor.MCP.Protocol.TraceContext do
  @moduledoc """
  Validates and bounds W3C trace-context fields carried in MCP `_meta`.

  `traceparent` and `tracestate` follow the W3C Trace Context wire grammar.
  Baggage is bounded before filtering and only explicitly allowlisted baggage
  keys are propagated. This module handles wire values only; it does not attach
  them to process-global OpenTelemetry state.
  """

  @trace_keys ~w(traceparent tracestate baggage)
  @traceparent_pattern ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$/
  @simple_tracestate_key ~r/^[a-z][a-z0-9_\-*\/]{0,255}$/
  @tenant_tracestate_key ~r/^[a-z0-9][a-z0-9_\-*\/]{0,240}@[a-z][a-z0-9_\-*\/]{0,13}$/
  @baggage_key_pattern ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @defaults [
    baggage_allowlist: [],
    max_total_bytes: 9_216,
    max_baggage_bytes: 8_192,
    max_baggage_members: 64
  ]

  @type error_key :: String.t()

  @max_configured_bytes 65_536

  @doc "Returns the trace-context keys used in MCP metadata."
  @spec keys() :: [String.t()]
  def keys, do: @trace_keys

  @doc "Validates, bounds, and filters a trace-context map."
  @spec normalize(map()) :: {:ok, map()} | {:error, error_key()}
  def normalize(context) when is_map(context) do
    opts = options()

    with {:ok, context} <- stringify_trace_keys(context),
         :ok <- validate_options(opts),
         :ok <- validate_binary_values(context),
         :ok <- validate_total_bytes(context, opts),
         :ok <- validate_traceparent(context["traceparent"]),
         :ok <- validate_tracestate(context["tracestate"], context["traceparent"]),
         {:ok, baggage} <- normalize_baggage(context["baggage"], opts) do
      normalized =
        context
        |> Map.take(~w(traceparent tracestate))
        |> put_optional("baggage", baggage)

      {:ok, normalized}
    end
  end

  def normalize(_context), do: {:error, "trace-context"}

  @doc false
  @spec select(map()) :: {:ok, map()} | {:error, error_key()}
  def select(context) when is_map(context), do: stringify_trace_keys(context)
  def select(_context), do: {:error, "trace-context"}

  defp options do
    configured = Application.get_env(:arbor_mcp, :otel_meta, [])

    if Keyword.keyword?(configured) do
      Keyword.merge(@defaults, Keyword.take(configured, Keyword.keys(@defaults)))
    else
      :invalid
    end
  end

  defp validate_options(opts) when is_list(opts) do
    integer_keys = ~w(max_total_bytes max_baggage_bytes max_baggage_members)a

    valid_integers? =
      Enum.all?(integer_keys, fn
        :max_baggage_members ->
          is_integer(opts[:max_baggage_members]) and opts[:max_baggage_members] in 0..64

        key ->
          is_integer(opts[key]) and opts[key] in 0..@max_configured_bytes
      end)

    allowlist = opts[:baggage_allowlist]

    valid_allowlist? =
      is_list(allowlist) and length(allowlist) <= 64 and
        Enum.all?(allowlist, fn key ->
          is_binary(key) and byte_size(key) in 1..256 and valid_baggage_key?(key)
        end)

    if valid_integers? and valid_allowlist?, do: :ok, else: {:error, "trace-context"}
  end

  defp validate_options(_opts), do: {:error, "trace-context"}

  defp validate_binary_values(context) do
    if Enum.all?(context, fn {_key, value} -> is_binary(value) end),
      do: :ok,
      else: {:error, "trace-context"}
  end

  defp validate_total_bytes(context, opts) do
    bytes =
      Enum.reduce(context, 0, fn {key, value}, total ->
        total + byte_size(key) + byte_size(value)
      end)

    if bytes <= opts[:max_total_bytes], do: :ok, else: {:error, "trace-context"}
  end

  defp validate_traceparent(nil), do: :ok

  defp validate_traceparent(traceparent) do
    valid? =
      ascii_header?(traceparent) and byte_size(traceparent) == 55 and
        Regex.match?(@traceparent_pattern, traceparent) and
        binary_part(traceparent, 3, 32) != String.duplicate("0", 32) and
        binary_part(traceparent, 36, 16) != String.duplicate("0", 16)

    if valid?, do: :ok, else: {:error, "traceparent"}
  end

  defp validate_tracestate(nil, _traceparent), do: :ok
  defp validate_tracestate(_tracestate, nil), do: {:error, "tracestate"}

  defp validate_tracestate(tracestate, _traceparent) do
    members = String.split(tracestate, ",", trim: false)

    valid? =
      ascii_header?(tracestate) and byte_size(tracestate) <= 512 and
        length(members) in 1..32 and
        valid_tracestate_members?(members)

    if valid?, do: :ok, else: {:error, "tracestate"}
  end

  defp valid_tracestate_members?(members) do
    case collect_tracestate_keys(members, []) do
      {:ok, keys} -> length(keys) == MapSet.size(MapSet.new(keys))
      :error -> false
    end
  end

  defp collect_tracestate_keys([], keys), do: {:ok, keys}

  defp collect_tracestate_keys([member | rest], keys) do
    case String.split(String.trim(member), "=", parts: 2) do
      [key, value] ->
        if valid_tracestate_key?(key) and valid_tracestate_value?(value),
          do: collect_tracestate_keys(rest, [key | keys]),
          else: :error

      _invalid ->
        :error
    end
  end

  defp valid_tracestate_key?(key) do
    Regex.match?(@simple_tracestate_key, key) or Regex.match?(@tenant_tracestate_key, key)
  end

  defp valid_tracestate_value?(value) do
    byte_size(value) in 1..256 and not String.starts_with?(value, " ") and
      not String.ends_with?(value, " ") and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E and &1 not in [?,, ?=]))
  end

  defp normalize_baggage(nil, _opts), do: {:ok, nil}

  defp normalize_baggage(baggage, opts) do
    cond do
      not ascii_header?(baggage) ->
        {:error, "baggage"}

      byte_size(baggage) > opts[:max_baggage_bytes] ->
        {:error, "baggage"}

      true ->
        members = String.split(baggage, ",", trim: false)

        if length(members) < 1 or length(members) > opts[:max_baggage_members] do
          {:error, "baggage"}
        else
          filter_baggage_members(members, MapSet.new(opts[:baggage_allowlist]))
        end
    end
  end

  defp filter_baggage_members(members, allowlist) do
    case parse_baggage_members(members, [], %{}) do
      {:ok, parsed} ->
        allowed =
          for {key, member} <- Enum.reverse(parsed), MapSet.member?(allowlist, key), do: member

        case allowed do
          [] -> {:ok, nil}
          values -> {:ok, Enum.join(values, ",")}
        end

      :error ->
        {:error, "baggage"}
    end
  end

  defp parse_baggage_members([], parsed, _seen), do: {:ok, parsed}

  defp parse_baggage_members([raw_member | rest], parsed, seen) do
    member = String.trim(raw_member)

    case String.split(member, "=", parts: 2) do
      [key, value_and_properties] ->
        valid? =
          valid_baggage_key?(key) and not Map.has_key?(seen, key) and
            valid_baggage_value_and_properties?(value_and_properties)

        if valid? do
          parse_baggage_members(rest, [{key, member} | parsed], Map.put(seen, key, true))
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp valid_baggage_key?(key) do
    ascii_header?(key) and Regex.match?(@baggage_key_pattern, key)
  end

  defp valid_baggage_value_and_properties?(value_and_properties) do
    case String.split(value_and_properties, ";", trim: false) do
      [value | properties] ->
        valid_baggage_value?(value) and Enum.all?(properties, &valid_baggage_property?/1)

      [] ->
        false
    end
  end

  defp valid_baggage_value?(value) do
    byte_size(value) <= 4_096 and
      Enum.all?(:binary.bin_to_list(value), fn byte ->
        byte in 0x21..0x7E and byte not in [?", ?,, ?;, ?\\]
      end)
  end

  defp valid_baggage_property?(property) do
    case String.split(String.trim(property), "=", parts: 2) do
      [key] -> valid_baggage_key?(key)
      [key, value] -> valid_baggage_key?(key) and valid_baggage_value?(value)
      _invalid -> false
    end
  end

  defp stringify_trace_keys(context) do
    Enum.reduce_while(context, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- stringify_trace_key(key),
           false <- key in @trace_keys and Map.has_key?(normalized, key) do
        normalized = if key in @trace_keys, do: Map.put(normalized, key, value), else: normalized
        {:cont, {:ok, normalized}}
      else
        _invalid -> {:halt, {:error, "trace-context"}}
      end
    end)
  end

  defp stringify_trace_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_trace_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_trace_key(_key), do: :error

  defp ascii_header?(value) do
    Enum.all?(:binary.bin_to_list(value), &(&1 == ?\t or &1 in 0x20..0x7E))
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
