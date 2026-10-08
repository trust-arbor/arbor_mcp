defmodule Arbor.MCP.Server.Stdio.OutputLease do
  @moduledoc false
  alias Arbor.MCP.Server.Stdio.OutputAuthority.Ref
  @enforce_keys [:authority, :token, :device, :deadline]
  defstruct [:authority, :token, :device, :deadline]

  @opaque t :: %__MODULE__{
            authority: Ref.t(),
            token: reference(),
            device: pid(),
            deadline: integer()
          }

  @spec new(Ref.t(), reference(), pid(), integer()) :: t()
  def new(authority, token, device, deadline),
    do: %__MODULE__{authority: authority, token: token, device: device, deadline: deadline}

  @spec info(term()) :: {:ok, map()} | {:error, :stdio_output_unavailable}
  def info(%__MODULE__{} = lease) do
    with {:ok, _} <- Ref.validate(lease.authority),
         true <-
           is_reference(lease.token) and is_pid(lease.device) and
             node(lease.device) == node() and is_integer(lease.deadline) do
      {:ok, Map.from_struct(lease)}
    else
      _ -> {:error, :stdio_output_unavailable}
    end
  end

  def info(_), do: {:error, :stdio_output_unavailable}
  @spec device(t()) :: pid()
  def device(%__MODULE__{device: device}), do: device
end
