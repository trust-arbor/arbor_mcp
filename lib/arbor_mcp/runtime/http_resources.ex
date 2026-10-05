defmodule Arbor.MCP.Server.Runtime.HTTPResources do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{
    HTTPWriterProxy,
    HTTPWriterRegistry,
    ServiceOperation,
    ServiceRef
  }

  alias Arbor.MCP.Server.Runtime.HTTPResources.Source
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.SessionManager.SessionLease
  alias Arbor.MCP.SubscriptionRegistry

  @max_uri_bytes 4_096

  def track(method, uri) when method in ["resources/subscribe", "resources/unsubscribe"] do
    with :ok <- valid_uri(uri), {:ok, source} <- Source.capture() do
      case Source.lease(source) do
        nil -> {:error, :resource_session_required}
        lease -> track(source, lease, method, uri)
      end
    else
      {:error, reason} when reason in [:not_http_request, :no_request_context] -> :ok
      error -> error
    end
  end

  defp track(source, lease, method, uri) do
    service = ServiceRef.new(Source.runtime(source), :resource_subscriptions)
    operation = if method == "resources/subscribe", do: :http_subscribe, else: :http_unsubscribe

    ServiceOperation.call(
      service,
      :resource_subscriptions,
      operation,
      [service, lease, uri, source],
      deadline: Source.deadline(source)
    )
  end

  def broadcast(uri) do
    with :ok <- valid_uri(uri),
         {:ok, source} <- Source.capture(),
         runtime = Source.runtime(source),
         resources = ServiceRef.new(runtime, :resource_subscriptions),
         sessions = ServiceRef.new(runtime, :sessions),
         {:ok, keys} <-
           SubscriptionRegistry.sessions(resources, uri, deadline: Source.deadline(source)),
         {:ok, targets} <- targets(source, sessions, keys) do
      publish(source, sessions, targets, uri)
    end
  end

  defp targets(source, service, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn {id, epoch}, {:ok, targets} ->
      with true <- Source.current?(source),
           {:ok, lease} <- SessionLease.new(service, id, epoch),
           {:ok, %{metadata: metadata}} <-
             SessionManager.get_session(service, lease, deadline: Source.deadline(source)) do
        targets = if Source.matches?(source, metadata), do: [lease | targets], else: targets
        {:cont, {:ok, targets}}
      else
        {:error, reason} when reason in [:stale_session_lease, :session_not_found] ->
          {:cont, {:ok, targets}}

        _retired ->
          {:halt, {:error, :resource_source_retired}}
      end
    end)
  end

  defp publish(source, service, targets, uri) do
    initial = %{subscribers: length(targets), delivered: 0, stored: 0}

    result =
      Enum.reduce_while(targets, {:ok, initial}, fn lease, {:ok, counts} ->
        with true <- Source.current?(source),
             {:ok, key} <- SessionLease.validate(lease, service, :sessions),
             {:ok, _event} <-
               ServiceOperation.call(
                 service,
                 :sessions,
                 :http_resource_append,
                 [key, uri, source],
                 deadline: Source.deadline(source)
               ) do
          delivered = if live_target?(source, lease), do: 1, else: 0

          {:cont,
           {:ok, %{counts | stored: counts.stored + 1, delivered: counts.delivered + delivered}}}
        else
          false ->
            {:halt, {:error, {:resource_publication_partial, :resource_source_retired, counts}}}

          {:error, reason} ->
            {:halt, {:error, {:resource_publication_partial, reason, counts}}}
        end
      end)

    case result do
      {:ok, counts} -> Map.take(counts, [:subscribers, :delivered])
      error -> error
    end
  end

  defp live_target?(source, lease) do
    case HTTPWriterProxy.domain(Source.runtime(source)) do
      {:ok, domain} -> HTTPWriterRegistry.session_delivery_active?(domain, lease, source)
      _unavailable -> false
    end
  end

  defp valid_uri(uri) when is_binary(uri) and byte_size(uri) in 1..@max_uri_bytes,
    do: if(String.valid?(uri), do: :ok, else: {:error, :invalid_resource_uri})

  defp valid_uri(_uri), do: {:error, :invalid_resource_uri}
end
