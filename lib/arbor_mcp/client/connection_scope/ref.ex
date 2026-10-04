defmodule Arbor.MCP.Client.ConnectionScope.Ref do
  @moduledoc false
  @opaque t :: %__MODULE__{
            observer: pid(),
            token: reference(),
            deadline: integer(),
            cleanup_ms: pos_integer()
          }
  defstruct [:observer, :token, :deadline, :cleanup_ms]

  @spec new(pid(), reference(), integer(), pos_integer()) :: t()
  def new(observer, token, deadline, cleanup),
    do: %__MODULE__{observer: observer, token: token, deadline: deadline, cleanup_ms: cleanup}

  @spec observer(t()) :: pid()
  def observer(%__MODULE__{observer: observer}), do: observer
  @spec token(t()) :: reference()
  def token(%__MODULE__{token: token}), do: token
  @spec deadline(t()) :: integer()
  def deadline(%__MODULE__{deadline: deadline}), do: deadline
  @spec cleanup_ms(t()) :: pos_integer()
  def cleanup_ms(%__MODULE__{cleanup_ms: cleanup}), do: cleanup
end
