defmodule Arbor.MCP.Server.Runtime.OwnedChildConfig do
  @moduledoc false

  def new(descriptors) when is_list(descriptors) do
    descriptors
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {descriptor, index}, {:ok, accepted} ->
      case validate(descriptor, index) do
        {:ok, normalized} ->
          if Enum.any?(accepted, &(&1.id == normalized.id)),
            do: {:halt, {:error, {:invalid_owned_store, index, :duplicate_id}}},
            else: {:cont, {:ok, [normalized | accepted]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  def new(_invalid), do: {:error, {:invalid_store_children, :owned_descriptors_required}}

  defp validate(descriptor, index) do
    if is_list(descriptor) and Keyword.keyword?(descriptor) do
      adapter = Keyword.get(descriptor, :adapter)
      options = Keyword.get(descriptor, :options, [])

      with :ok <- validate_keys(descriptor),
           :ok <- validate_options(options),
           :ok <- validate_adapter(adapter),
           :ok <- validate_id(Keyword.get(descriptor, :id)) do
        {:ok,
         %{
           adapter: adapter,
           options: options,
           id: Keyword.get(descriptor, :id, {:owned_store, adapter, index})
         }}
      else
        {:error, reason} -> {:error, {:invalid_owned_store, index, reason}}
      end
    else
      {:error, {:invalid_owned_store, index, :owned_descriptor_required}}
    end
  end

  defp validate_keys(descriptor) do
    if Enum.all?(Keyword.keys(descriptor), &(&1 in [:adapter, :options, :id])) and
         length(descriptor) == length(Enum.uniq(Keyword.keys(descriptor))),
       do: :ok,
       else: {:error, :unsupported_descriptor_option}
  end

  defp validate_id(id)
       when id in [
              :tasks,
              :replay_cache,
              :sessions,
              :resource_subscriptions,
              :subscriptions,
              :subscription_listeners
            ],
       do: {:error, :reserved_id}

  defp validate_id(_id), do: :ok

  defp validate_options(options) do
    if is_list(options) and Keyword.keyword?(options),
      do: :ok,
      else: {:error, :keyword_options_required}
  end

  defp validate_adapter(adapter) when is_atom(adapter) and not is_nil(adapter) do
    with {:module, ^adapter} <- Code.ensure_loaded(adapter),
         true <- function_exported?(adapter, :start_link, 1),
         true <- function_exported?(adapter, :child_spec, 1),
         true <- function_exported?(adapter, :runtime_service_capabilities, 0),
         %{bounded_startup: 1} <- adapter.runtime_service_capabilities() do
      :ok
    else
      _invalid -> {:error, :bounded_owned_startup_required}
    end
  rescue
    _error -> {:error, :bounded_owned_startup_required}
  catch
    _kind, _reason -> {:error, :bounded_owned_startup_required}
  end

  defp validate_adapter(_invalid), do: {:error, :bounded_owned_startup_required}
end
