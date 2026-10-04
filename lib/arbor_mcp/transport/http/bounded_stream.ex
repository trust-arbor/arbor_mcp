defmodule Arbor.MCP.Transport.HTTP.BoundedStream do
  @moduledoc false

  alias Arbor.MCP.Transport.HTTP.TargetPolicy

  @default_max_header_bytes 65_536
  @default_delivery_timeout 6_000

  @type event ::
          {:stream_start, non_neg_integer(), [{String.t(), String.t()}]}
          | {:stream, binary()}
          | {:stream_end, [{String.t(), String.t()}]}
          | {:complete, non_neg_integer(), [{String.t(), String.t()}], binary()}
          | {:error, term()}

  @spec start(pid(), atom(), String.t(), list(), binary() | nil, keyword()) ::
          {:ok, pid()} | {:error, atom()}
  def start(owner, method, url, headers, body, opts)
      when is_pid(owner) and method in [:get, :post] and is_binary(url) and is_list(headers) and
             (is_binary(body) or is_nil(body)) and is_list(opts) do
    with {:ok, uri, address} <- TargetPolicy.resolve(url, opts) do
      pid =
        Arbor.MCP.Client.ConnectionScope.spawn_link(fn ->
          run(owner, method, uri, address, headers, body, opts)
        end)

      {:ok, pid}
    end
  end

  @spec ack(pid(), pid()) :: :ok
  def ack(worker, owner \\ self()) when is_pid(worker) and is_pid(owner) do
    send(worker, {:bounded_stream_ack, owner})
    :ok
  end

  @spec cancel(pid() | nil) :: :ok
  def cancel(nil), do: :ok

  def cancel(worker) when is_pid(worker) do
    Process.unlink(worker)

    if Process.alive?(worker) do
      Process.exit(worker, :shutdown)
    end

    :ok
  end

  defp run(owner, method, uri, address, headers, body, opts) do
    result =
      with {:ok, conn} <- connect(uri, address, opts),
           {:ok, conn, request_ref} <-
             Mint.HTTP1.request(
               conn,
               method_name(method),
               request_target(uri),
               headers |> normalize_headers() |> delete_header("host"),
               body
             ) do
        response = %{
          status: nil,
          reason: "",
          headers: [],
          mode: nil,
          chunks: [],
          size: 0
        }

        receive_response(conn, request_ref, response, owner, opts)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> send(owner, {:bounded_http, self(), {:error, reason}})
    end
  rescue
    _exception -> send(owner, {:bounded_http, self(), {:error, :request_failed}})
  catch
    _kind, _reason -> send(owner, {:bounded_http, self(), {:error, :request_failed}})
  end

  defp connect(uri, address, opts) do
    scheme = String.to_existing_atom(uri.scheme)
    port = uri.port || default_port(scheme)
    pinned_address = address |> :inet.ntoa() |> to_string()

    transport_opts =
      opts
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put(:timeout, Keyword.fetch!(opts, :connect_timeout))
      |> Keyword.merge(address_family_options(address))

    Mint.HTTP1.connect(scheme, pinned_address, port,
      hostname: uri.host,
      mode: :passive,
      transport_opts: transport_opts,
      max_header_list_size: Keyword.get(opts, :max_header_bytes, @default_max_header_bytes),
      optional_responses: [:status_reason]
    )
  end

  defp receive_response(conn, request_ref, response, owner, opts) do
    case Mint.HTTP1.recv(conn, 0, :infinity) do
      {:ok, next_conn, events} ->
        case consume_events(events, request_ref, response, owner, opts) do
          {:more, updated} -> receive_response(next_conn, request_ref, updated, owner, opts)
          :done -> close(next_conn)
          {:error, reason} -> close(next_conn, reason)
        end

      {:error, next_conn, reason, events} ->
        case consume_events(events, request_ref, response, owner, opts) do
          :done -> close(next_conn)
          {:error, event_reason} -> close(next_conn, event_reason)
          {:more, _updated} -> close(next_conn, {:http_receive_failed, reason})
        end
    end
  end

  defp consume_events(events, request_ref, response, owner, opts) do
    Enum.reduce_while(events, {:more, response}, fn
      {:status, ^request_ref, status}, {:more, acc} ->
        {:cont, {:more, %{acc | status: status}}}

      {:status_reason, ^request_ref, reason}, {:more, acc} ->
        {:cont, {:more, %{acc | reason: reason}}}

      {:headers, ^request_ref, headers}, {:more, acc} ->
        headers = normalize_headers(headers)
        all_headers = acc.headers ++ headers
        mode = acc.mode || response_mode(acc.status, all_headers)

        case validate_headers(all_headers, mode, Keyword.fetch!(opts, :max_response_bytes)) do
          :ok ->
            updated = %{acc | headers: all_headers, mode: mode}

            if mode == :stream and is_nil(acc.mode) do
              case deliver(owner, {:stream_start, acc.status, headers}, opts) do
                :ok -> {:cont, {:more, updated}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            else
              {:cont, {:more, updated}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      {:data, ^request_ref, data}, {:more, %{mode: :stream} = acc} ->
        case deliver(owner, {:stream, data}, opts) do
          :ok -> {:cont, {:more, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:data, ^request_ref, data}, {:more, acc} ->
        size = acc.size + byte_size(data)

        if size > Keyword.fetch!(opts, :max_response_bytes) do
          {:halt, {:error, :response_too_large}}
        else
          {:cont, {:more, %{acc | chunks: [data | acc.chunks], size: size, mode: :bounded}}}
        end

      {:done, ^request_ref}, {:more, %{mode: :stream} = acc} ->
        send(owner, {:bounded_http, self(), {:stream_end, acc.headers}})
        {:halt, :done}

      {:done, ^request_ref}, {:more, %{status: status} = acc} when is_integer(status) ->
        body = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
        send(owner, {:bounded_http, self(), {:complete, status, acc.headers, body}})
        {:halt, :done}

      {:done, ^request_ref}, {:more, _acc} ->
        {:halt, {:error, :invalid_response}}

      _event, result ->
        {:cont, result}
    end)
  end

  defp response_mode(status, headers) do
    content_type = header_value(headers, "content-type") || ""

    if status in 200..299 and
         String.starts_with?(String.downcase(String.trim(content_type)), "text/event-stream") do
      :stream
    else
      :bounded
    end
  end

  defp validate_headers(headers, mode, max_response_bytes) do
    cond do
      compressed?(headers) ->
        {:error, :compressed_response}

      conflicting_framing?(headers) ->
        {:error, :invalid_response_framing}

      mode == :bounded and invalid_or_oversized_content_length?(headers, max_response_bytes) ->
        {:error, :response_too_large}

      true ->
        :ok
    end
  end

  defp invalid_or_oversized_content_length?(headers, max_bytes) do
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

  defp compressed?(headers) do
    Enum.any?(headers, fn
      {"content-encoding", value} -> String.downcase(String.trim(value)) not in ["", "identity"]
      _header -> false
    end)
  end

  defp conflicting_framing?(headers) do
    Enum.any?(headers, &(elem(&1, 0) == "content-length")) and
      Enum.any?(headers, &(elem(&1, 0) == "transfer-encoding"))
  end

  defp deliver(owner, event, opts) do
    send(owner, {:bounded_http, self(), event})

    receive do
      {:bounded_stream_ack, ^owner} -> :ok
    after
      Keyword.get(opts, :delivery_timeout, @default_delivery_timeout) ->
        {:error, :stream_consumer_timeout}
    end
  end

  defp close(conn) do
    _ = Mint.HTTP1.close(conn)
    :ok
  end

  defp close(conn, reason) do
    _ = Mint.HTTP1.close(conn)
    {:error, reason}
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp delete_header(headers, name), do: Enum.reject(headers, &(elem(&1, 0) == name))

  defp header_value(headers, wanted) do
    Enum.find_value(headers, fn
      {^wanted, value} -> value
      _header -> nil
    end)
  end

  defp request_target(%URI{path: path, query: nil}), do: path_or_root(path)
  defp request_target(%URI{path: path, query: query}), do: path_or_root(path) <> "?" <> query
  defp path_or_root(path) when path in [nil, ""], do: "/"
  defp path_or_root(path), do: path

  defp method_name(method), do: method |> Atom.to_string() |> String.upcase()

  defp address_family_options(address) when tuple_size(address) == 8,
    do: [inet4: false, inet6: true]

  defp address_family_options(_address), do: [inet4: true, inet6: false]
  defp default_port(:http), do: 80
  defp default_port(:https), do: 443
end
