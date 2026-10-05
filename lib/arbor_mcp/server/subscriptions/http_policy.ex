defmodule Arbor.MCP.Server.Subscriptions.HTTPPolicy do
  @moduledoc false

  alias Arbor.MCP.SubscriptionFilter

  @limits [:max_queue, :max_message_bytes, :max_queue_bytes, :max_lifetime_ms]

  # Runtime descriptor policy remains authoritative. A mount may only narrow it.
  # The registry separately clamps all limits to its configured native caps and
  # the listener capability retains its original entry-time lifetime cutoff.
  def restrict(resolved, mount) do
    resolved =
      Enum.reduce(@limits, resolved, fn key, options ->
        case Keyword.get(mount, key) do
          nil -> options
          limit -> Keyword.update(options, key, limit, &min(&1, limit))
        end
      end)

    resolved
    |> Keyword.put(
      :authorize_filter,
      filter(Keyword.get(resolved, :authorize_filter), Keyword.get(mount, :authorize_filter))
    )
    |> Keyword.put(
      :authorize_publication,
      publication(
        Keyword.get(resolved, :authorize_publication),
        Keyword.get(mount, :authorize_publication)
      )
    )
  end

  defp filter(nil, mount), do: mount
  defp filter(root, nil), do: root

  defp filter(root, mount) do
    fn requested, context ->
      with {:ok, authorized} <- normalize(root.(requested, context)),
           {:ok, authorized} <- SubscriptionFilter.normalize(authorized),
           true <- SubscriptionFilter.subset?(authorized, requested),
           {:ok, narrowed} <- normalize(mount.(authorized, context)),
           {:ok, narrowed} <- SubscriptionFilter.normalize(narrowed),
           true <- SubscriptionFilter.subset?(narrowed, authorized) do
        {:ok, narrowed}
      else
        false -> {:error, :authorizer_broadened_filter}
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize({:ok, filter}) when is_map(filter), do: {:ok, filter}
  defp normalize(false), do: {:error, :subscription_not_authorized}
  defp normalize({:error, _reason} = error), do: error
  defp normalize(true), do: {:error, :filter_authorizer_must_return_filter}
  defp normalize(_other), do: {:error, :invalid_filter_authorizer_result}

  defp publication(nil, mount), do: mount
  defp publication(root, nil), do: root

  defp publication(root, mount) do
    fn method, params, context ->
      allowed?(root.(method, params, context)) and allowed?(mount.(method, params, context))
    end
  end

  defp allowed?(result), do: result in [true, :ok, {:ok, true}]
end
