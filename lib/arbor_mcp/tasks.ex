defmodule Arbor.MCP.Tasks do
  @moduledoc """
  Durable lifecycle helpers for the MCP Tasks extension.

  `create/3` inserts a task into the configured store before returning its
  `CreateTaskResult`. Server callbacks can use `get/2`, `update/3`, and
  `cancel/2` for the modern task methods, while workers use the transition and
  input-response helpers.

  The current request principal, tenant, and endpoint are included in the
  store owner automatically. Runtime callbacks use their owned task service.
  A worker outside the callback must capture `Server.Runtime.service(:tasks)`
  and `owner/1` before spawning, then pass `service: service, owner: owner`.

  Successful creates and wire-visible transitions asynchronously publish the
  full modern state to authorized `subscriptions/listen` task filters. Pass a
  runtime address as `runtime: runtime` or its task reference as `service: service`.
  The runtime selects the matching subscription service. Outside Runtime,
  standalone legacy helpers still accept `subscription_registry: registry`.
  Use `notify: false` only when the host owns publication.
  """

  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.Runtime.Services
  alias Arbor.MCP.Server.Subscriptions
  alias Arbor.MCP.Tasks.{Extension, Store, StoreCall, Task}

  @default_ttl_ms 3_600_000
  @default_poll_interval_ms 1_000

  @type task_error :: {:error, Store.store_error() | :task_store_unavailable}

  @doc "Synchronously creates and stores a task before returning its wire handle."
  @spec create(String.t(), map(), keyword()) :: {:ok, map()} | task_error()
  def create(tool_name, arguments \\ %{}, opts \\ [])

  def create(tool_name, arguments, opts)
      when is_binary(tool_name) and is_map(arguments) and is_list(opts) do
    task_opts =
      [
        ttl: Keyword.get(opts, :ttl, @default_ttl_ms),
        poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval_ms),
        status_message: Keyword.get(opts, :status_message),
        metadata: Keyword.get(opts, :metadata, %{})
      ]
      |> maybe_put_id(opts)

    task = Task.new(tool_name, arguments, task_opts)

    with {:ok, stored} <- call_store(:create, [task, owner(opts)], opts) do
      notify(stored, opts)

      result =
        stored
        |> Task.to_map(:modern)
        |> Map.put("resultType", Extension.result_type())

      {:ok, result}
    end
  end

  def create(_tool_name, _arguments, _opts), do: {:error, :invalid_task}

  @doc "Returns the authorized full wire state for one task."
  @spec get(String.t(), keyword()) :: {:ok, map()} | task_error()
  def get(task_id, opts \\ [])

  def get(task_id, opts) when is_binary(task_id) and is_list(opts) do
    with {:ok, task} <- call_store(:fetch, [task_id, owner(opts)], opts) do
      {:ok, Task.to_map(task, :modern)}
    end
  end

  def get(_task_id, _opts), do: {:error, :not_found_or_unauthorized}

  @doc "Idempotently submits responses for currently outstanding task inputs."
  @spec update(String.t(), map(), keyword()) :: :ok | task_error()
  def update(task_id, input_responses, opts \\ [])

  def update(task_id, input_responses, opts)
      when is_binary(task_id) and is_map(input_responses) and is_list(opts) do
    task_owner = owner(opts)

    case call_store(:submit_input, [task_id, input_responses, task_owner], opts) do
      :ok ->
        notify_current(task_id, task_owner, opts)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  def update(_task_id, _input_responses, _opts), do: {:error, :invalid_input_responses}

  @doc "Records a cooperative cancellation request and acknowledges it."
  @spec cancel(String.t(), keyword()) :: :ok | task_error()
  def cancel(task_id, opts \\ [])

  def cancel(task_id, opts) when is_binary(task_id) and is_list(opts) do
    call_store(:request_cancel, [task_id, owner(opts)], opts)
  end

  def cancel(_task_id, _opts), do: {:error, :not_found_or_unauthorized}

  @doc "Atomically completes a working task."
  @spec complete(String.t(), map(), keyword()) :: {:ok, Task.t()} | task_error()
  def complete(task_id, result, opts \\ []) when is_map(result) do
    transition(task_id, {:complete, result}, opts)
  end

  @doc "Atomically fails a working task with a JSON-RPC error object."
  @spec fail(String.t(), map(), keyword()) :: {:ok, Task.t()} | task_error()
  def fail(task_id, error, opts \\ []) when is_map(error) do
    transition(task_id, {:fail, error}, opts)
  end

  @doc "Atomically moves a working task to input-required."
  @spec require_input(String.t(), map(), keyword()) :: {:ok, Task.t()} | task_error()
  def require_input(task_id, input_requests, opts \\ []) when is_map(input_requests) do
    transition(task_id, {:require_input, input_requests}, opts)
  end

  @doc "Atomically marks a cooperatively stopped task as cancelled."
  @spec mark_cancelled(String.t(), keyword()) :: {:ok, Task.t()} | task_error()
  def mark_cancelled(task_id, opts \\ []), do: transition(task_id, :cancelled, opts)

  @doc "Atomically changes a non-terminal task's status message."
  @spec put_status_message(String.t(), String.t() | nil, keyword()) ::
          {:ok, Task.t()} | task_error()
  def put_status_message(task_id, message, opts \\ [])
      when is_nil(message) or is_binary(message) do
    transition(task_id, {:status_message, message}, opts)
  end

  @doc "Atomically drains input responses accepted for a task worker."
  @spec take_input_responses(String.t(), keyword()) :: {:ok, map()} | task_error()
  def take_input_responses(task_id, opts \\ []) when is_binary(task_id) do
    call_store(:take_input_responses, [task_id, owner(opts)], opts)
  end

  @doc "Returns whether cooperative cancellation was requested."
  @spec cancellation_requested?(String.t(), keyword()) :: {:ok, boolean()} | task_error()
  def cancellation_requested?(task_id, opts \\ []) when is_binary(task_id) do
    call_store(:cancellation_requested?, [task_id, owner(opts)], opts)
  end

  @doc "Builds the non-secret authorization owner for the current request."
  @spec owner(keyword()) :: Store.owner()
  def owner(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :owner) do
      owner when is_map(owner) -> normalize_owner(owner)
      _other -> context_owner(opts)
    end
  end

  defp transition(task_id, operation, opts) when is_binary(task_id) and is_list(opts) do
    case call_store(:transition, [task_id, operation, owner(opts)], opts) do
      {:ok, task} = ok ->
        notify(task, opts)
        ok

      {:error, _reason} = error ->
        error
    end
  end

  defp transition(_task_id, _operation, _opts), do: {:error, :invalid_transition}

  defp context_owner(opts) do
    context = Context.current()

    %{
      principal_id: Keyword.get(opts, :principal_id, context_value(context, :principal_id)),
      tenant_id: Keyword.get(opts, :tenant_id, context_value(context, :tenant_id)),
      audience:
        Keyword.get(
          opts,
          :audience,
          Keyword.get(opts, :endpoint, context_value(context, :endpoint))
        )
    }
  end

  defp normalize_owner(owner) do
    %{
      principal_id: map_value(owner, :principal_id),
      tenant_id: map_value(owner, :tenant_id),
      audience: map_value(owner, :audience)
    }
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp context_value(nil, _key), do: nil
  defp context_value(context, key), do: Map.get(context, key)

  defp maybe_put_id(task_opts, opts) do
    case Keyword.fetch(opts, :id) do
      {:ok, id} -> Keyword.put(task_opts, :id, id)
      :error -> task_opts
    end
  end

  defp notify_current(task_id, task_owner, opts) do
    case call_store(:fetch, [task_id, task_owner], opts) do
      {:ok, task} -> notify(task, opts)
      {:error, _reason} -> :ok
    end
  end

  defp notify(%Task{} = task, opts) do
    case Services.task_options(opts) do
      {:ok, resolved} -> publish_task(task, resolved)
      {:error, _reason} -> :ok
    end
  end

  defp publish_task(task, opts) do
    if Keyword.get(opts, :notify, true) do
      publish_opts =
        case Keyword.fetch(opts, :subscription_registry) do
          {:ok, registry} -> [registry: registry]
          :error -> []
        end

      publish_opts =
        case Keyword.get(opts, :service) || Keyword.get(opts, :runtime) do
          nil -> publish_opts
          server -> Keyword.put(publish_opts, :runtime, server)
        end

      Subscriptions.publish_async(
        Extension.notification_method(),
        Task.to_map(task, :modern),
        publish_opts
      )
    else
      :ok
    end
  end

  defp call_store(function, args, opts), do: StoreCall.call(function, args, opts)
end
