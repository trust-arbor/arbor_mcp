defmodule Arbor.MCP.Server.HTTP.Bandit.Owned do
  @moduledoc false
  use Supervisor
  require Logger

  alias Arbor.MCP.Server.HTTP.Bandit.{Connection, Dynamic, Options, Worker}
  alias Arbor.MCP.Server.Runtime.{Diagnostics, Initialization, Ref}

  @supervisors [
    ThousandIsland.Server,
    ThousandIsland.AcceptorPoolSupervisor,
    ThousandIsland.AcceptorSupervisor
  ]
  @workers [ThousandIsland.Listener, ThousandIsland.ShutdownListener]

  def compatible? do
    Application.load(:bandit)
    Application.load(:thousand_island)

    Application.spec(:bandit, :vsn) == ~c"1.12.5" and
      Application.spec(:thousand_island, :vsn) == ~c"1.5.0" and
      Enum.all?(
        @supervisors ++ @workers,
        &(Code.ensure_loaded?(&1) and function_exported?(&1, :init, 1))
      ) and
      Code.ensure_loaded?(ThousandIsland.Acceptor) and
      function_exported?(ThousandIsland.Acceptor, :run, 1)
  end

  def start_link(runtime, options) do
    config = Options.compile(options)

    config = %{
      config
      | handler_module: Connection,
        handler_options: {runtime, config.handler_options}
    }

    result = start_role(runtime, ThousandIsland.Server, config)

    if match?({:ok, _}, result) and Keyword.get(options, :startup_log, :info) do
      Logger.log(Keyword.get(options, :startup_log, :info), "Running MCP owned Bandit listener")
    end

    result
  rescue
    _ -> {:error, :http_listener_start_failed}
  end

  def start_role(runtime, module, argument) when module in @supervisors do
    table = Ref.table(runtime)

    Initialization.start_supervisor(
      __MODULE__,
      fn -> {runtime, module, argument} end,
      Initialization.current(table) |> elem(1) |> Map.fetch!(:deadline)
    )
  end

  @impl true
  def init(constructor) do
    {runtime, module, argument} = constructor.()

    with :ok <- Initialization.watch(Ref.table(runtime), self()),
         {:ok, {flags, children}} <- invoke(module, :init, [argument]) do
      {:ok, {flags, Enum.map(children, &owned_child(&1, runtime))}}
    else
      _ -> {:stop, :http_listener_start_failed}
    end
  catch
    _kind, _reason -> {:stop, :http_listener_start_failed}
  end

  defp owned_child(%{start: {module, :start_link, [argument]}} = spec, runtime)
       when module in @supervisors do
    owned_spec(spec, fn -> start_role(runtime, module, argument) end, __MODULE__)
  end

  defp owned_child(%{start: {module, :start_link, [argument]}} = spec, runtime)
       when module in @workers do
    owned_spec(spec, fn -> Worker.start_link(runtime, module, argument) end, Worker)
  end

  defp owned_child(%{start: {DynamicSupervisor, :start_link, [argument]}} = spec, runtime) do
    owned_spec(spec, fn -> Dynamic.start_link(runtime, argument) end, Dynamic)
  end

  defp owned_child(%{start: {ThousandIsland.Acceptor, :start_link, [argument]}} = spec, runtime) do
    parent = self()

    owned_spec(
      spec,
      fn ->
        :proc_lib.start_link(
          __MODULE__,
          :init_acceptor,
          [fn -> {runtime, parent, argument} end],
          Initialization.remaining(Ref.table(runtime))
        )
      end,
      __MODULE__
    )
  end

  defp owned_spec(spec, start, module),
    do:
      spec |> Map.put(:start, {Diagnostics, :start_child, [start]}) |> Map.put(:modules, [module])

  @doc false
  @spec init_acceptor((-> {Ref.t(), pid(), term()})) :: no_return()
  def init_acceptor(constructor) do
    {runtime, parent, argument} = constructor.()

    case Initialization.watch(Ref.table(runtime), self()) do
      :ok ->
        :proc_lib.init_ack(parent, {:ok, self()})
        invoke(ThousandIsland.Acceptor, :run, [argument])
        exit(:normal)

      _ ->
        :proc_lib.init_fail(
          parent,
          {:error, :http_listener_start_failed},
          {:exit, :http_listener_start_failed}
        )
    end
  catch
    _kind, _reason -> exit(:http_acceptor_failed)
  end

  defp invoke(module, function, arguments) do
    # The delegated backend is optional and guarded by the exact constructor ABI.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(module, function, arguments)
  end
end
