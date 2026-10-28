defmodule Arbor.MCP.Server.Runtime.HTTPNotifications do
  @moduledoc false

  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.{Context, Subscriptions}
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    Deadline,
    HTTPNotificationTarget,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    ServiceOperation,
    ServiceRef
  }

  alias Arbor.MCP.Server.Runtime.HTTPResources.Source
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.SessionLease

  @topic_methods ~w(notifications/resources/updated notifications/resources/list_changed notifications/tools/list_changed notifications/prompts/list_changed)
  @list_changes ~w(notifications/resources/list_changed notifications/tools/list_changed notifications/prompts/list_changed)
  @broadcast_ms 1_000

  # Native helpers retain their original edge path. An actual HTTP callback
  # cannot silently route through a different runtime's singleton peer.
  def cast(server, control) do
    with {:ok, source} <- Source.capture(),
         {:ok, runtime} <- Runtime.ref(server),
         true <- runtime == Source.runtime(source),
         {:ok, message} <- notification(control) do
      cast_source(source, message)
    else
      {:error, reason} when reason in [:not_http_request, :no_request_context] ->
        :not_http_request

      false ->
        {:error, :wrong_runtime}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  # An HTTP runtime has no edge process to send through. Outside a request,
  # list changes go to its subscriptions/listen streams, under the service's
  # publication rules, and to every legacy session with an open GET stream.
  # `:ok` means each of them took the change: every matching subscription
  # queued it and each open session stream's replay stored it, for those
  # streams to write out. A modern publication error comes first; otherwise
  # `{:error, :partially_delivered}` says some subscription or open session
  # didn't take it.
  def publish(runtime, control) do
    with {:ok, %{"method" => method, "params" => params} = message} <- notification(control),
         true <- method in @topic_methods do
      modern = publish_subscriptions(runtime, method, params)
      legacy = if method in @list_changes, do: broadcast_sessions(runtime, message), else: :ok
      if modern == :ok, do: legacy, else: modern
    else
      false -> {:error, :unsupported_http_control}
      {:error, _reason} = error -> error
    end
  end

  # Every matching subscription has to take the change, queued or merged
  # with one already queued; one that was closed or refused it didn't.
  defp publish_subscriptions(runtime, method, params) do
    with {:ok, service} <- Runtime.service(runtime, :subscriptions) do
      case Subscriptions.publish(method, params, service: service) do
        %{} = counts ->
          taken = Map.get(counts, :enqueued, 0) + Map.get(counts, :coalesced, 0)

          if taken >= Map.get(counts, :subscribers, 0),
            do: :ok,
            else: {:error, :partially_delivered}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        _rejected ->
          {:error, :publication_rejected}
      end
    end
  end

  # A legacy Streamable HTTP session has no subscriptions/listen stream: a
  # list change reaches it on its GET stream, through the session's replay,
  # which the stream drains on its own. The change carries no data, only
  # "refetch", and each session's refetch is authorized on its own, so every
  # session may get it. Only sessions whose GET stream is open now get it;
  # the others, including one whose stream is closed until its client opens
  # it again, are skipped rather than queued. Each append is bounded by the
  # session's replay limits and all of them by one deadline. A stream that
  # reads slowly or has died only fills or loses its own replay, so it holds
  # up neither the other sessions nor the caller.
  defp broadcast_sessions(runtime, message) do
    deadline = Deadline.after_ms(@broadcast_ms)

    with {:ok, domain} <- HTTPWriterProxy.domain(runtime),
         {:ok, leases} <- HTTPWriterRegistry.session_stream_leases(domain) do
      service = ServiceRef.new(runtime, :sessions)

      Enum.reduce(leases, :ok, fn lease, result ->
        case append_change(service, lease, message, deadline) do
          :ok -> result
          {:error, _reason} -> {:error, :partially_delivered}
        end
      end)
    else
      # No HTTP writer, so no session has a stream to miss the change.
      _unavailable -> :ok
    end
  end

  defp append_change(service, lease, message, deadline) do
    if Deadline.remaining(deadline) > 0 do
      case SessionManager.append_event(service, lease, "message", message, deadline: deadline) do
        {:ok, _event} -> :ok
        # The session ended after it was listed: it has no stream to miss it.
        {:error, reason} when reason in [:stale_session_lease, :session_not_found] -> :ok
        {:error, _reason} = error -> error
      end
    else
      {:error, :operation_timeout}
    end
  end

  def deliver(runtime, lease, message) do
    with {:ok, source} <- Source.capture(),
         true <- Source.runtime(source) == runtime and Source.lease(source) == lease do
      append(source, message)
    else
      _invalid -> {:error, :stream_closed}
    end
  end

  # The same actual Task performs the service operation. Store validates its
  # protected producer row again at mutation; no actor impersonation or relay.
  def append(source, message) do
    with true <- Source.current?(source),
         lease when not is_nil(lease) <- Source.lease(source),
         {:ok, domain} <- HTTPWriterProxy.domain(Source.runtime(source)),
         true <- HTTPWriterRegistry.session_delivery_active?(domain, lease, source),
         service = ServiceRef.new(Source.runtime(source), :sessions),
         {:ok, key} <- SessionLease.validate(lease, service, :sessions),
         {:ok, _event} <-
           ServiceOperation.call(
             service,
             :sessions,
             :http_callback_append,
             [key, message, source],
             deadline: Source.deadline(source)
           ) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _closed -> {:error, :stream_closed}
    end
  end

  defp cast_source(source, %{"method" => method, "params" => params} = message) do
    if is_nil(Source.lease(source)) and method in @topic_methods do
      publish_topic(source, method, params)
    else
      case Context.current() do
        %{notification_target: target} ->
          if HTTPNotificationTarget.target?(target),
            do: HTTPNotificationTarget.deliver(target, message),
            else: append(source, message)

        _missing ->
          {:error, :no_request_context}
      end
    end
  end

  defp publish_topic(source, method, params) do
    with {:ok, service} <- Runtime.service(Source.runtime(source), :subscriptions) do
      case Subscriptions.publish(method, params, service: service) do
        %{} -> :ok
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _rejected -> {:error, :publication_rejected}
      end
    end
  end

  defp notification({:notify_progress, token, progress, total}),
    do: {:ok, Protocol.encode_progress(token, progress, total)}

  defp notification({:send_log_message, level, text, data}),
    do:
      message("notifications/message", %{
        "level" => level,
        "logger" => "Arbor.MCP.Server",
        "message" => text,
        "data" => data || %{}
      })

  defp notification({:notify_resource_update, uri})
       when is_binary(uri) and byte_size(uri) in 1..4_096 do
    if String.valid?(uri),
      do: message("notifications/resources/updated", %{"uri" => uri}),
      else: {:error, :invalid_resource_uri}
  end

  defp notification({:notify_resource_update, _uri}), do: {:error, :invalid_resource_uri}

  defp notification({:notify_resources_changed}),
    do: message("notifications/resources/list_changed", %{})

  defp notification({:notify_tools_changed}), do: message("notifications/tools/list_changed", %{})

  defp notification({:notify_prompts_changed}),
    do: message("notifications/prompts/list_changed", %{})

  defp notification(:notify_roots_changed), do: message("notifications/roots/list_changed", %{})

  defp notification({:notification, "notifications/cancelled", params}),
    do: message("notifications/cancelled", params)

  defp notification(_unsupported), do: {:error, :unsupported_http_control}

  defp message(method, params),
    do: {:ok, %{"jsonrpc" => "2.0", "method" => method, "params" => params}}
end
