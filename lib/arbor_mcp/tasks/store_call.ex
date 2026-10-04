defmodule Arbor.MCP.Tasks.StoreCall do
  @moduledoc false

  # Store-invocation primitive shared by `Arbor.MCP.Tasks` and
  # `Arbor.MCP.Server.Subscriptions`. It sits below both so subscription
  # authorization can consult the configured task store without depending on
  # the `Arbor.MCP.Tasks` facade, which itself publishes through Subscriptions.

  alias Arbor.MCP.Server.Runtime.{ServiceOperation, Services}
  alias Arbor.MCP.Tasks.Store

  @spec call(atom(), [term()], keyword()) :: term() | {:error, :task_store_unavailable}
  def call(function, args, opts) do
    case Services.task_options(opts) do
      {:ok, opts} ->
        store = Keyword.get(opts, :store, Application.get_env(:arbor_mcp, :task_store, Store.ETS))

        store_opts =
          Keyword.drop(opts, [
            :store,
            :owner,
            :principal_id,
            :tenant_id,
            :audience,
            :subscription_registry,
            :notify,
            :transport_ref,
            :runtime,
            :service
          ])

        if opts[:runtime],
          do:
            ServiceOperation.call(
              opts[:runtime],
              :tasks,
              function,
              args,
              Keyword.delete(opts, :owner)
            ),
          else: apply(store, function, args ++ [store_opts])

      {:error, _reason} ->
        {:error, :task_store_unavailable}
    end
  rescue
    _error -> {:error, :task_store_unavailable}
  catch
    :exit, _reason -> {:error, :task_store_unavailable}
  end
end
