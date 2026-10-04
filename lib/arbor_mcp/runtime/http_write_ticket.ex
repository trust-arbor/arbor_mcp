defmodule Arbor.MCP.Server.Runtime.HTTPWriteTicket do
  @moduledoc false
  @enforce_keys [:domain, :token, :binding, :writer, :receipt]
  defstruct [:domain, :token, :binding, :writer, :receipt]

  @opaque t :: %__MODULE__{
            domain: Arbor.MCP.Server.Runtime.HTTPWriterRegistry.t(),
            token: reference(),
            binding: reference(),
            writer: pid(),
            receipt: :atomics.atomics_ref()
          }

  @spec new(
          Arbor.MCP.Server.Runtime.HTTPWriterRegistry.t(),
          reference(),
          reference(),
          pid(),
          :atomics.atomics_ref()
        ) :: t()
  def new(domain, token, binding, writer, receipt),
    do: %__MODULE__{
      domain: domain,
      token: token,
      binding: binding,
      writer: writer,
      receipt: receipt
    }

  @spec address(t()) ::
          {:ok, {Arbor.MCP.Server.Runtime.HTTPWriterRegistry.t(), reference(), reference()}}
          | {:error, atom()}
  def address(%__MODULE__{domain: domain, token: token, binding: binding})
      when is_reference(token) and is_reference(binding),
      do: {:ok, {domain, token, binding}}

  def address(_), do: {:error, :invalid_http_write_ticket}

  @spec writer?(t(), pid()) :: boolean()
  def writer?(%__MODULE__{writer: writer}, caller), do: writer == caller
  def writer?(_, _), do: false

  @spec receipt_matches?(t(), :atomics.atomics_ref()) :: boolean()
  def receipt_matches?(%__MODULE__{receipt: receipt}, expected), do: receipt == expected

  @spec record_return(t(), 1 | 2 | 3) :: 0 | 1 | 2 | 3 | {:error, atom()}
  def record_return(%__MODULE__{receipt: receipt, writer: writer}, code)
      when writer == self() and code in [1, 2, 3] do
    case :atomics.compare_exchange(receipt, 1, 0, code) do
      :ok -> code
      previous -> previous
    end
  end

  def record_return(_, _), do: {:error, :invalid_http_writer}

  @spec receipt(t()) :: 0 | 1 | 2 | 3
  def receipt(%__MODULE__{receipt: receipt}), do: :atomics.get(receipt, 1)
end
