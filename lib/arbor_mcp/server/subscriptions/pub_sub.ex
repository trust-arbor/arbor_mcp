defmodule Arbor.MCP.Server.Subscriptions.PubSub do
  @moduledoc """
  Cluster fan-out adapter for modern MCP subscriptions.

  The adapter keeps registrations in a configurable storage adapter on the
  node that owns each listener and distributes untargeted publications over a
  Phoenix.PubSub-compatible module. No Phoenix dependency is required by
  ArborMCP; applications that select this adapter must provide a module exporting
  `subscribe/2` and `broadcast_from/4`.

  Publications constrained to a `transport_ref` remain node-local because a
  transport process is owned by exactly one registry.
  """

  @behaviour Arbor.MCP.Server.Subscriptions.Adapter

  alias Arbor.MCP.Server.Subscriptions.ETS

  @message_tag :ex_mcp_subscription_publication
  @message_version 1
  @default_topic "ex_mcp:subscriptions:v1"

  defstruct [
    :pubsub_module,
    :pubsub_server,
    :topic,
    :storage_adapter,
    :storage_state
  ]

  @impl true
  def init(opts) do
    pubsub_module = Keyword.get(opts, :pubsub_module, Phoenix.PubSub)
    topic = Keyword.get(opts, :topic, @default_topic)
    {storage_adapter, storage_opts} = adapter_spec(Keyword.get(opts, :storage_adapter, ETS))

    with {:ok, pubsub_server} <- Keyword.fetch(opts, :pubsub_server),
         :ok <- validate_topic(topic),
         :ok <- validate_pubsub_module(pubsub_module),
         :ok <- validate_storage_adapter(storage_adapter),
         {:ok, storage_state} <- storage_adapter.init(storage_opts),
         :ok <- pubsub_module.subscribe(pubsub_server, topic) do
      {:ok,
       %__MODULE__{
         pubsub_module: pubsub_module,
         pubsub_server: pubsub_server,
         topic: topic,
         storage_adapter: storage_adapter,
         storage_state: storage_state
       }}
    else
      :error -> {:error, :pubsub_server_required}
      {:error, _reason} = error -> error
      other -> {:error, {:pubsub_subscribe_failed, other}}
    end
  end

  @impl true
  def put(entry, state) do
    case state.storage_adapter.put(entry, state.storage_state) do
      {:ok, storage_state} -> {:ok, %{state | storage_state: storage_state}}
      {:error, reason, storage_state} -> {:error, reason, %{state | storage_state: storage_state}}
    end
  end

  @impl true
  def delete(token, state) do
    {:ok, storage_state} = state.storage_adapter.delete(token, state.storage_state)
    {:ok, %{state | storage_state: storage_state}}
  end

  @impl true
  def all(state) do
    {entries, storage_state} = state.storage_adapter.all(state.storage_state)
    {entries, %{state | storage_state: storage_state}}
  end

  @impl true
  def broadcast(_method, _params, transport_ref, state) when is_pid(transport_ref) do
    {:ok, state}
  end

  def broadcast(method, params, nil, state) do
    message = {@message_tag, @message_version, method, params}

    case state.pubsub_module.broadcast_from(
           state.pubsub_server,
           self(),
           state.topic,
           message
         ) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
      other -> {:error, {:unexpected_pubsub_result, other}, state}
    end
  rescue
    error -> {:error, {:pubsub_exception, Exception.message(error)}, state}
  catch
    kind, reason -> {:error, {:pubsub_failure, kind, reason}, state}
  end

  @impl true
  def handle_info({@message_tag, @message_version, method, params}, state)
      when is_binary(method) and is_map(params) do
    {:publish, method, params, nil, state}
  end

  def handle_info(_message, _state), do: :unhandled

  defp validate_topic(topic) when is_binary(topic) and byte_size(topic) > 0, do: :ok
  defp validate_topic(_topic), do: {:error, :invalid_pubsub_topic}

  defp validate_pubsub_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :subscribe, 2) and
         function_exported?(module, :broadcast_from, 4) do
      :ok
    else
      {:error, {:invalid_pubsub_module, module}}
    end
  end

  defp validate_pubsub_module(module), do: {:error, {:invalid_pubsub_module, module}}

  defp validate_storage_adapter(__MODULE__), do: {:error, :recursive_pubsub_storage_adapter}

  defp validate_storage_adapter(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :init, 1) and
         function_exported?(adapter, :put, 2) and function_exported?(adapter, :delete, 2) and
         function_exported?(adapter, :all, 1) do
      :ok
    else
      {:error, {:invalid_subscription_storage_adapter, adapter}}
    end
  end

  defp adapter_spec({adapter, opts}) when is_atom(adapter) and is_list(opts), do: {adapter, opts}
  defp adapter_spec(adapter) when is_atom(adapter), do: {adapter, []}
end
