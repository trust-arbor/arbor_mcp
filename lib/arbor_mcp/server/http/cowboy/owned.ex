defmodule Arbor.MCP.Server.HTTP.Cowboy.Owned do
  @moduledoc false
  use Supervisor

  alias Arbor.MCP.Server.HTTP.CowboyClaims
  alias Arbor.MCP.Server.Runtime.{Diagnostics, Initialization, Ref}

  @version ~c"1.8.1"

  def compatible? do
    Application.load(:ranch)

    Application.spec(:ranch, :vsn) == @version and child_shape?() and
      Enum.all?(
        [
          {:ranch_listener_sup, :init, 1},
          {:ranch_acceptors_sup, :init, 1},
          {:ranch_conns_sup, :init, 4},
          {:ranch_server, :set_new_listener_opts, 5}
        ],
        fn {module, function, arity} ->
          Code.ensure_loaded?(module) and function_exported?(module, function, arity)
        end
      )
  end

  defp child_shape? do
    case :ranch.child_spec(:arbor_mcp_constructor_probe, :ranch_tcp, %{}, :cowboy_clear, %{}) do
      {{:ranch_listener_sup, :arbor_mcp_constructor_probe},
       {:ranch_listener_sup, :start_link, _arguments}, :permanent, :infinity, :supervisor,
       [:ranch_listener_sup]} ->
        true

      _unsupported ->
        false
    end
  end

  def start_link(opts) do
    table = Ref.table(opts.runtime)
    Initialization.start_supervisor(__MODULE__, fn -> opts end, startup_deadline(table))
  end

  @impl true
  def init(constructor) do
    opts = constructor.()

    case register(opts) do
      :ok -> init_role(opts)
      _ -> {:stop, :http_listener_start_failed}
    end
  catch
    :exit, {:listen_error, _ref, reason} ->
      {:stop, {:http_listener_start_failed, safe_reason(reason)}}

    _kind, _reason ->
      {:stop, :http_listener_start_failed}
  end

  defp init_role(
         %{role: :listener, arguments: [ref, transport, trans_opts, protocol, proto_opts]} = opts
       ) do
    trans_opts =
      trans_opts
      |> Map.put(:logger, Arbor.MCP.Server.HTTP.Cowboy.SafeLogger)
      |> CowboyClaims.tag_transport(opts.lease)

    :ok =
      :ranch_server.set_new_listener_opts(
        ref,
        Map.get(trans_opts, :max_connections, 1024),
        trans_opts,
        proto_opts,
        [ref, transport, trans_opts, protocol, proto_opts]
      )

    {:ok, {flags, children}} = :ranch_listener_sup.init({ref, transport, protocol})
    children = Enum.map(children, &owned_child(&1, opts))
    {:ok, {supervisor_flags(flags), children}}
  end

  defp init_role(%{role: :acceptors, arguments: arguments}) do
    {:ok, {flags, children}} = :ranch_acceptors_sup.init(arguments)
    {:ok, {supervisor_flags(flags), children}}
  end

  defp supervisor_flags({strategy, intensity, period}),
    do: %{strategy: strategy, intensity: intensity, period: period}

  defp owned_child(
         {:ranch_conns_sup, {:ranch_conns_sup, :start_link, arguments}, restart, shutdown, type,
          _},
         opts
       ) do
    constructor = fn -> start_connections(%{opts | role: :connections, arguments: arguments}) end

    {:ranch_conns_sup, {Diagnostics, :start_child, [constructor]}, restart, shutdown, type,
     [__MODULE__]}
  end

  defp owned_child(
         {:ranch_acceptors_sup, {:ranch_acceptors_sup, :start_link, arguments}, restart, shutdown,
          type, _},
         opts
       ) do
    constructor = fn -> start_link(%{opts | role: :acceptors, arguments: arguments}) end

    {:ranch_acceptors_sup, {Diagnostics, :start_child, [constructor]}, restart, shutdown, type,
     [__MODULE__]}
  end

  defp start_connections(opts) do
    parent = self()

    :proc_lib.start_link(
      __MODULE__,
      :init_connections,
      [fn -> {parent, opts} end],
      Initialization.remaining(Ref.table(opts.runtime))
    )
  end

  @doc false
  @spec init_connections((-> {pid(), map()})) :: no_return()
  def init_connections(constructor) do
    {parent, opts} = constructor.()
    [ref, transport, protocol] = opts.arguments

    case register(opts) do
      :ok ->
        :ranch_conns_sup.init(parent, ref, transport, protocol)

      _ ->
        :proc_lib.init_fail(
          parent,
          {:error, :http_listener_start_failed},
          {:exit, :http_listener_start_failed}
        )
    end
  catch
    _kind, _reason -> exit(:http_listener_start_failed)
  end

  defp register(opts) do
    table = Ref.table(opts.runtime)

    with :ok <- Initialization.watch(table, self()),
         do: CowboyClaims.register(opts.lease, self(), opts.role, startup_deadline(table))
  end

  defp startup_deadline(table) do
    {:ok, context} = Initialization.current(table)
    context.deadline
  end

  defp safe_reason(reason) when reason in [:eaddrinuse, :eacces, :eaddrnotavail], do: reason
  defp safe_reason(_), do: :listener_failed
end
