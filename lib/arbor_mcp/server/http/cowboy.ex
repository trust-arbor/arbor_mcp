defmodule Arbor.MCP.Server.HTTP.Cowboy do
  @moduledoc """
  Optional Cowboy listener adapter.

  Install `{:plug_cowboy, "~> 2.7"}` in the host application. Listener options
  are passed to `Plug.Cowboy.http/3`; `:ref` keeps its Ranch meaning, including
  the default `Arbor.MCP.HttpPlug.HTTP` reference. Stop by the Ranch reference
  or the returned listener PID to remove the listener from Ranch supervision.
  """

  @behaviour Arbor.MCP.Server.HTTP.ListenerAdapter
  alias Arbor.MCP.Server.HTTP.ListenerAdapter

  @impl true
  def available?, do: Code.ensure_loaded?(Plug.Cowboy)

  @impl true
  def start(plug, plug_opts, opts) do
    with :ok <- ListenerAdapter.ensure_started(Plug.Cowboy, :cowboy, :plug_cowboy) do
      # The dependency is optional; retain the adapter module in a core build.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Plug.Cowboy, :http, [plug, plug_opts, opts])
    end
  end

  @impl true
  def stop(listener, timeout \\ 5_000) do
    ListenerAdapter.bounded(:cowboy, :shutdown, timeout, fn ->
      with :ok <- ListenerAdapter.ensure_started(Plug.Cowboy, :cowboy, :plug_cowboy),
           {:ok, ref} <- lookup_reference(listener) do
        # The Ranch child must be removed rather than restarted after a PID stop.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Plug.Cowboy, :shutdown, [ref])
      end
    end)
  end

  @doc false
  def reference(listener) when is_pid(listener) do
    ListenerAdapter.bounded(:cowboy, :lookup, 5_000, fn -> lookup_reference(listener) end)
  end

  def reference(ref), do: {:ok, ref}

  defp lookup_reference(listener) when is_pid(listener) and node(listener) == node() do
    if available?() do
      # Read only the root supervisor's identities. Ranch.info/0 additionally
      # queries every listener and its connections, so unrelated work can block it.
      case Enum.find(Supervisor.which_children(:ranch_sup), fn
             {{:ranch_listener_sup, _ref}, ^listener, :supervisor, _modules} -> true
             _child -> false
           end) do
        {{:ranch_listener_sup, ref}, ^listener, :supervisor, _modules} -> {:ok, ref}
        nil -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  catch
    :exit, {:noproc, _call} -> {:error, :not_found}
  end

  defp lookup_reference(listener) when is_pid(listener), do: {:error, :invalid_http_listener}
  defp lookup_reference(ref), do: {:ok, ref}
end
