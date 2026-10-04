defmodule Arbor.MCP.Server.Runtime.ServiceRef do
  @moduledoc """
  Opaque address of a logical service owned or borrowed by one server runtime.

  References resolve the current service after child restarts. They do not
  follow a replacement of the entire runtime, and contain no cached child PID.
  Obtain one with `Arbor.MCP.Server.Runtime.service/2`.
  """

  alias Arbor.MCP.Server.Runtime.Ref

  @enforce_keys [:runtime, :kind]
  defstruct [:runtime, :kind]

  @opaque t :: %__MODULE__{
            runtime: Ref.t(),
            kind: :tasks | :replay_cache | :subscriptions | :sessions | :resource_subscriptions
          }

  @doc false
  @spec new(Ref.t(), atom()) :: t()
  def new(runtime, kind), do: %__MODULE__{runtime: runtime, kind: kind}

  @doc false
  @spec validate(term(), atom()) :: {:ok, Ref.t()} | {:error, atom()}
  def validate(%__MODULE__{runtime: runtime, kind: kind}, kind), do: Ref.validate(runtime)
  def validate(%__MODULE__{}, _kind), do: {:error, :wrong_service}
  def validate(_other, _kind), do: {:error, :invalid_service_reference}
end
