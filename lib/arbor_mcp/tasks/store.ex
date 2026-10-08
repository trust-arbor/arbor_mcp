defmodule Arbor.MCP.Tasks.Store do
  @moduledoc """
  Persistence contract for the MCP Tasks extension.

  A store must make `create/3` durable before returning success and must apply
  ownership checks to every operation. Implementations should make lifecycle
  operations atomic across every node that can serve the same task ID.

  ArborMCP ships `Arbor.MCP.Tasks.Store.ETS` as a bounded, node-local reference
  implementation. Deployments that require task survival across server or
  node restarts should configure a database-backed implementation.
  """

  alias Arbor.MCP.Tasks.Task

  @type owner :: %{
          principal_id: String.t() | nil,
          tenant_id: String.t() | nil,
          audience: String.t() | nil
        }

  @type transition ::
          {:complete, map()}
          | {:fail, map()}
          | {:require_input, map()}
          | {:status_message, String.t() | nil}
          | :cancelled

  @type store_error ::
          :already_exists
          | :invalid_task
          | :invalid_input_responses
          | :invalid_transition
          | :not_found_or_unauthorized
          | :store_full
          | :ttl_out_of_range
          | term()

  @callback create(Task.t(), owner(), keyword()) ::
              {:ok, Task.t()} | {:error, store_error()}

  @callback fetch(String.t(), owner(), keyword()) ::
              {:ok, Task.t()} | {:error, store_error()}

  @callback submit_input(String.t(), map(), owner(), keyword()) ::
              :ok | {:error, store_error()}

  @callback request_cancel(String.t(), owner(), keyword()) ::
              :ok | {:error, store_error()}

  @callback transition(String.t(), transition(), owner(), keyword()) ::
              {:ok, Task.t()} | {:error, store_error()}

  @callback take_input_responses(String.t(), owner(), keyword()) ::
              {:ok, map()} | {:error, store_error()}

  @callback cancellation_requested?(String.t(), owner(), keyword()) ::
              {:ok, boolean()} | {:error, store_error()}
end
