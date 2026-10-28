defmodule Arbor.MCP.Transport.HTTP.BoundedClient do
  @moduledoc false

  alias Arbor.MCP.Internal.CACerts
  alias Arbor.MCP.Internal.HTTPResponseReducer, as: Reducer
  alias Arbor.MCP.Transport.HTTP.TargetPolicy

  @max_declared_length Integer.pow(2, 62)

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

    with {:ok, transport_opts} <- CACerts.put_default(scheme, transport_opts) do
      Mint.HTTP1.connect(scheme, pinned_address, port,
        hostname: uri.host,
        mode: :passive,
        transport_opts: transport_opts,
        max_header_list_size: Keyword.get(opts, :max_header_bytes, 65_536),
        optional_responses: [:status_reason]
      )
    end
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
          stream = Keyword.get(opts, :event_stream)

          limits = [
            max_bytes: max_bytes,
            max_bytes_for: body_limit(max_bytes, stream),
            validate_headers: header_policy(max_bytes, stream)
          ]

          receive_response(
            next_conn,
            request_ref,
            Reducer.empty_response(),
            deadline,
            limits,
            stream
          )

        {:error, next_conn, reason} ->
          {{:error, {:http_request_failed, reason}}, next_conn}
      end

    {reply, final_conn} = result
    _ = Mint.HTTP1.close(final_conn)
    reply
  end

  defp receive_response(conn, request_ref, response, deadline, limits, stream) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {response_timeout(), conn}
    else
      recv_response(conn, request_ref, response, deadline, limits, stream, remaining)
    end
  end

  defp recv_response(conn, request_ref, response, deadline, limits, stream, remaining) do
    case Mint.HTTP1.recv(conn, 0, remaining) do
      {:ok, next_conn, events} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {response_timeout(), next_conn}
        else
          with {:done, completed} <- Reducer.reduce(events, request_ref, response, limits),
               {:ok, completed, stream} <- consume_stream(completed, stream, deadline),
               {:ok, completed} <- finish_stream(completed, stream),
               :ok <- response_within_deadline(deadline) do
            {{:ok, format_response(completed)}, next_conn}
          else
            {:cont, updated} ->
              case consume_stream(updated, stream, deadline) do
                {:ok, updated, stream} ->
                  receive_response(next_conn, request_ref, updated, deadline, limits, stream)

                {:error, reason} ->
                  {{:error, reason}, next_conn}
              end

            {:error, reason} ->
              {{:error, reason}, next_conn}
          end
        end

      {:error, next_conn, reason, _events} ->
        {{:error, {:http_receive_failed, reason}}, next_conn}
    end
  end

  defp response_within_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: response_timeout()
  end

  defp response_timeout,
    do: {:error, {:http_receive_failed, %Mint.TransportError{reason: :timeout}}}

  # An `:event_stream` hook, `{acc, fun}`, takes the body of a 2xx
  # `text/event-stream` response as it arrives instead of it accumulating:
  # `fun.({:data, chunk, deadline}, acc)` returns `{:ok, acc}` or
  # `{:error, reason}`, where `deadline` is the response's (monotonic
  # milliseconds), and `fun.(:done, acc)` returns `{:ok, body}`, the body the
  # response then carries.
  defp consume_stream(response, {acc, fun} = stream, deadline) do
    if response.chunks != [] and event_stream?(response) do
      case fun.({:data, Reducer.body(response), deadline}, acc) do
        {:ok, acc} -> {:ok, %{response | chunks: [], size: 0}, {acc, fun}}
        {:error, _reason} = error -> error
      end
    else
      {:ok, response, stream}
    end
  end

  defp consume_stream(response, nil, _deadline), do: {:ok, response, nil}

  defp finish_stream(response, {acc, fun}) do
    if event_stream?(response) do
      with {:ok, body} <- fun.(:done, acc),
           do: {:ok, %{response | chunks: [body], size: byte_size(body)}}
    else
      {:ok, response}
    end
  end

  defp finish_stream(response, nil), do: {:ok, response}

  defp event_stream?(%{status: status, headers: headers}) when status in 200..299,
    do: event_stream_type?(headers)

  defp event_stream?(_response), do: false

  defp event_stream_type?(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_name, value} -> String.contains?(String.downcase(value), "text/event-stream")
      nil -> false
    end
  end

  # A 2xx event-stream body handed to an `:event_stream` hook is limited as
  # the hook takes it, so neither one read of it nor the length it declares
  # counts against `:max_response_bytes`.
  defp body_limit(max_bytes, nil), do: fn _response -> max_bytes end

  defp body_limit(max_bytes, _stream) do
    fn response -> if event_stream?(response), do: @max_declared_length, else: max_bytes end
  end

  # Applied to the accumulated header list, trailers included: compression
  # and conflicting framing are refused, and the strict single-value
  # content-length rule decides the size limit.
  defp header_policy(max_bytes, stream) do
    fn _batch, accumulated, status ->
      length_limit =
        if is_nil(stream) or not event_stream?(%{status: status, headers: accumulated}),
          do: max_bytes,
          else: @max_declared_length

      cond do
        Reducer.compressed?(accumulated) ->
          {:error, :compressed_response}

        Reducer.conflicting_framing?(accumulated) ->
          {:error, :invalid_response_framing}

        Reducer.invalid_or_oversized_content_length?(accumulated, length_limit) ->
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
