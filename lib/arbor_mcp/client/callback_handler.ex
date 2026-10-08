defmodule Arbor.MCP.Client.CallbackHandler do
  @moduledoc """
  Callback-based handler for MCP client events.

  Routes server-initiated requests (elicitation, sampling, roots) to
  user-provided callback functions. This allows any UI framework to
  integrate with MCP without implementing the full Handler behaviour.

  ## Usage

      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :http,
        url: "http://localhost:3000/mcp",
        handler: {Arbor.MCP.Client.CallbackHandler, [
          on_elicitation: fn message, schema ->
            # Present to your UI and collect response
            {:ok, %{"name" => "Alice", "age" => 30}}
          end,
          on_sampling: fn params ->
            # Handle sampling/createMessage request
            {:ok, %{"role" => "assistant", "content" => %{"type" => "text", "text" => "Hello"}}}
          end,
          on_roots: fn ->
            # Return list of roots
            {:ok, [%{"uri" => "file:///workspace", "name" => "workspace"}]}
          end
        ]},
        capabilities: %{"elicitation" => %{}, "sampling" => %{}}
      )

  ## Callbacks

  All callbacks are optional. When not provided, the handler declines
  elicitations, returns empty roots, and rejects sampling requests.

  ### on_elicitation

      fn message :: String.t(), requested_schema :: map() ->
        {:ok, content :: map()}      # accept with data
        | :decline                    # decline the request
        | :cancel                     # cancel the operation
        | {:error, reason}            # error
      end

  ### on_sampling

      fn params :: map() ->
        {:ok, result :: map()}        # sampling result
        | {:error, reason}            # error
      end

  ### on_roots

      fn ->
        {:ok, roots :: [map()]}       # list of root URIs
        | {:error, reason}            # error
      end
  """

  @behaviour Arbor.MCP.Client.Handler

  @impl true
  def init(args) do
    callbacks = Map.new(args || [])
    {:ok, callbacks}
  end

  @impl true
  def handle_ping(state), do: {:ok, %{}, state}

  @impl true
  def handle_list_roots(state) do
    case Map.get(state, :on_roots) do
      nil ->
        {:ok, [], state}

      callback when is_function(callback, 0) ->
        case callback.() do
          {:ok, roots} -> {:ok, roots, state}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  @impl true
  def handle_create_message(params, state) do
    case Map.get(state, :on_sampling) do
      nil ->
        {:error, "Sampling not supported", state}

      callback when is_function(callback, 1) ->
        case callback.(params) do
          {:ok, result} -> {:ok, result, state}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  @impl true
  def handle_elicitation_create(message, requested_schema, state) do
    case Map.get(state, :on_elicitation) do
      nil ->
        {:ok, %{"action" => "decline"}, state}

      callback when is_function(callback, 2) ->
        case callback.(message, requested_schema) do
          {:ok, content} when is_map(content) ->
            {:ok, %{"action" => "accept", "content" => content}, state}

          :decline ->
            {:ok, %{"action" => "decline"}, state}

          :cancel ->
            {:ok, %{"action" => "cancel"}, state}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
