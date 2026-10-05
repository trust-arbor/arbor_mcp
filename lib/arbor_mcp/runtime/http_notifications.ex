defmodule Arbor.MCP.Server.Runtime.HTTPNotifications do
  @moduledoc false

  alias Arbor.MCP.Internal.Protocol
  alias Arbor.MCP.Server.{Context, Subscriptions}
  alias Arbor.MCP.Server.Runtime

  alias Arbor.MCP.Server.Runtime.{
    HTTPNotificationTarget,
    HTTPWriterProxy,
    HTTPWriterRegistry,
    ServiceOperation,
    ServiceRef
  }

  alias Arbor.MCP.Server.Runtime.HTTPResources.Source
  alias Arbor.MCP.SessionManager.SessionLease

  @topic_methods ~w(notifications/resources/updated notifications/resources/list_changed notifications/tools/list_changed notifications/prompts/list_changed)

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
