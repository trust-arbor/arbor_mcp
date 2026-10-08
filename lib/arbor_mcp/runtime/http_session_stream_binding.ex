defmodule Arbor.MCP.Server.Runtime.HTTPSessionStreamBinding do
  @moduledoc false
  alias Arbor.MCP.Server.Runtime.{HTTPWriterBinding, HTTPWriterRegistry, Ref}
  @enforce_keys [:writer, :registration]
  defstruct [:writer, :registration]

  @opaque t :: %__MODULE__{writer: HTTPWriterBinding.t(), registration: reference()}

  @spec new(HTTPWriterBinding.t(), reference()) :: t()
  def new(writer, registration) when is_reference(registration),
    do: %__MODULE__{writer: writer, registration: registration}

  @spec address(t()) :: {:ok, HTTPWriterBinding.t(), reference()} | {:error, atom()}
  def address(%__MODULE__{writer: writer, registration: registration}),
    do: {:ok, writer, registration}

  def address(_invalid), do: {:error, :invalid_http_session_stream}

  @spec validate(t(), Ref.t()) :: {:ok, map()} | {:error, atom()}
  def validate(binding, runtime), do: HTTPWriterRegistry.validate_session_stream(binding, runtime)
end
