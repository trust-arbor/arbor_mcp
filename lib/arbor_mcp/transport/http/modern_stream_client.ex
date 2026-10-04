defmodule Arbor.MCP.Transport.HTTP.ModernStreamClient do
  @moduledoc false

  use GenServer

  alias Arbor.MCP.Client.{ConnectionScope, Deadline, Lifetime}
  alias Arbor.MCP.Internal.{Headers, Redaction, SSE}
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
  @derive {Inspect, except: [:headers, :body, :http_options, :auth_provider_state]}
  defstruct [
    :parent,
    :parent_monitor,
    :request_id,
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

  @impl true
  def init(opts) do
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

  @impl true
  def handle_continue(:open, state) do
    case open_request(state) do
      {:ok, request_ref} ->
        {:noreply, state |> Map.put(:request_ref, request_ref) |> reset_handshake_timer()}

      {:error, reason} ->
        {:stop, :normal, notify_closed(state, reason)}
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

    if byte_size(body) > state.max_response_bytes do
      {:stop, :normal, notify_closed(state, :response_too_large)}
    else
      handle_complete_http_response(status, headers, body, state)
    end
  end

  def handle_info({:bounded_http, ref, {:error, reason}}, %{request_ref: ref} = state) do
    {:stop, :normal,
     state |> cancel_handshake_timer() |> cancel_idle_timer() |> notify_closed(reason)}
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
  def format_status(status) do
    Redaction.status(status, fn
      %__MODULE__{} = state ->
        %{
          state
          | headers: Redaction.headers(state.headers),
            body: Redaction.secret(state.body),
            http_options: Redaction.secret(state.http_options),
            auth_provider_state: Redaction.secret(state.auth_provider_state)
        }

      state ->
        state
    end)
  end

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
    case maybe_retry_with_auth(status, headers, state) do
      {:retry, state} ->
        case open_request(%{state | request_ref: nil}) do
          {:ok, request_ref} ->
            {:noreply, state |> Map.put(:request_ref, request_ref) |> reset_handshake_timer()}

          {:error, reason} ->
            {:stop, :normal, notify_closed(state, {:auth_retry_failed, reason})}
        end

      :no_retry ->
        state = handle_complete_response(status, body, state)

        if state.completed? do
          Lifetime.deliver(state.parent, {:modern_http_stream_finished, self(), state.request_id})
        end

        {:stop, :normal, state}

      {:error, reason, state} ->
        {:stop, :normal, notify_closed(state, {:authentication_failed, reason})}
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

  defp handle_complete_response(status, _body, state) do
    notify_closed(state, {:http_error, status})
  end

  # A POST-owned stream gets non-2xx responses as complete httpc responses,
  # rather than stream_start/stream_end messages. Retry at most the same two
  # challenge steps as the ordinary HTTP path: an initial 401 followed by an
  # optional 403 insufficient-scope step-up.
  defp maybe_retry_with_auth(status, response_headers, state)
       when status in [401, 403] and not is_nil(state.auth_provider) and
              state.auth_attempts < 2 do
    callback = if status == 401, do: :handle_unauthorized, else: :handle_forbidden
    www_auth = Headers.get(response_headers, "www-authenticate")
    scopes = extract_scopes(www_auth)

    case apply(state.auth_provider, callback, [www_auth, scopes, state.auth_provider_state]) do
      {:ok, token, provider_state} when is_binary(token) ->
        case sanitize_retry_headers(put_bearer_header(state.headers, token), state) do
          {:ok, headers} ->
            Lifetime.deliver(
              state.parent,
              {:modern_http_stream_auth_updated, self(), state.request_id,
               %{access_token: token, auth_provider_state: provider_state}}
            )

            {:retry,
             %{
               state
               | headers: headers,
                 auth_provider_state: provider_state,
                 auth_attempts: state.auth_attempts + 1,
                 buffer: "",
                 close_notified?: false,
                 failed?: false,
                 completed?: false
             }}

          {:error, reason} ->
            {:error, {:security_policy_rejected, reason}, state}
        end

      {:error, reason, _provider_state} ->
        {:error, reason, state}

      other ->
        {:error, {:invalid_provider_response, other}, state}
    end
  end

  defp maybe_retry_with_auth(_status, _response_headers, _state), do: :no_retry

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
