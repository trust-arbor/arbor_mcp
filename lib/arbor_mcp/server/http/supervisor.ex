defmodule Arbor.MCP.Server.HTTP.Supervisor do
  @moduledoc false
  use Supervisor

  alias Arbor.MCP.Server.HTTP.Bandit.Owned, as: OwnedBandit
  alias Arbor.MCP.Server.HTTP.Cowboy.Owned
  alias Arbor.MCP.Server.HTTP.{CowboyClaims, Lifetime, ListenerAdapter}
  alias Arbor.MCP.Server.Runtime.{Diagnostics, Initialization, Ref}

  def start_link(opts) do
    table = Ref.table(Keyword.fetch!(opts, :runtime))

    with :ok <- Initialization.edge_start(table),
         {:ok, context} <- Initialization.current(table) do
      Initialization.start_supervisor(__MODULE__, fn -> opts end, context.deadline)
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: Keyword.fetch!(opts, :config).shutdown_timeout_ms
    }
  end

  @impl true
  def init(constructor) do
    opts = constructor.()
    runtime = Keyword.fetch!(opts, :runtime)
    table = Ref.table(runtime)
    config = Keyword.fetch!(opts, :config)
    http = config.http

    with :ok <- Initialization.watch(table, self()),
         :ok <- prepare_claim(http, runtime),
         :ok <- ensure_backend(http.backend),
         {:ok, listener_spec} <- backend_spec(http, runtime) do
      {module, function, arguments} = listener_spec.start
      start = fn -> start_listener(module, function, arguments, runtime, http) end

      listener_spec =
        listener_spec
        |> Map.put(:id, :listener)
        |> Map.put(:restart, :temporary)
        |> Map.put(:shutdown, config.shutdown_timeout_ms)
        |> Map.put(:start, {Diagnostics, :start_child, [start]})

      children = [listener_spec, Diagnostics.child_spec({Lifetime, opts})]
      Supervisor.init(children, strategy: :one_for_one)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp ensure_backend(:cowboy),
    do: ListenerAdapter.ensure_started(Plug.Cowboy, :cowboy, :plug_cowboy)

  defp ensure_backend(:bandit),
    do: ListenerAdapter.ensure_started(Elixir.Bandit, :bandit, :bandit)

  defp backend_spec(%{backend: :cowboy} = http, runtime) do
    options = [
      scheme: :http,
      plug: {Arbor.MCP.HttpPlug, plug_options(http, runtime)},
      options: http.listener_options
    ]

    # The selected package is optional in a core-only production graph.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    spec = apply(Plug.Cowboy, :child_spec, [options])

    case spec.start do
      {:ranch_listener_sup, :start_link, arguments} ->
        owned = %{role: :listener, arguments: arguments, runtime: runtime, lease: http.lease}
        {:ok, %{spec | start: {Owned, :start_link, [owned]}, modules: [Owned]}}

      _unsupported ->
        {:error, :unsupported_owned_ranch_constructor}
    end
  end

  defp backend_spec(%{backend: :bandit} = http, runtime) do
    options =
      Keyword.put(http.listener_options, :plug, {Arbor.MCP.HttpPlug, plug_options(http, runtime)})

    spec = %{
      id: :listener,
      start: {OwnedBandit, :start_link, [runtime, options]},
      type: :supervisor,
      restart: :permanent
    }

    {:ok, spec}
  end

  defp prepare_claim(%{backend: :cowboy} = http, runtime) do
    {:ok, context} = Initialization.current(Ref.table(runtime))
    CowboyClaims.prepare(http.lease, runtime, context)
  end

  defp prepare_claim(_http, _runtime), do: :ok

  defp publish_claim(%{backend: :cowboy} = http, listener, deadline),
    do: CowboyClaims.published(http.lease, listener, deadline)

  defp publish_claim(_http, _listener, _deadline), do: :ok

  defp plug_options(http, runtime), do: Keyword.put(http.plug_options, :runtime, runtime)

  defp start_listener(module, function, arguments, runtime, http) do
    table = Ref.table(runtime)

    with {:ok, context} <- Initialization.current(table),
         true <- Initialization.current?(table, context),
         {:ok, listener} <- apply(module, function, arguments),
         :ok <- Initialization.watch(table, listener, :supervisor),
         :ok <- publish_claim(http, listener, context.deadline),
         true <- Initialization.current?(table, context) do
      info = %{listener: listener, adapter: http.backend, ranch_ref: http.ranch_ref}
      :ets.insert(table, {:http_listener, info})

      if Initialization.current?(table, context),
        do: {:ok, listener},
        else: {:error, :runtime_init_timeout}
    else
      false -> {:error, :runtime_init_timeout}
      error -> error
    end
  end
end
