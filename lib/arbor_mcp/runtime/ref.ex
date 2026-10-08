defmodule Arbor.MCP.Server.Runtime.Ref do
  @moduledoc """
  Opaque reference to one supervised MCP server instance.

  Obtain references with `Arbor.MCP.Server.Runtime.ref/1`. A reference survives
  restarts of children, but not replacement of the runtime supervisor itself.
  """

  @enforce_keys [:supervisor, :table]
  defstruct [:supervisor, :table]

  @opaque t :: %__MODULE__{supervisor: pid(), table: :ets.tid()}

  @doc false
  @spec new(pid(), :ets.tid()) :: t()
  def new(supervisor, table), do: %__MODULE__{supervisor: supervisor, table: table}

  @doc false
  @spec validate(term()) :: {:ok, t()} | {:error, :runtime_unavailable}
  def validate(%__MODULE__{supervisor: supervisor, table: table} = runtime) do
    if local_pid?(supervisor) and Process.alive?(supervisor) and
         :proc_lib.translate_initial_call(supervisor) ==
           {:supervisor, Arbor.MCP.Server.Runtime, 1} and
         :ets.info(table, :owner) == supervisor do
      {:ok, runtime}
    else
      {:error, :runtime_unavailable}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  def validate(_other), do: {:error, :runtime_unavailable}

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(runtime), do: match?({:ok, _runtime}, validate(runtime))

  @doc false
  @spec supervisor(t()) :: pid()
  def supervisor(%__MODULE__{supervisor: supervisor}), do: supervisor

  @doc false
  @spec table(t()) :: :ets.tid()
  def table(%__MODULE__{table: table}), do: table

  @doc false
  @spec address(term()) ::
          {:ok, pid() | atom() | {:global, term()} | {:via, module(), term()}}
          | {:error, :runtime_unavailable}
  def address(pid) when is_pid(pid) do
    if local_pid?(pid), do: {:ok, pid}, else: {:error, :runtime_unavailable}
  end

  def address(name) when is_atom(name), do: {:ok, name}
  def address({:global, _name} = address), do: {:ok, address}
  def address({:via, module, _name} = address) when is_atom(module), do: {:ok, address}
  def address(_other), do: {:error, :runtime_unavailable}

  defp local_pid?(pid), do: is_pid(pid) and node(pid) == node()
end
