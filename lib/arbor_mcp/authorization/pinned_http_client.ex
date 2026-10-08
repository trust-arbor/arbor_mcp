defmodule Arbor.MCP.Authorization.PinnedHTTPClient do
  @moduledoc false

  alias Arbor.MCP.Internal.HTTPResponseReducer, as: Reducer

  @type httpc_response ::
          {{charlist(), non_neg_integer(), charlist()}, [{String.t(), String.t()}], binary()}

  @spec request(atom(), URI.t(), :inet.ip_address(), tuple(), keyword(), keyword()) ::
          {:ok, httpc_response()} | {:error, term()}
  def request(method, %URI{} = uri, address, request, http_options, opts)
      when method in [:get, :post, :put, :delete] and is_list(http_options) and is_list(opts) do
    with {:ok, headers, body} <- request_parts(request),
         {:ok, conn} <- connect(uri, address, http_options, opts) do
      request_and_receive(conn, method, uri, headers, body, opts)
    end
  rescue
    _exception -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp connect(uri, address, http_options, opts) do
    scheme = String.to_existing_atom(uri.scheme)
    port = uri.port || Reducer.default_port(scheme)
    pinned_address = address |> :inet.ntoa() |> to_string()

    transport_opts =
      http_options
      |> Keyword.get(:ssl, [])
      |> Keyword.put(:timeout, Keyword.fetch!(opts, :connect_timeout_ms))
      |> Keyword.put(:send_timeout, Keyword.fetch!(opts, :request_timeout_ms))
      |> Keyword.put(:send_timeout_close, true)
      |> Keyword.merge(Reducer.address_family_options(address))

    Mint.HTTP1.connect(scheme, pinned_address, port,
      hostname: uri.host,
      mode: :passive,
      transport_opts: transport_opts,
      max_header_list_size: Keyword.fetch!(opts, :max_header_bytes),
      optional_responses: [:status_reason]
    )
  end

  defp request_and_receive(conn, method, uri, headers, body, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :request_timeout_ms)
    max_bytes = Keyword.fetch!(opts, :max_response_bytes)
    limits = [max_bytes: max_bytes, validate_headers: header_policy(max_bytes)]
    target = Reducer.request_target(uri)

    case Mint.HTTP1.request(conn, Reducer.method_name(method), target, headers, body) do
      {:ok, next_conn, request_ref} ->
        {reply, _final_conn} =
          receive_response(next_conn, request_ref, Reducer.empty_response(), deadline, limits)

        reply

      {:error, _next_conn, _reason} ->
        {:error, :request_failed}
    end
  after
    # Mint connections are immutable, but every state returned for this
    # single request owns the same socket. Closing the initial state therefore
    # also covers parser failures and exceptions before a final state exists.
    _ = Mint.HTTP1.close(conn)
  end

  defp receive_response(conn, request_ref, response, deadline, limits) do
    timeout = Reducer.remaining_ms(deadline, System.monotonic_time(:millisecond))

    case Mint.HTTP1.recv(conn, 0, timeout) do
      {:ok, next_conn, events} ->
        case Reducer.reduce(events, request_ref, response, limits) do
          {:done, completed} ->
            {complete_response(completed), next_conn}

          {:cont, updated} ->
            receive_response(next_conn, request_ref, updated, deadline, limits)

          {:error, reason} ->
            {{:error, reason}, next_conn}
        end

      {:error, next_conn, _reason, _events} ->
        {{:error, :request_failed}, next_conn}
    end
  end

  defp complete_response(%{status: status} = response) when is_integer(status),
    do: {:ok, format_response(response)}

  defp complete_response(_response), do: {:error, :invalid_response}

  # Applied to each header batch on its own: compression is refused, and the
  # strict single-value content-length rule decides the size limit.
  defp header_policy(max_bytes) do
    fn batch, _accumulated ->
      cond do
        Reducer.compressed?(batch) ->
          {:error, :compressed_response}

        Reducer.invalid_or_oversized_content_length?(batch, max_bytes) ->
          {:error, :response_too_large}

        true ->
          :ok
      end
    end
  end

  defp format_response(response) do
    status_line = {~c"HTTP/1.1", response.status, String.to_charlist(response.reason)}
    {status_line, response.headers, Reducer.body(response)}
  end

  defp request_parts({_url, headers}) do
    {:ok, Reducer.normalize_headers(headers), nil}
  end

  defp request_parts({_url, headers, content_type, body}) do
    headers =
      headers
      |> Reducer.normalize_headers()
      |> put_header_if_missing("content-type", to_string(content_type))

    {:ok, headers, IO.iodata_to_binary(body)}
  rescue
    _exception -> {:error, :invalid_request}
  end

  defp request_parts(_request), do: {:error, :invalid_request}

  defp put_header_if_missing(headers, name, value) do
    if Enum.any?(headers, fn {key, _value} -> key == name end),
      do: headers,
      else: [{name, value} | headers]
  end
end
