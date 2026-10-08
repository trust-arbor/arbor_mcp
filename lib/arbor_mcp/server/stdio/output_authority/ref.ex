defmodule Arbor.MCP.Server.Stdio.OutputAuthority.Ref do
  @moduledoc false
  @enforce_keys [:pid, :table, :identity]
  defstruct [:pid, :table, :identity]
  @opaque t :: %__MODULE__{pid: pid(), table: :ets.tid(), identity: reference()}

  @spec new(pid(), :ets.tid(), reference()) :: t()
  def new(pid, table, identity), do: %__MODULE__{pid: pid, table: table, identity: identity}

  @spec validate(term()) :: {:ok, t()} | {:error, :stdio_output_unavailable}
  def validate(%__MODULE__{} = ref) do
    if is_pid(ref.pid) and node(ref.pid) == node() and Process.alive?(ref.pid) and
         :proc_lib.translate_initial_call(ref.pid) ==
           {Arbor.MCP.Server.Stdio.OutputAuthority, :init, 1} and
         :ets.info(ref.table, :owner) == ref.pid and
         :ets.lookup(ref.table, :identity) == [{:identity, ref.identity}] do
      {:ok, ref}
    else
      {:error, :stdio_output_unavailable}
    end
  rescue
    ArgumentError -> {:error, :stdio_output_unavailable}
  end

  def validate(_), do: {:error, :stdio_output_unavailable}
  @spec pid(t()) :: pid()
  def pid(%__MODULE__{pid: pid}), do: pid
  @spec table(t()) :: :ets.tid()
  def table(%__MODULE__{table: table}), do: table
end
