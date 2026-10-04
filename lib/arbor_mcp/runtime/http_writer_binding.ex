defmodule Arbor.MCP.Server.Runtime.HTTPWriterBinding do
  @moduledoc false
  @enforce_keys [:domain, :token]
  defstruct [:domain, :token]

  @opaque t :: %__MODULE__{
            domain: Arbor.MCP.Server.Runtime.HTTPWriterRegistry.t(),
            token: reference()
          }

  @spec new(Arbor.MCP.Server.Runtime.HTTPWriterRegistry.t(), reference()) :: t()
  def new(domain, token), do: %__MODULE__{domain: domain, token: token}

  @spec address(t()) ::
          {:ok, {Arbor.MCP.Server.Runtime.HTTPWriterRegistry.t(), reference()}} | {:error, atom()}
  def address(%__MODULE__{domain: domain, token: token}) when is_reference(token),
    do: {:ok, {domain, token}}

  def address(_), do: {:error, :invalid_http_writer_binding}

  @spec validate(t(), Arbor.MCP.Server.Runtime.Ref.t()) :: {:ok, map()} | {:error, atom()}
  def validate(binding, runtime),
    do: Arbor.MCP.Server.Runtime.HTTPWriterRegistry.validate_invocation(binding, runtime)
end
