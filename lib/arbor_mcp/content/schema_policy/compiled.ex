defmodule Arbor.MCP.Content.SchemaPolicy.Compiled do
  @moduledoc false

  @enforce_keys [:root]
  defstruct [:root]

  @opaque t :: %__MODULE__{root: JSV.Root.t()}

  @spec new(JSV.Root.t()) :: t()
  def new(root), do: %__MODULE__{root: root}

  @spec fetch(term()) :: {:ok, t()} | :error
  def fetch(%__MODULE__{} = compiled), do: {:ok, compiled}
  def fetch(_other), do: :error

  @spec validate(t(), term()) :: :ok | {:error, [{String.t(), String.t()}]}
  def validate(%__MODULE__{root: root}, data) do
    case JSV.validate(data, root, cast: false, cast_formats: false) do
      {:ok, _unreturned_data} -> :ok
      {:error, _error} -> {:error, [{"value does not conform to JSON Schema", "#"}]}
    end
  end
end
