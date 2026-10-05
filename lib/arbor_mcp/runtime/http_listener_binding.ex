defmodule Arbor.MCP.Server.Runtime.HTTPListenerBinding do
  @moduledoc false
  @enforce_keys [:writer, :registration]
  defstruct [:writer, :registration]

  @opaque t :: %__MODULE__{
            writer: Arbor.MCP.Server.Runtime.HTTPWriterBinding.t(),
            registration: reference()
          }

  @spec new(Arbor.MCP.Server.Runtime.HTTPWriterBinding.t(), reference()) :: t()
  def new(writer, registration) when is_reference(registration),
    do: %__MODULE__{writer: writer, registration: registration}

  @spec address(t()) ::
          {:ok, Arbor.MCP.Server.Runtime.HTTPWriterBinding.t(), reference()} | {:error, atom()}
  def address(%__MODULE__{writer: writer, registration: registration}),
    do: {:ok, writer, registration}

  def address(_invalid), do: {:error, :invalid_http_listener_binding}

  @spec validate(t(), Arbor.MCP.Server.Runtime.Ref.t()) :: {:ok, map()} | {:error, atom()}
  def validate(binding, runtime),
    do: Arbor.MCP.Server.Runtime.HTTPWriterRegistry.validate_listener(binding, runtime)
end
