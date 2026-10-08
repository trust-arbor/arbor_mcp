defmodule Arbor.MCP.Internal.PinnedHTTPClient do
  @moduledoc false

  alias Arbor.MCP.Internal.HTTPResponseReducer, as: Reducer

  @type response :: %{
          required(:status) => pos_integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => binary()
        }

  @type request_result :: {:ok, response()} | {:error, :fetch_failed | :response_too_large}

  @spec get(URI.t(), :inet.ip_address(), keyword()) :: request_result()
  def get(%URI{} = uri, address, opts) do
    scheme = String.to_existing_atom(uri.scheme)
    port = uri.port || Reducer.default_port(scheme)
    timeout = opts[:request_timeout_ms]
    max_bytes = opts[:max_response_bytes]

    connect_opts = [
      hostname: uri.host,
      mode: :passive,
      transport_opts: transport_opts(address, opts)
    ]

    pinned_address = address |> :inet.ntoa() |> to_string()

    case Mint.HTTP1.connect(scheme, pinned_address, port, connect_opts) do
      {:ok, conn} -> request_and_receive(conn, uri, opts[:request_headers], timeout, max_bytes)
      {:error, _reason} -> {:error, :fetch_failed}
    end
  rescue
    _exception -> {:error, :fetch_failed}
  catch
    _kind, _reason -> {:error, :fetch_failed}
  end

  @spec request_and_receive(
          Mint.HTTP1.t(),
          URI.t(),
          Mint.Types.headers(),
          non_neg_integer(),
          pos_integer()
        ) :: request_result()
  defp request_and_receive(conn, uri, headers, timeout, max_bytes) do
    result =
      case Mint.HTTP1.request(conn, "GET", Reducer.request_target(uri), headers, nil) do
        {:ok, next_conn, request_ref} ->
          deadline = System.monotonic_time(:millisecond) + timeout
          limits = [max_bytes: max_bytes, validate_headers: header_policy(max_bytes)]
          receive_response(next_conn, request_ref, Reducer.empty_response(), deadline, limits)

        {:error, _conn, _reason} ->
          {:error, :fetch_failed}
      end

    _ = Mint.HTTP1.close(conn)
    result
  end

  defp receive_response(conn, request_ref, response, deadline, limits) do
    timeout = Reducer.remaining_ms(deadline, System.monotonic_time(:millisecond))

    case Mint.HTTP1.recv(conn, 0, timeout) do
      {:ok, next_conn, events} ->
        case Reducer.reduce(events, request_ref, response, limits) do
          {:done, completed} ->
            {:ok,
             %{
               status: completed.status,
               headers: completed.headers,
               body: Reducer.body(completed)
             }}

          {:cont, updated} ->
            receive_response(next_conn, request_ref, updated, deadline, limits)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _next_conn, _reason, _events} ->
        {:error, :fetch_failed}
    end
  end

  # Lenient check applied to each header batch on its own; compression is
  # not rejected here because callers send accept-encoding: identity.
  defp header_policy(max_bytes) do
    fn batch, _accumulated ->
      if Reducer.content_length_too_large?(batch, max_bytes),
        do: {:error, :response_too_large},
        else: :ok
    end
  end

  defp transport_opts(address, opts) do
    [{:timeout, opts[:connect_timeout_ms]} | Reducer.address_family_options(address)]
  end
end
