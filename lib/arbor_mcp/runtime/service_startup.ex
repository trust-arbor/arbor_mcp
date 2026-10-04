defmodule Arbor.MCP.Server.Runtime.ServiceStartup do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.{Deadline, Initialization, ShutdownGuard}

  def arm(table, generation, deadline) do
    caller = self()
    token = make_ref()

    {observer, monitor} =
      spawn_monitor(fn ->
        observe(table, generation, deadline, Process.monitor(caller), token, %{})
      end)

    :ets.insert(table, {:service_start_observer, generation, observer})

    with true <- current?(table, generation, deadline),
         :ok <- ShutdownGuard.watch(table, observer, :worker, deadline) do
      {:ok, {observer, monitor, token}}
    else
      _failed ->
        abort_cohort(table, generation, deadline)
        disarm(table, generation, {observer, monitor, token})
        {:error, :service_start_timeout}
    end
  end

  def disarm(table, generation, {observer, monitor, token}) do
    send(observer, {token, :done})
    Process.exit(observer, :kill)
    Process.demonitor(monitor, [:flush])

    case :ets.lookup(table, :service_start_observer) do
      [{:service_start_observer, ^generation, ^observer}] ->
        :ets.delete(table, :service_start_observer)

      _other ->
        :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def current?(table, generation, deadline) do
    Deadline.validate(deadline) == :ok and is_integer(deadline) and Deadline.now() < deadline and
      :ets.lookup(table, :services_startup) == [
        {:services_startup, generation, deadline, :starting}
      ]
  rescue
    ArgumentError -> false
  end

  def remaining(deadline), do: min(4_294_967_295, max(0, deadline - Deadline.now()))

  def register(table, pid, starter, deadline) do
    with [{:services_startup, generation, ^deadline, :starting}] <-
           :ets.lookup(table, :services_startup),
         true <- current?(table, generation, deadline) do
      # Publish provenance before a potentially blocked guard call. The cohort
      # observer can clean these owned PIDs even when its guard is suspended.
      :ets.insert(table, [
        {{:service_owner, pid}, %{starter: starter}},
        {{:service_start_owned, generation, pid}, true}
      ])

      with [{:service_start_observer, ^generation, observer}] <-
             :ets.lookup(table, :service_start_observer),
           :ok <- Initialization.track(table, pid),
           :ok <- GenServer.call(observer, {:owned, generation, pid}, remaining(deadline)),
           true <- current?(table, generation, deadline) do
        ShutdownGuard.watch(table, pid, :worker, deadline)
      else
        _expired -> {:error, :service_start_timeout}
      end
    else
      _expired -> {:error, :service_start_timeout}
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  catch
    :exit, _reason -> {:error, :service_start_timeout}
  end

  def abort_cohort(table, generation, deadline) do
    case :ets.lookup(table, :services_startup) do
      [{:services_startup, ^generation, ^deadline, status}] when status in [:starting, :ready] ->
        :ets.insert(table, {:services_startup, generation, deadline, :failed})

      _other ->
        :ok
    end

    case :ets.lookup(table, :service_listeners) do
      [{:service_listeners, pid}] ->
        if :ets.member(table, {:service_start_owned, generation, pid}) or not Process.alive?(pid),
          do: :ets.delete(table, :service_listeners)

      _other ->
        :ok
    end

    kill_cohort(table, generation)

    for {{:service, kind}, %{generation: ^generation}} <-
          :ets.match_object(table, {{:service, :_}, :_}),
        do: :ets.delete(table, {:service, kind})

    case :ets.lookup(table, :services_generation) do
      [{:services_generation, ^generation, _pid}] -> :ets.delete(table, :services_generation)
      _other -> :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def kill_cohort(table, generation) do
    for {{:service_start_owned, ^generation, pid}, true} <-
          :ets.match_object(table, {{:service_start_owned, generation, :_}, :_}) do
      if pid != self(), do: Process.exit(pid, :kill)
      :ets.delete(table, {:service_start_owned, generation, pid})
      :ets.delete(table, {:service_owner, pid})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp observe(table, generation, deadline, parent, token, owned) do
    receive do
      {:"$gen_call", from, {:owned, ^generation, pid}} ->
        if current?(table, generation, deadline) do
          owned = Map.put(owned, pid, true)
          GenServer.reply(from, :ok)
          observe(table, generation, deadline, parent, token, owned)
        else
          GenServer.reply(from, {:error, :service_start_timeout})
          abort_cohort(table, generation, deadline)
          kill_known(owned)
        end

      {^token, :done} ->
        :ok

      {:DOWN, ^parent, :process, _caller, _reason} ->
        abort_cohort(table, generation, deadline)
        kill_known(owned)
    after
      remaining(deadline) ->
        case :ets.lookup(table, :services_startup) do
          [{:services_startup, ^generation, ^deadline, :starting}] ->
            abort_cohort(table, generation, deadline)
            kill_known(owned)

          _finished ->
            :ok
        end
    end
  rescue
    ArgumentError -> kill_known(owned)
  end

  defp kill_known(owned), do: Enum.each(owned, fn {pid, true} -> Process.exit(pid, :kill) end)
end
