defmodule Arbor.MCP.Server.HTTP.Cowboy do
  @moduledoc """
  Optional Cowboy listener adapter.

  Install `{:plug_cowboy, "~> 2.7"}` in the host application. Listener options
  are passed to `Plug.Cowboy.http/3`; `:ref` keeps its Ranch meaning, including
  the default `Arbor.MCP.HttpPlug.HTTP` reference. Stop by the Ranch reference
  or the returned listener PID to remove the listener from Ranch supervision.

  Host-managed listeners may use compatible Ranch 1.x or 2.x within the package
  requirements. A runtime that owns its listener (`transport: :http`) separately
  requires the qualified Ranch 1.8.1 constructor; mounting `HttpPlug` with
  `transport: :mounted_http` does not invoke that owned constructor.
  """

  @behaviour Arbor.MCP.Server.HTTP.ListenerAdapter
  alias Arbor.MCP.Server.HTTP.{CowboyClaims, ListenerAdapter}
  alias Arbor.MCP.Server.Runtime.Deadline

  @impl true
  def available?, do: Code.ensure_loaded?(Plug.Cowboy)

  @impl true
  def start(plug, plug_opts, opts) do
    deadline = Deadline.now() + 10_000
    reference = Keyword.get(opts, :ref) || Module.concat(plug, HTTP)

    with :ok <- ListenerAdapter.ensure_started(Plug.Cowboy, :cowboy, :plug_cowboy),
         {:ok, lease} <- CowboyClaims.borrowed(reference, deadline) do
      # The dependency is optional; retain the adapter module in a core build.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      result = apply(Plug.Cowboy, :http, [plug, plug_opts, opts])
      # This is settlement of an actual result, not permission for new effects.
      # A slow host Plug constructor may outlive its initial claim wait; keep
      # exclusion until that known result or the original starter's actual DOWN.
      CowboyClaims.borrowed_done(lease, result, Deadline.now() + 1_000)
      result
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
