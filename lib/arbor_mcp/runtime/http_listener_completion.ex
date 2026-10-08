defmodule Arbor.MCP.Server.Runtime.HTTPListenerCompletion do
  @moduledoc false
  @enforce_keys [:listener, :token]
  defstruct [:listener, :token]

  @opaque t :: %__MODULE__{
            listener: Arbor.MCP.Server.Runtime.HTTPListenerBinding.t(),
            token: reference()
          }

  def new(listener, token) when is_reference(token),
    do: %__MODULE__{listener: listener, token: token}

  def address(%__MODULE__{listener: listener, token: token}), do: {:ok, listener, token}
  def address(_invalid), do: {:error, :invalid_http_listener_completion}

  def validate(completion),
    do: Arbor.MCP.Server.Runtime.HTTPWriterRegistry.validate_listener_completion(completion)
end
