defmodule ExMCP.ACP.PendingRequests do
  @moduledoc false

  @type id ::
          String.t()
          | integer()
          | reference()
          | {:acp_handler_request, reference(), :atomics.atomics_ref()}
          | nil
  @type pending :: %{optional(id()) => term()}

  @spec put(pending(), id(), term()) :: pending()
  def put(pending, id, value) when is_map(pending) do
    Map.put(pending, id, value)
  end

  @spec pop(pending(), id()) :: {term() | nil, pending()}
  def pop(pending, id) when is_map(pending) do
    Map.pop(pending, id)
  end

  @spec delete(pending(), id()) :: pending()
  def delete(pending, id) when is_map(pending) do
    Map.delete(pending, id)
  end

  @spec values(pending()) :: [term()]
  def values(pending) when is_map(pending) do
    Map.values(pending)
  end

  @spec empty() :: pending()
  def empty, do: %{}
end
