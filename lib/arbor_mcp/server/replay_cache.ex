defmodule Arbor.MCP.Server.ReplayCache do
  @moduledoc """
  Behaviour for atomically consuming MRTR continuation identifiers.

  A replay cache is optional because consuming a token changes ambiguous
  network failure semantics. Enable one for resumed handlers that may cause
  side effects; otherwise `Arbor.MCP.Server.RequestContext.delivery_semantics` is
  explicitly `:at_least_once`.
  """

  alias Arbor.MCP.Server.Runtime.Services

  @callback consume(jti :: String.t(), expires_at :: integer(), opts :: keyword()) ::
              :ok | {:error, :replayed | term()}

  @doc "Consumes a continuation ID through an explicitly addressed runtime replay service."
  def consume(service, jti, expires_at),
    do: Services.consume(service, jti, expires_at)
end

defmodule Arbor.MCP.Server.ReplayCache.Runtime do
  @moduledoc false
  @behaviour Arbor.MCP.Server.ReplayCache

  alias Arbor.MCP.Server.Runtime.Services

  @impl true
  def consume(jti, expires_at, opts),
    do: Services.consume(opts[:runtime], jti, expires_at)
end

defmodule Arbor.MCP.Server.ReplayCache.ETS do
  @moduledoc """
  Node-local atomic replay cache for MRTR request state.

  Clustered servers should configure an adapter backed by their shared
  consistency store instead.
  """

  use GenServer

  @impl true
  def format_status(status),
    do: Arbor.MCP.Server.Runtime.Diagnostics.format_status(status, __MODULE__)

  @behaviour Arbor.MCP.Server.ReplayCache

  @name __MODULE__

  alias Arbor.MCP.Server.Runtime.{ServiceAdapter, ServiceOperation}

  def start_link(opts \\ []) do
    server_opts = [timeout: Keyword.get(opts, :init_timeout_ms, :infinity)]

    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts, server_opts)
      name -> GenServer.start_link(__MODULE__, opts, Keyword.put(server_opts, :name, name))
    end
  end

  @doc false
  def runtime_service_capabilities, do: %{bounded_startup: 1, bounded_operations: 1}

  @doc false
  def runtime_service_binding(server, timeout),
    do: GenServer.call(server, :service_binding, timeout)

  @doc false
  def operate(operation, args, context, opts),
    do: ServiceOperation.submit(opts[:service_address], operation, args, context)

  @impl Arbor.MCP.Server.ReplayCache
  def consume(jti, expires_at, opts \\ [])
      when is_binary(jti) and is_integer(expires_at) do
    server = Keyword.get(opts, :server, @name)

    case ServiceOperation.native_call(server, :consume, [jti, expires_at], opts) do
      {:error, :service_unavailable} ->
        {:error, {:replay_cache_unavailable, :service_unavailable}}

      result ->
        result
    end
  catch
    :exit, reason -> {:error, {:replay_cache_unavailable, reason}}
  end

  @impl GenServer
  def init(opts) do
    with :ok <- ServiceAdapter.watch_owned(opts),
         {:ok, address} <- ServiceOperation.new(opts),
         {:ok, limits} <- limits(opts) do
      ServiceOperation.publish(address)
      Process.send_after(self(), :service_reap, 25)

      {:ok,
       %{
         entries: %{},
         expiry_queue: :gb_sets.empty(),
         retained_bytes: 0,
         limits: limits,
         address: address,
         operation_offset: 0,
         reap_offset: 0
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:service_binding, _from, state),
    do: {:reply, %{address: state.address, read_address: nil}, state}

  @impl GenServer
  def handle_info(:service_operations, state) do
    {state, offset} =
      ServiceOperation.run(state.address, state, state.operation_offset, &execute/4)

    {:noreply, %{state | operation_offset: offset}}
  end

  def handle_info(:service_reap, state) do
    offset = ServiceOperation.reap(state.address, state.reap_offset)
    state = expire(state)
    Process.send_after(self(), :service_reap, 25)
    {:noreply, %{state | reap_offset: offset}}
  end

  defp execute(:consume, [jti, expires_at], context, state) do
    state = state |> expire() |> expire_id(jti, System.system_time(:second))
    bytes = :erlang.external_size({jti, expires_at})
    now = System.system_time(:second)

    result =
      cond do
        not valid_identifier?(jti, state.limits) ->
          {:error, :invalid_replay_id}

        not valid_expiry?(expires_at, now, state.limits) ->
          {:error, :invalid_replay_expiry}

        Map.has_key?(state.entries, jti) ->
          {:error, :replayed}

        map_size(state.entries) >= state.limits.max_replay_entries or
            state.retained_bytes + bytes > state.limits.max_replay_bytes ->
          {:error, :replay_cache_full}

        true ->
          ServiceOperation.validate_context(context)
      end

    if result == :ok do
      {:ok,
       %{
         state
         | entries: Map.put(state.entries, jti, expires_at),
           retained_bytes: state.retained_bytes + bytes,
           expiry_queue: :gb_sets.add({expires_at, jti}, state.expiry_queue)
       }}
    else
      {result, state}
    end
  end

  defp valid_identifier?(jti, limits),
    do: is_binary(jti) and byte_size(jti) > 0 and byte_size(jti) <= limits.max_replay_id_bytes

  defp valid_expiry?(expires_at, now, limits),
    do:
      is_integer(expires_at) and expires_at >= now and
        (expires_at - now) * 1_000 <= limits.max_replay_ttl_ms

  defp expire(state) do
    expire_turn(state, System.system_time(:second), System.monotonic_time(:millisecond) + 5, 32)
  end

  defp expire_turn(state, _now, _cutoff, 0), do: state

  defp expire_turn(state, now, cutoff, remaining) do
    if not :gb_sets.is_empty(state.expiry_queue) and
         System.monotonic_time(:millisecond) < cutoff do
      {expiry, jti} = :gb_sets.smallest(state.expiry_queue)

      if expiry < now,
        do: expire_turn(remove_entry(state, jti), now, cutoff, remaining - 1),
        else: state
    else
      state
    end
  end

  defp expire_id(state, jti, now) do
    case state.entries[jti] do
      expiry when is_integer(expiry) and expiry < now -> remove_entry(state, jti)
      _current -> state
    end
  end

  defp remove_entry(state, jti) do
    {expiry, entries} = Map.pop(state.entries, jti)

    %{
      state
      | entries: entries,
        retained_bytes: state.retained_bytes - :erlang.external_size({jti, expiry}),
        expiry_queue: :gb_sets.delete({expiry, jti}, state.expiry_queue)
    }
  end

  defp limits(opts) do
    limits =
      Map.new(
        [
          max_replay_entries: 10_000,
          max_replay_bytes: 8_000_000,
          max_replay_id_bytes: 4_096,
          max_replay_ttl_ms: 2_592_000_000
        ],
        fn {key, default} ->
          {key, Keyword.get(opts, key, default)}
        end
      )

    if Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end),
      do: {:ok, limits},
      else: {:error, :invalid_replay_limits}
  end
end
