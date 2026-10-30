defmodule Arbor.MCP.Transport.HTTP.ModernStreamClient do
  @moduledoc false

  use GenServer

  alias Arbor.MCP.Client.{ConnectionScope, Deadline, Diagnostics, Lifetime}
  alias Arbor.MCP.Internal.{Headers, SSE}
  alias Arbor.MCP.Transport.HTTP.BoundedStream

  @httpc_profiles [
    :ex_mcp_modern_stream_0,
    :ex_mcp_modern_stream_1,
    :ex_mcp_modern_stream_2,
    :ex_mcp_modern_stream_3,
    :ex_mcp_modern_stream_4,
    :ex_mcp_modern_stream_5,
    :ex_mcp_modern_stream_6,
    :ex_mcp_modern_stream_7,
    :ex_mcp_modern_stream_8,
    :ex_mcp_modern_stream_9,
    :ex_mcp_modern_stream_10,
    :ex_mcp_modern_stream_11,
    :ex_mcp_modern_stream_12,
    :ex_mcp_modern_stream_13,
    :ex_mcp_modern_stream_14,
    :ex_mcp_modern_stream_15
  ]

  # Request headers and the auth provider's state carry the connection's
  # credentials, the body the request's arguments, and the HTTP options TLS
  # settings: none is printed, and format_status/1 keeps them out of crash
  # reports too.
  # How long a stream waits for the client to answer its auth challenge. A
  # browser flow can take minutes; the caller's own timeout cancels the
  # stream sooner, and a dead client is noticed through the parent monitor,
  # so this only bounds a lost answer.
  @auth_wait_ms 600_000

  @derive {Inspect,
           except: [:headers, :body, :http_options, :auth_provider_state, :auth_response]}
  defstruct [
    :parent,
    :parent_monitor,
    :request_id,
    :deadline,
    :stream_kind,
    :url,
    :headers,
    :body,
    :http_options,
    :httpc_profile,
    :request_ref,
    :handshake_timeout,
    :handshake_timer,
    :idle_timeout,
    :idle_timer,
    :max_response_bytes,
    :max_buffer_bytes,
    :auth_provider,
    :auth_provider_state,
    :header_sanitizer,
    :consumer_ack_timeout,
    # {ref, timer} while the client process answers an auth challenge.
    :auth_wait,
    :auth_response,
    credential_generation: 0,
    auth_attempts: 0,
    buffer: "",
    completed?: false,
    failed?: false,
    cancelled?: false,
    close_notified?: false
  ]

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts),
    do: ConnectionScope.start_process(__MODULE__, opts, :unlinked)

  @spec cancel(pid(), integer()) :: :ok | {:error, term()}
  def cancel(pid, deadline \\ Deadline.after_ms(1_000)) do
    Lifetime.native_stop(
      pid,
      __MODULE__,
      fn timeout -> GenServer.call(pid, :cancel, timeout) end,
      deadline
    )
  end

  @doc false
  @spec handshake_timer_active?(pid()) :: boolean()
  def handshake_timer_active?(pid), do: GenServer.call(pid, :handshake_timer_active?)

  def child_spec(opts), do: Diagnostics.child_spec(super(opts))

  @impl true
  def init(constructor) when is_function(constructor, 0), do: init(constructor.())

  def init(opts), do: Diagnostics.initialize(fn -> initialize_owner(opts) end)

  defp initialize_owner(opts) do
    :ok =
      ConnectionScope.register_process(
        Keyword.get(opts, :_connection_scope),
        Keyword.get(opts, :_client_lifetime),
        Keyword.get(opts, :_client_lifetime_deadline, Deadline.after_ms(1_000))
      )

    parent = Keyword.fetch!(opts, :parent)
    Process.put({Lifetime, :native_parent}, parent)
    profile = httpc_profile()
    ensure_httpc_profile!(profile)

    state = %__MODULE__{
      parent: parent,
      parent_monitor: Process.monitor(parent),
      request_id: Keyword.fetch!(opts, :request_id),
      deadline: Keyword.get(opts, :deadline),
      credential_generation: Keyword.get(opts, :credential_generation, 0),
      stream_kind: Keyword.fetch!(opts, :stream_kind),
      url: Keyword.fetch!(opts, :url),
      headers: Keyword.fetch!(opts, :headers),
      body: Keyword.fetch!(opts, :body),
      http_options: Keyword.fetch!(opts, :http_options),
      httpc_profile: profile,
      handshake_timeout: Keyword.fetch!(opts, :handshake_timeout),
      idle_timeout: Keyword.fetch!(opts, :idle_timeout),
      max_response_bytes: Keyword.fetch!(opts, :max_response_bytes),
      max_buffer_bytes: Keyword.fetch!(opts, :max_buffer_bytes),
      auth_provider: Keyword.get(opts, :auth_provider),
      auth_provider_state: Keyword.get(opts, :auth_provider_state),
      header_sanitizer: Keyword.get(opts, :header_sanitizer),
      consumer_ack_timeout: positive_limit(Keyword.get(opts, :consumer_ack_timeout), 5_000)
    }

    {:ok, state, {:continue, :open}}
  end

  # A request whose connection never opened closes with
  # {:connect_failed, reason}, as BoundedStream reports it: its address
  # didn't resolve or wasn't permitted (here), or the connection was refused
  # or its trust store unavailable (later). Nothing of it was written, so the
  # client reports it as not sent.
  @impl true
  def handle_continue(:open, state) do
    case open_request(state) do
      {:ok, request_ref} ->
        {:noreply, state |> Map.put(:request_ref, request_ref) |> reset_handshake_timer()}

      {:error, reason} ->
        {:stop, :normal, notify_closed(state, {:connect_failed, reason})}
    end
  end

  @impl true
  def handle_call(:handshake_timer_active?, _from, state) do
    {:reply, is_reference(state.handshake_timer), state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    cancel_request(state)
    {:stop, :normal, :ok, %{state | cancelled?: true}}
  end

  @impl true
  def handle_info(
        {:bounded_http, ref, {:stream_start, _status, _headers}},
        %{request_ref: ref} = state
      ) do
    BoundedStream.ack(ref)
    {:noreply, state |> cancel_handshake_timer() |> reset_idle_timer()}
  end

  def handle_info({:bounded_http, ref, {:stream, chunk}}, %{request_ref: ref} = state) do
    case append_chunk(state.buffer, chunk, state.max_buffer_bytes) do
      {:ok, buffer} ->
        {events, remaining} = SSE.parse_stream(buffer)

        state =
          if events != [] or complete_sse_frame?(buffer),
            do: reset_idle_timer(state),
            else: state

        state =
          Enum.reduce_while(events, %{state | buffer: remaining}, fn event, acc ->
            state = deliver_event(event, acc)

            if state.completed? or state.failed?, do: {:halt, state}, else: {:cont, state}
          end)

        cond do
          state.completed? ->
            cancel_request(state)

            Lifetime.deliver(
              state.parent,
              {:modern_http_stream_finished, self(), state.request_id}
            )

            {:stop, :normal, cancel_idle_timer(state)}

          state.failed? ->
            cancel_request(state)
            {:stop, :normal, cancel_idle_timer(state)}

          true ->
            BoundedStream.ack(ref)
            {:noreply, state}
        end

      {:error, :stream_buffer_limit_exceeded} ->
        cancel_request(state)

        {:stop, :normal,
         state
         |> cancel_idle_timer()
         |> notify_closed(:stream_buffer_limit_exceeded)}
    end
  end

  def handle_info(
        {:bounded_http, ref, {:stream_end, _headers}},
        %{request_ref: ref} = state
      ) do
    state = state |> cancel_handshake_timer() |> cancel_idle_timer()

    if state.completed? do
      Lifetime.deliver(state.parent, {:modern_http_stream_finished, self(), state.request_id})
      {:stop, :normal, state}
    else
      {:stop, :normal, notify_closed(state, :stream_ended)}
    end
  end

  def handle_info(
        {:bounded_http, ref, {:complete, status, headers, body}},
        %{request_ref: ref} = state
      ) do
    state = state |> cancel_handshake_timer() |> cancel_idle_timer()
    body = to_binary(body)

    if status == 401 do
      Lifetime.deliver(
        state.parent,
        {:http_credential_rejected, :stream, self(), state.request_id,
         state.credential_generation}
      )
    end

    if byte_size(body) > state.max_response_bytes do
      {:stop, :normal, notify_closed(state, :response_too_large)}
    else
      handle_complete_http_response(status, headers, body, state)
    end
  end

  def handle_info({:bounded_http, ref, {:error, reason}}, %{request_ref: ref} = state) do
    {:stop, :normal,
     state
     |> cancel_handshake_timer()
     |> cancel_idle_timer()
     |> notify_closed(close_reason(reason, state))}
  end

  def handle_info(:handshake_timeout, %{request_ref: ref} = state) when not is_nil(ref) do
    cancel_request(state)

    {:stop, :normal,
     state
     |> Map.put(:handshake_timer, nil)
     |> cancel_idle_timer()
     |> notify_closed(:stream_handshake_timeout)}
  end

  def handle_info(:handshake_timeout, state), do: {:noreply, state}

  def handle_info(
        {:modern_http_stream_auth_result, ref, result},
        %{auth_wait: {ref, timer}} = state
      ) do
    Process.cancel_timer(timer, async: false, info: false)
    retry_with_auth(result, %{state | auth_wait: nil})
  end

  # An answer after the wait timed out, or for an earlier challenge.
  def handle_info({:modern_http_stream_auth_result, _ref, _result}, state),
    do: {:noreply, state}

  def handle_info({:auth_timeout, ref}, %{auth_wait: {ref, _timer}} = state),
    do: {:stop, :normal, notify_closed(%{state | auth_wait: nil}, {:auth_refused, :timeout})}

  def handle_info({:auth_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(:idle_timeout, state) do
    cancel_request(state)
    {:stop, :normal, notify_closed(state, :stream_idle_timeout)}
  end

  def handle_info(
        {:DOWN, ref, :process, parent, _reason},
        %{parent_monitor: ref, parent: parent} = state
      ) do
    cancel_request(state)
    {:stop, :normal, %{state | cancelled?: true}}
  end

  @impl true
  def format_status(status), do: Diagnostics.format_status(status, __MODULE__)

  @impl true
  def terminate(_reason, state) do
    cancel_handshake_timer(state)
    cancel_idle_timer(state)

    unless state.cancelled? or state.completed? or state.close_notified? do
      Lifetime.deliver(
        state.parent,
        {:modern_http_stream_closed, self(), state.request_id, :stream_stopped}
      )
    end

    :ok
  end

  defp handle_complete_http_response(status, headers, body, state) do
    state = %{state | auth_response: {status, headers, body}}

    case maybe_retry_with_auth(status, headers, state) do
      {:await_auth, state} ->
        {:noreply, state}

      :no_retry ->
        state = handle_complete_response(status, body, state)

        if state.completed? do
          Lifetime.deliver(state.parent, {:modern_http_stream_finished, self(), state.request_id})
        end

        {:stop, :normal, state}
    end
  end

  defp open_request(state) do
    headers =
      state.headers
      |> put_header_if_missing("content-type", "application/json")
      |> put_header_if_missing("accept-encoding", "identity")

    BoundedStream.start(
      self(),
      :post,
      state.url,
      headers,
      state.body,
      connect_timeout: Keyword.get(state.http_options, :connect_timeout, state.handshake_timeout),
      transport_opts: Keyword.get(state.http_options, :ssl, []),
      max_response_bytes: state.max_response_bytes,
      auth_headers_only: true,
      delivery_timeout: state.consumer_ack_timeout + 1_000,
      dns_timeout_ms: Keyword.get(state.http_options, :dns_timeout_ms, 1_000),
      dns_resolver:
        Keyword.get(state.http_options, :dns_resolver, Arbor.MCP.Internal.DNSResolver),
      allowed_private_hosts: Keyword.get(state.http_options, :allowed_private_hosts, [])
    )
  end

  defp deliver_event(%{"data" => data}, state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, message} ->
        handle_stream_message(message, state)

      {:error, _reason} ->
        state
        |> notify_closed(:invalid_sse_json)
        |> Map.put(:failed?, true)
    end
  end

  defp deliver_event(_comment_or_empty_event, state), do: state

  defp handle_stream_message(message, state) do
    case validate_message(message, state.request_id, state.stream_kind) do
      :ok ->
        case deliver_message(message, state) do
          :ok ->
            if final_response?(message),
              do: %{state | completed?: true},
              else: state

          {:error, reason} ->
            state
            |> notify_closed(reason)
            |> Map.put(:failed?, true)
        end

      {:error, reason} ->
        state
        |> notify_closed(reason)
        |> Map.put(:failed?, true)
    end
  end

  defp deliver_message(message, state) do
    Lifetime.deliver(
      state.parent,
      {:modern_http_stream_message, self(), state.request_id, message}
    )

    receive do
      {:modern_http_stream_ack, parent, request_id}
      when parent == state.parent and request_id == state.request_id ->
        :ok

      {:DOWN, monitor, :process, parent, _reason}
      when monitor == state.parent_monitor and parent == state.parent ->
        {:error, :stream_consumer_closed}
    after
      state.consumer_ack_timeout -> {:error, :stream_consumer_timeout}
    end
  end

  defp handle_complete_response(status, body, state) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, message} ->
        case validate_message(message, state.request_id, state.stream_kind) do
          :ok ->
            if final_response?(message) do
              deliver_message(message, state)
              %{state | completed?: true}
            else
              notify_closed(state, :final_response_required)
            end

          {:error, reason} ->
            notify_closed(state, reason)
        end

      {:error, _reason} ->
        notify_closed(state, :invalid_sse_json)
    end
  end

  # A server answers a method it doesn't implement with 404 and a JSON-RPC
  # error for the request (2026-07-28 Streamable HTTP): that error is the
  # request's answer, as in a 200. Any other 404 is an HTTP error.
  defp handle_complete_response(404, body, state) do
    with {:ok, %{"error" => %{"code" => code, "message" => message}} = response}
         when is_integer(code) and is_binary(message) <- Jason.decode(body),
         :ok <- validate_message(response, state.request_id, state.stream_kind) do
      deliver_message(response, state)
      %{state | completed?: true}
    else
      _not_json_rpc -> notify_closed(state, {:http_error, 404})
    end
  end

  defp handle_complete_response(status, _body, state) do
    if status in [401, 403],
      do: notify_closed(state, {:auth_refused, auth_response_error(state)}),
      else: notify_closed(state, {:http_error, status})
  end

  # A POST-owned stream gets non-2xx responses as complete httpc responses,
  # rather than stream_start/stream_end messages. Retry at most the same two
  # challenge steps as the ordinary HTTP path: an initial 401 followed by an
  # optional 403 insufficient-scope step-up.
  #
  # The stream doesn't authenticate itself. With several streams open, each
  # would refresh, and a rotating refresh token used twice fails. The client
  # process answers every stream's challenges in turn and reuses a token
  # another stream already obtained, so the stream waits for its answer.
  defp maybe_retry_with_auth(status, response_headers, state)
       when status in [401, 403] and state.auth_attempts < 2 do
    www_auth = Headers.get(response_headers, "www-authenticate")
    ref = make_ref()

    challenge = %{
      status: status,
      www_authenticate: www_auth,
      scopes: extract_scopes(www_auth),
      token: bearer_token(state.headers),
      credential_generation: state.credential_generation,
      deadline: state.deadline
    }

    Lifetime.deliver(
      state.parent,
      {:modern_http_stream_auth_challenge, self(), state.request_id, ref, challenge}
    )

    wait =
      if state.deadline,
        do: min(Deadline.remaining(state.deadline), @auth_wait_ms),
        else: @auth_wait_ms

    timer = Process.send_after(self(), {:auth_timeout, ref}, wait)
    {:await_auth, %{state | request_ref: nil, auth_wait: {ref, timer}}}
  end

  defp maybe_retry_with_auth(_status, _response_headers, _state), do: :no_retry

  defp retry_with_auth({:ok, token, generation}, state) when is_binary(token) do
    retry_with_auth({:ok, token}, %{state | credential_generation: generation})
  end

  defp retry_with_auth({:ok, token}, state) when is_binary(token) do
    if Deadline.expired?(state.deadline),
      do: retry_with_auth({:error, :timeout}, state),
      else: retry_authenticated(token, state)
  end

  defp retry_with_auth({:error, reason}, state),
    do:
      {:stop, :normal, notify_closed(state, {:auth_refused, authentication_error(reason, state)})}

  defp retry_with_auth(other, state),
    do:
      {:stop, :normal,
       notify_closed(
         state,
         {:auth_refused, {:authentication_failed, {:invalid_provider_response, other}}}
       )}

  defp retry_authenticated(token, state) do
    case sanitize_retry_headers(put_bearer_header(state.headers, token), state) do
      {:ok, headers} ->
        state = %{
          state
          | headers: headers,
            auth_attempts: state.auth_attempts + 1,
            buffer: "",
            close_notified?: false,
            failed?: false,
            completed?: false
        }

        case open_request(state) do
          {:ok, request_ref} ->
            {:noreply, state |> Map.put(:request_ref, request_ref) |> reset_handshake_timer()}

          {:error, reason} ->
            {:stop, :normal, notify_closed(state, {:auth_retry_failed, reason})}
        end

      {:error, reason} ->
        {:stop, :normal,
         notify_closed(state, {:authentication_failed, {:security_policy_rejected, reason}})}
    end
  end

  defp authentication_error(:timeout, _state), do: :timeout

  defp authentication_error(:no_credentials, %{auth_provider: nil} = state),
    do: auth_response_error(state)

  defp authentication_error(reason, %{auth_provider: nil}), do: reason
  defp authentication_error(reason, _state), do: {:authentication_failed, reason}

  defp auth_response_error(%{auth_response: {401, headers, body}}),
    do: {:unauthorized, 401, body, Headers.get(headers, "www-authenticate")}

  defp auth_response_error(%{auth_response: {status, _headers, body}}),
    do: {:http_error, status, body}

  defp bearer_token(headers) do
    case Headers.get(headers, "authorization") do
      "Bearer " <> token -> token
      _none -> nil
    end
  end

  defp sanitize_retry_headers(headers, %{header_sanitizer: sanitizer})
       when is_function(sanitizer, 1) do
    sanitizer.(headers)
  rescue
    _exception -> {:error, :header_sanitizer_failed}
  catch
    _kind, _reason -> {:error, :header_sanitizer_failed}
  end

  defp sanitize_retry_headers(_headers, _state), do: {:error, :header_sanitizer_missing}

  defp extract_scopes(www_auth) when is_binary(www_auth) do
    case Regex.run(~r/scope="([^"]+)"/, www_auth) do
      [_, scopes] -> String.split(scopes, " ", trim: true)
      _other -> []
    end
  end

  defp extract_scopes(_www_auth), do: []

  defp put_bearer_header(headers, token) do
    headers
    |> Headers.delete("authorization")
    |> List.insert_at(0, {"Authorization", "Bearer #{token}"})
  end

  defp reset_idle_timer(state) do
    state = cancel_idle_timer(state)
    %{state | idle_timer: Process.send_after(self(), :idle_timeout, state.idle_timeout)}
  end

  defp reset_handshake_timer(state) do
    state = cancel_handshake_timer(state)

    %{
      state
      | handshake_timer: Process.send_after(self(), :handshake_timeout, state.handshake_timeout)
    }
  end

  defp cancel_handshake_timer(%{handshake_timer: nil} = state), do: state

  defp cancel_handshake_timer(state) do
    Process.cancel_timer(state.handshake_timer, async: false, info: false)
    %{state | handshake_timer: nil}
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(state) do
    Process.cancel_timer(state.idle_timer, async: false, info: false)
    %{state | idle_timer: nil}
  end

  defp cancel_request(%{request_ref: nil}), do: :ok

  defp cancel_request(state) do
    BoundedStream.cancel(state.request_ref)
  end

  # Only the first attempt's connection failure means the request was never
  # sent: a re-send after an auth challenge follows a request the server
  # answered, so its failure to connect is reported as the bare reason.
  defp close_reason({:connect_failed, reason}, %{auth_attempts: attempts}) when attempts > 0,
    do: reason

  defp close_reason(reason, _state), do: reason

  defp notify_closed(%{close_notified?: true} = state, _reason), do: state

  defp notify_closed(state, reason) do
    Lifetime.deliver(state.parent, {:modern_http_stream_closed, self(), state.request_id, reason})
    %{state | close_notified?: true}
  end

  @doc false
  @spec validate_message(map(), Arbor.MCP.Types.request_id(), :request | :subscription) ::
          :ok | {:error, atom()}
  def validate_message(message, request_id, stream_kind) when is_map(message) do
    cond do
      final_response?(message) ->
        if Map.get(message, "id") == request_id,
          do: :ok,
          else: {:error, :response_id_mismatch}

      notification?(message) and allowed_notification?(message["method"], stream_kind) ->
        :ok

      true ->
        {:error, :invalid_stream_message}
    end
  end

  def validate_message(_message, _request_id, _stream_kind),
    do: {:error, :invalid_stream_message}

  defp final_response?(%{"jsonrpc" => "2.0", "id" => _id} = message) do
    not Map.has_key?(message, "method") and
      Map.has_key?(message, "result") != Map.has_key?(message, "error")
  end

  defp final_response?(_message), do: false

  defp notification?(%{"jsonrpc" => "2.0", "method" => method} = message)
       when is_binary(method) do
    not Map.has_key?(message, "id") and not Map.has_key?(message, "result") and
      not Map.has_key?(message, "error")
  end

  defp notification?(_message), do: false

  defp allowed_notification?(method, :request),
    do: method in ["notifications/progress", "notifications/message"]

  defp allowed_notification?(method, :subscription) do
    method in [
      "notifications/subscriptions/acknowledged",
      "notifications/tools/list_changed",
      "notifications/prompts/list_changed",
      "notifications/resources/list_changed",
      "notifications/resources/updated",
      "notifications/tasks"
    ]
  end

  defp allowed_notification?(_method, _stream_kind), do: false

  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value) when is_list(value), do: List.to_string(value)

  @doc false
  @spec append_chunk(binary(), iodata(), pos_integer()) ::
          {:ok, binary()} | {:error, :stream_buffer_limit_exceeded}
  def append_chunk(buffer, chunk, max_bytes)
      when is_binary(buffer) and is_integer(max_bytes) and max_bytes > 0 do
    chunk = to_binary(chunk)

    if byte_size(buffer) + byte_size(chunk) <= max_bytes,
      do: {:ok, buffer <> chunk},
      else: {:error, :stream_buffer_limit_exceeded}
  end

  defp complete_sse_frame?(buffer) do
    String.contains?(buffer, "\n\n") or String.contains?(buffer, "\r\r") or
      String.contains?(buffer, "\r\n\r\n")
  end

  defp put_header_if_missing(headers, name, value) do
    if Enum.any?(headers, fn {key, _value} -> String.downcase(to_string(key)) == name end),
      do: headers,
      else: [{name, value} | headers]
  end

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp httpc_profile do
    index = rem(:erlang.unique_integer([:positive, :monotonic]), length(@httpc_profiles))
    Enum.at(@httpc_profiles, index)
  end

  defp ensure_httpc_profile!(profile) do
    case :inets.start(:httpc, [{:profile, profile}]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
