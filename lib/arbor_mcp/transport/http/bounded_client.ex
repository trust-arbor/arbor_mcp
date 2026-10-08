defmodule Arbor.MCP.Transport.HTTP.BoundedClient do
  @moduledoc false

  alias Arbor.MCP.Internal.HTTPResponseReducer, as: Reducer
  alias Arbor.MCP.Transport.HTTP.TargetPolicy

  @type response :: {
          {charlist(), pos_integer(), charlist()},
          [{String.t(), String.t()}],
          binary()
        }

  @spec request(atom(), String.t(), list(), binary(), binary(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, url, headers, content_type, body, opts)
      when method in [:get, :post, :put, :patch, :delete] and is_binary(url) and
             is_binary(content_type) and is_binary(body) do
    # The deadline is applied before each step that can wait (DNS, connect)
    # with what is left of it at that point, and checked once more before a
    # byte is written.
    with {:ok, opts} <- apply_deadline(opts),
         {:ok, uri, address} <- TargetPolicy.resolve(url, opts),
         :ok <- request_within_limit(body, opts),
         {:ok, opts} <- apply_deadline(opts),
         {:ok, conn} <- connect(uri, address, opts),
         {:ok, conn} <- before_send(conn, opts) do
      do_request(conn, method, uri, headers, content_type, body, opts)
    end
  rescue
    exception -> {:error, {:http_client_error, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:http_client_error, kind}}
  end

  # An absolute `:deadline` (monotonic milliseconds) caps the whole exchange:
  # DNS, connect and the response all have to fit before it. A deadline that
  # has already passed refuses the request before anything is resolved or
  # connected, so `:deadline_expired` always means nothing was sent.
  defp apply_deadline(opts) do
    case Keyword.get(opts, :deadline) do
      nil ->
        {:ok, opts}

      deadline when is_integer(deadline) ->
        case deadline - System.monotonic_time(:millisecond) do
          remaining when remaining > 0 ->
            {:ok, opts |> cap(:connect_timeout, remaining) |> cap(:dns_timeout_ms, remaining)}

          _expired ->
            {:error, :deadline_expired}
        end
    end
  end

  defp before_send(conn, opts) do
    case Keyword.get(opts, :deadline) do
      deadline when is_integer(deadline) ->
        if System.monotonic_time(:millisecond) < deadline do
          {:ok, conn}
        else
          _ = Mint.HTTP1.close(conn)
          {:error, :deadline_expired}
        end

      nil ->
        {:ok, conn}
    end
  end

  defp cap(opts, key, limit) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> Keyword.put(opts, key, min(value, limit))
      _other -> opts
    end
  end

  defp response_deadline(opts) do
    from_timeout = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :request_timeout)

    case Keyword.get(opts, :deadline) do
      deadline when is_integer(deadline) -> min(from_timeout, deadline)
      nil -> from_timeout
    end
  end

  defp request_within_limit(body, opts) do
    if byte_size(body) <= Keyword.fetch!(opts, :max_request_bytes),
      do: :ok,
      else: {:error, :request_too_large}
  end

  defp connect(uri, address, opts) do
    scheme = String.to_existing_atom(uri.scheme)
    port = uri.port || Reducer.default_port(scheme)
    pinned_address = address |> :inet.ntoa() |> to_string()

    transport_opts =
      opts
      |> Keyword.fetch!(:transport_opts)
      |> Keyword.put(:timeout, Keyword.fetch!(opts, :connect_timeout))
      |> Keyword.merge(Reducer.address_family_options(address))

    Mint.HTTP1.connect(scheme, pinned_address, port,
      hostname: uri.host,
      mode: :passive,
      transport_opts: transport_opts,
      max_header_list_size: Keyword.get(opts, :max_header_bytes, 65_536),
      optional_responses: [:status_reason]
    )
  end

  defp do_request(conn, method, uri, headers, content_type, body, opts) do
    headers =
      headers
      |> Reducer.normalize_headers()
      |> delete_header("host")
      |> put_header("content-type", content_type)
      |> put_header("accept-encoding", "identity")

    target = Reducer.request_target(uri)

    result =
      case Mint.HTTP1.request(conn, Reducer.method_name(method), target, headers, body) do
        {:ok, next_conn, request_ref} ->
          deadline = response_deadline(opts)
          max_bytes = Keyword.fetch!(opts, :max_response_bytes)
          limits = [max_bytes: max_bytes, validate_headers: header_policy(max_bytes)]
          receive_response(next_conn, request_ref, Reducer.empty_response(), deadline, limits)

        {:error, next_conn, reason} ->
          {{:error, {:http_request_failed, reason}}, next_conn}
      end

    {reply, final_conn} = result
    _ = Mint.HTTP1.close(final_conn)
    reply
  end

  defp receive_response(conn, request_ref, response, deadline, limits) do
    timeout = Reducer.remaining_ms(deadline, System.monotonic_time(:millisecond))

    case Mint.HTTP1.recv(conn, 0, timeout) do
      {:ok, next_conn, events} ->
        case Reducer.reduce(events, request_ref, response, limits) do
          {:done, completed} ->
            {{:ok, format_response(completed)}, next_conn}

          {:cont, updated} ->
            receive_response(next_conn, request_ref, updated, deadline, limits)

          {:error, reason} ->
            {{:error, reason}, next_conn}
        end

      {:error, next_conn, reason, _events} ->
        {{:error, {:http_receive_failed, reason}}, next_conn}
    end
  end

  # Applied to the accumulated header list, trailers included: compression
  # and conflicting framing are refused, and the strict single-value
  # content-length rule decides the size limit.
  defp header_policy(max_bytes) do
    fn _batch, accumulated ->
      cond do
        Reducer.compressed?(accumulated) ->
          {:error, :compressed_response}

        Reducer.conflicting_framing?(accumulated) ->
          {:error, :invalid_response_framing}

        Reducer.invalid_or_oversized_content_length?(accumulated, max_bytes) ->
          {:error, :response_too_large}

        true ->
          :ok
      end
    end
  end

  defp format_response(response) do
    status_line = {~c"HTTP/1.1", response.status, to_charlist(response.reason)}
    {status_line, response.headers, Reducer.body(response)}
  end

  defp put_header(headers, name, value) do
    [{name, value} | Enum.reject(headers, fn {key, _value} -> key == name end)]
  end

  defp delete_header(headers, name), do: Enum.reject(headers, &(elem(&1, 0) == name))
end
