defmodule Arbor.MCP.Internal.HTTPResponseReducer do
  @moduledoc false

  # Pure reduction of Mint HTTP/1 response events into a bounded response
  # accumulator, plus the small pure helpers the pinned HTTP clients share.
  #
  # This module owns only mechanics: event accumulation order, request-ref
  # filtering, `:done` detection, the byte budget for the body, header
  # normalization, and the content-length / content-encoding / framing
  # predicates. Each caller keeps its own policy: which predicates it
  # composes into `:validate_headers`, which error atoms it returns, whether
  # it validates the latest header batch or the accumulated list, and how
  # it formats the final response. Nothing here touches sockets, clocks,
  # DNS, TLS, redirects, or OAuth.

  @type headers :: [{String.t(), String.t()}]

  @type acc :: %{
          status: nil | non_neg_integer(),
          reason: String.t(),
          headers: headers(),
          chunks: [binary()],
          size: non_neg_integer()
        }

  @typedoc """
  Called for every `:headers` event with the normalized headers from that
  event and the accumulated list including them. Returning `{:error, reason}`
  halts reduction with that reason untouched.
  """
  @type header_check :: (headers(), headers() -> :ok | {:error, term()})

  @type limits :: [max_bytes: pos_integer(), validate_headers: header_check()]

  @type result :: {:cont, acc()} | {:done, acc()} | {:error, term()}

  @spec empty_response() :: acc()
  def empty_response, do: %{status: nil, reason: "", headers: [], chunks: [], size: 0}

  @doc """
  Folds one batch of Mint events for `request_ref` into `acc`.

  Returns `{:cont, acc}` when the response is still open, `{:done, acc}` at
  the first `:done` for the ref (later events in the batch are ignored), and
  `{:error, reason}` when a header check fails or the body would exceed
  `:max_bytes`. Events for other refs and unknown event shapes are skipped.
  """
  @spec reduce([tuple()], Mint.Types.request_ref(), acc(), limits()) :: result()
  def reduce(events, request_ref, acc, limits) do
    max_bytes = Keyword.fetch!(limits, :max_bytes)
    validate = Keyword.get(limits, :validate_headers, fn _new, _all -> :ok end)

    events
    |> Enum.reduce_while(acc, &step(&1, request_ref, &2, max_bytes, validate))
    |> case do
      {:done, _acc} = done -> done
      {:error, _reason} = error -> error
      %{} = open -> {:cont, open}
    end
  end

  defp step({:status, ref, status}, ref, acc, _max_bytes, _validate),
    do: {:cont, %{acc | status: status}}

  defp step({:status_reason, ref, reason}, ref, acc, _max_bytes, _validate),
    do: {:cont, %{acc | reason: reason}}

  defp step({:headers, ref, headers}, ref, acc, _max_bytes, validate) do
    headers = normalize_headers(headers)
    all_headers = acc.headers ++ headers

    case validate.(headers, all_headers) do
      :ok -> {:cont, %{acc | headers: all_headers}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp step({:data, ref, data}, ref, acc, max_bytes, _validate) do
    size = acc.size + byte_size(data)

    if size > max_bytes do
      {:halt, {:error, :response_too_large}}
    else
      {:cont, %{acc | chunks: [data | acc.chunks], size: size}}
    end
  end

  defp step({:done, ref}, ref, acc, _max_bytes, _validate), do: {:halt, {:done, acc}}
  defp step(_event, _ref, acc, _max_bytes, _validate), do: {:cont, acc}

  @doc "Joins the accumulated chunks into the response body in arrival order."
  @spec body(acc()) :: binary()
  def body(%{chunks: chunks}), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  @doc "Milliseconds left before `deadline`, never negative."
  @spec remaining_ms(integer(), integer()) :: non_neg_integer()
  def remaining_ms(deadline, now), do: max(deadline - now, 0)

  @spec normalize_headers([{String.Chars.t(), String.Chars.t()}]) :: headers()
  def normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  @doc """
  Lenient content-length check: true when any `content-length` header is
  above `max_bytes` or does not parse as an integer. Multiple parseable
  values are each checked on their own and nothing is trimmed.
  """
  @spec content_length_too_large?(headers(), pos_integer()) :: boolean()
  def content_length_too_large?(headers, max_bytes) do
    Enum.any?(headers, fn
      {"content-length", value} ->
        case Integer.parse(value) do
          {length, ""} -> length > max_bytes
          _other -> true
        end

      _header ->
        false
    end)
  end

  @doc """
  Strict content-length check: true unless there is at most one
  `content-length` header whose trimmed value is a non-negative integer no
  larger than `max_bytes`.
  """
  @spec invalid_or_oversized_content_length?(headers(), pos_integer()) :: boolean()
  def invalid_or_oversized_content_length?(headers, max_bytes) do
    values = for {"content-length", value} <- headers, do: String.trim(value)

    case values do
      [] ->
        false

      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> length > max_bytes
          _invalid -> true
        end

      _multiple ->
        true
    end
  end

  @doc "True when any `content-encoding` is something other than blank or `identity`."
  @spec compressed?(headers()) :: boolean()
  def compressed?(headers) do
    Enum.any?(headers, fn
      {"content-encoding", value} -> String.downcase(String.trim(value)) not in ["", "identity"]
      _header -> false
    end)
  end

  @doc "True when both `content-length` and `transfer-encoding` are present."
  @spec conflicting_framing?(headers()) :: boolean()
  def conflicting_framing?(headers) do
    Enum.any?(headers, &(elem(&1, 0) == "content-length")) and
      Enum.any?(headers, &(elem(&1, 0) == "transfer-encoding"))
  end

  @doc "Request target for the request line: the path (`/` when absent) plus any query."
  @spec request_target(URI.t()) :: String.t()
  def request_target(%URI{path: path, query: nil}), do: path_or_root(path)
  def request_target(%URI{path: path, query: query}), do: path_or_root(path) <> "?" <> query

  defp path_or_root(path) when path in [nil, ""], do: "/"
  defp path_or_root(path), do: path

  @spec default_port(:http | :https) :: 80 | 443
  def default_port(:http), do: 80
  def default_port(:https), do: 443

  @doc "Mint transport options pinning the socket family to the resolved address."
  @spec address_family_options(:inet.ip_address()) :: [inet4: boolean(), inet6: boolean()]
  def address_family_options(address) when tuple_size(address) == 8,
    do: [inet4: false, inet6: true]

  def address_family_options(_address), do: [inet4: true, inet6: false]

  @spec method_name(atom()) :: String.t()
  def method_name(method), do: method |> Atom.to_string() |> String.upcase()
end
