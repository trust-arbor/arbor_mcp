defmodule Arbor.MCP.Testing.SchemaEncoderProbe do
  @moduledoc false
  defstruct [:value]
end

defimpl Jason.Encoder, for: Arbor.MCP.Testing.SchemaEncoderProbe do
  def encode(_value, opts) do
    send(self(), :schema_encoder_invoked)
    Jason.Encode.map(%{}, opts)
  end
end
