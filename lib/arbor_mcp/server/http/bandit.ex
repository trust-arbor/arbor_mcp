defmodule Arbor.MCP.Server.HTTP.Bandit do
  @moduledoc """
  Optional Bandit listener adapter.

  Install `{:bandit, "~> 1.12 and >= 1.12.5"}` in the host application.
  Listener options are passed to `Bandit.start_link/1`. The returned supervisor
  is linked to the caller and is stopped by PID. Ranch references apply only
  to Cowboy.

  This borrowed adapter uses Bandit's public constructor. A runtime that owns
  its listener (`transport: :http`) separately requires the qualified exact
  Bandit 1.12.5 / Thousand Island 1.5.0 pair. Broader package dependency ranges
  do not widen that owned constructor's support.
  """

  @behaviour Arbor.MCP.Server.HTTP.ListenerAdapter
  alias Arbor.MCP.Server.HTTP.ListenerAdapter

  @impl true
  def available?, do: Code.ensure_loaded?(Elixir.Bandit)

  @impl true
  def start(plug, plug_opts, opts) do
    with :ok <- ListenerAdapter.ensure_started(Elixir.Bandit, :bandit, :bandit) do
      # The dependency is optional; retain the adapter module in a core build.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Elixir.Bandit, :start_link, [Keyword.put(opts, :plug, {plug, plug_opts})])
    end
  end

  @impl true
  def stop(listener, timeout \\ 5_000)

  def stop(listener, timeout) when is_pid(listener) and node(listener) == node() do
    cond do
      not Process.alive?(listener) ->
        {:error, :not_found}

      not listener?(listener) ->
        {:error, :invalid_http_listener}

      true ->
        ListenerAdapter.bounded(:bandit, :shutdown, timeout, fn ->
          Supervisor.stop(listener, :normal, timeout)
        end)
    end
  end

  def stop(_listener, _timeout), do: {:error, :bandit_listener_pid_required}

  @doc false
  def listener?(listener) when is_pid(listener) and node(listener) == node(),
    do: :proc_lib.translate_initial_call(listener) == {:supervisor, ThousandIsland.Server, 1}

  def listener?(_listener), do: false
end
