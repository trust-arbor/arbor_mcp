defmodule Arbor.MCP.Server.Subscriptions.Adapter do
  @moduledoc """
  Storage contract for modern MCP subscription registrations.

  The bundled ETS adapter is node-local. Clustered HTTP deployments can use
  `Arbor.MCP.Server.Subscriptions.PubSub`, which combines node-local listener
  storage with cluster publication fan-out, or provide their own adapter.

  The optional callbacks let an adapter broadcast an untargeted publication
  and translate a cluster message back into a local publication. Storage
  callbacks are still serialized by the owning subscription registry.
  """

  alias Arbor.MCP.Server.Subscriptions.Entry

  @type adapter_state :: term()

  @callback init(keyword()) :: {:ok, adapter_state()} | {:error, term()}
  @callback put(Entry.t(), adapter_state()) ::
              {:ok, adapter_state()} | {:error, term(), adapter_state()}
  @callback delete(String.t(), adapter_state()) :: {:ok, adapter_state()}
  @callback all(adapter_state()) :: {[Entry.t()], adapter_state()}

  @callback broadcast(String.t(), map(), pid() | nil, adapter_state()) ::
              {:ok, adapter_state()} | {:error, term(), adapter_state()}

  @callback handle_info(term(), adapter_state()) ::
              {:publish, String.t(), map(), pid() | nil, adapter_state()}
              | {:noreply, adapter_state()}
              | :unhandled

  @optional_callbacks broadcast: 4, handle_info: 2
end
