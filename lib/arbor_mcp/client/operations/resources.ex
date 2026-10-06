defmodule Arbor.MCP.Client.Operations.Resources do
  @moduledoc """
  Resource operations for ArborMCP client.

  This module handles all resource-related operations including listing available
  resources, reading resource content, and managing resource subscriptions.
  """

  alias Arbor.MCP.Client.{Subscription, Types}
  alias Arbor.MCP.Internal.{RequestParams, VersionRegistry}

  @doc """
  Lists all available resources from the MCP server.

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, resources} = Arbor.MCP.Client.Operations.Resources.list_resources(client)
  """
  @spec list_resources(Types.client(), Types.request_opts()) :: Types.mcp_response()
  def list_resources(client, opts \\ []) do
    Arbor.MCP.Client.make_request(
      client,
      "resources/list",
      RequestParams.cursor_from_opts(opts),
      opts,
      5_000
    )
  end

  @doc """
  Reads a specific resource by its URI.

  ## Parameters

  - `client` - The MCP client process.
  - `uri` - The URI of the resource to read.

  ## Options

  - `:timeout` - Request timeout (default: 10000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, resource_content} = Arbor.MCP.Client.Operations.Resources.read_resource(client, "mcp://example/resource")
  """
  @spec read_resource(Types.client(), Types.uri(), Types.request_opts()) :: Types.mcp_response()
  def read_resource(client, uri, opts \\ []) do
    Arbor.MCP.Client.make_request(client, "resources/read", RequestParams.uri(uri), opts, 10_000)
  end

  @doc """
  Subscribes to changes for a specific resource.

  The client will receive notifications when the resource is updated.

  ## Parameters

  - `client` - The MCP client process.
  - `uri` - The URI of the resource to subscribe to.

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, subscription} = Arbor.MCP.Client.Operations.Resources.subscribe_resource(client, "mcp://example/resource")
  """
  @spec subscribe_resource(Types.client(), Types.uri(), Types.request_opts()) ::
          Types.mcp_response() | {:ok, Subscription.Ref.t()}
  def subscribe_resource(client, uri, opts \\ []) do
    if modern_client?(client),
      do: subscribe_modern(client, uri, opts),
      else: subscribe_legacy(client, uri, opts)
  end

  @doc """
  Unsubscribes from changes for a specific resource.

  ## Parameters

  - `client` - The MCP client process.
  - `uri` - The URI of the resource to unsubscribe from.

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, result} = Arbor.MCP.Client.Operations.Resources.unsubscribe_resource(client, "mcp://example/resource")
  """
  @spec unsubscribe_resource(Types.client(), Types.uri(), Types.request_opts()) ::
          Types.mcp_response()
  def unsubscribe_resource(client, uri, opts \\ []) do
    if modern_client?(client),
      do: unsubscribe_modern(client, uri, opts),
      else: unsubscribe_legacy(client, uri, opts)
  end

  defp subscribe_modern(client, uri, opts) do
    subscriber = self()

    case GenServer.call(client, {:prepare_resource_subscribe, uri, subscriber}) do
      {:retained, existing} ->
        Subscription.current(existing)

      {:replace, old, uris, generation} ->
        replace_resource_subscription(client, old, uris, generation, opts)
    end
  end

  defp subscribe_legacy(client, uri, opts) do
    Arbor.MCP.Client.make_request(
      client,
      "resources/subscribe",
      RequestParams.uri(uri),
      opts,
      5_000
    )
  end

  defp unsubscribe_modern(client, uri, opts) do
    subscriber = self()

    case GenServer.call(client, {:prepare_resource_unsubscribe, uri, subscriber}) do
      {:retained, _existing} ->
        {:ok, %{}}

      {:cancel, nil} ->
        {:ok, %{}}

      {:cancel, subscription} ->
        :ok = Subscription.cancel(subscription)
        {:ok, %{}}

      {:replace, old, uris, generation} ->
        case replace_resource_subscription(client, old, uris, generation, opts) do
          {:ok, _subscription} -> {:ok, %{}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec replace_resource_subscription(
          Types.client(),
          Subscription.Ref.t() | nil,
          [Types.uri()],
          non_neg_integer(),
          Types.request_opts()
        ) :: {:ok, Subscription.Ref.t()} | {:error, term()}
  def replace_resource_subscription(client, old, uris, generation, opts \\ []) do
    do_replace_resource_subscription(client, old, uris, generation, opts, 4)
  end

  defp do_replace_resource_subscription(_client, _old, _uris, _generation, _opts, 0) do
    {:error, :subscription_filter_changed_concurrently}
  end

  defp do_replace_resource_subscription(client, old, uris, generation, opts, attempts) do
    open_opts = opts |> Keyword.delete(:format) |> Keyword.put(:subscriber, client)

    with {:ok, opened} <-
           Arbor.MCP.Client.listen(
             client,
             %{"resourceSubscriptions" => uris},
             open_opts
           ) do
      case GenServer.call(client, {:commit_resource_subscription, generation, opened}) do
        {:committed, committed_old} ->
          cancel_replaced_subscription(committed_old, opened)
          {:ok, opened}

        {:stale, {:replace, latest_old, latest_uris, latest_generation}} ->
          :ok = Subscription.cancel(opened, "superseded by a newer desired filter")

          do_replace_resource_subscription(
            client,
            latest_old || old,
            latest_uris,
            latest_generation,
            opts,
            attempts - 1
          )
      end
    end
  end

  defp cancel_replaced_subscription(nil, _opened), do: :ok

  defp cancel_replaced_subscription(%Subscription.Ref{pid: pid}, %Subscription.Ref{pid: pid}),
    do: :ok

  defp cancel_replaced_subscription(old, _opened) do
    Subscription.cancel(old, "replaced by acknowledged immutable filter")
  end

  defp unsubscribe_legacy(client, uri, opts) do
    Arbor.MCP.Client.make_request(
      client,
      "resources/unsubscribe",
      RequestParams.uri(uri),
      opts,
      5_000
    )
  end

  defp modern_client?(client) do
    with pid when is_pid(pid) <- GenServer.whereis(client),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         true <- :proplists.get_value({Arbor.MCP.Client, :client}, dictionary) == true,
         {:ok, version} when is_binary(version) <- Arbor.MCP.Client.negotiated_version(client) do
      VersionRegistry.modern?(version)
    else
      _other -> false
    end
  end
end
