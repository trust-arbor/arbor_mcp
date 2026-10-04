defmodule Arbor.MCP.Server.Stdio.OutputAuthority do
  @moduledoc false
  use GenServer

  alias Arbor.MCP.Server.Runtime.{Deadline, Initialization, Ref}
  alias Arbor.MCP.Server.Stdio.OutputAuthority.Control
  alias Arbor.MCP.Server.Stdio.OutputAuthority.Ref, as: AuthorityRef
  alias Arbor.MCP.Server.Stdio.{OutputLease, Writer}
  alias Arbor.RPC.StdioFraming

  @anchor {__MODULE__, :default_identity}
  @limit 64
  @maintenance 10

  # This authority belongs to the logical IO endpoint, never to a Runtime.
  # It is intentionally not restarted after loss: the retained anchor prevents
  # silently forgetting an IO request that its borrowed device may still hold.
  def default(deadline) do
    case :persistent_term.get(@anchor, nil) do
      nil -> start_default(deadline)
      ref -> AuthorityRef.validate(ref)
    end
  end

  # Unnamed authorities are private fixture domains. Their refs never replace
  # the production anchor and a dead ref has no fallback to another domain.
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def reference(pid) when is_pid(pid) and node(pid) == node() do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, {__MODULE__, :reference}, 0) do
          {_, ref} -> AuthorityRef.validate(ref)
          _ -> {:error, :stdio_output_unavailable}
        end

      _ ->
        {:error, :stdio_output_unavailable}
    end
  end

  def reference(_), do: {:error, :stdio_output_unavailable}

  def acquire(ref, device, config, deadline) do
    with {:ok, _} <- AuthorityRef.validate(ref),
         {:ok, pid, key} <- capture_device(device) do
      limits =
        Map.take(config, [
          :max_output_frames,
          :max_output_bytes,
          :max_output_frame_bytes,
          :max_output_term_bytes,
          :max_output_scope_bytes
        ])

      Control.call(ref, {:acquire, pid, key, limits}, deadline)
    end
  end

  def bind(lease, runtime, deadline) do
    with {:ok, info} <- OutputLease.info(lease),
         {:ok, _} <- Ref.validate(runtime) do
      Control.call(info.authority, {:bind, info.token, runtime}, deadline)
    end
  end

  def execution_boundary(lease, table, context) do
    with {:ok, info} <- OutputLease.info(lease),
         true <- Initialization.current?(table, context),
         runtime = Ref.new(:ets.info(table, :owner), table),
         :ok <-
           Control.call(
             info.authority,
             {:execution_boundary, info.token, runtime, context.epoch},
             context.deadline
           ),
         true <- Initialization.current?(table, context) do
      :ok
    else
      _ -> {:error, :stdio_output_unsettled}
    end
  rescue
    ArgumentError -> {:error, :stdio_output_unsettled}
  end

  def write(lease, wire, deadline, epoch) when is_binary(wire) do
    with {:ok, info} <- OutputLease.info(lease),
         [{_, %{writer: writer, frame_limit: limit, epoch: ^epoch}}] <-
           :ets.lookup(AuthorityRef.table(info.authority), {:lease, info.token}),
         true <- writer == self() and byte_size(wire) + 1 <= limit do
      Control.call(info.authority, {:write, info.token, wire, epoch}, deadline)
    else
      _ -> {:error, :stdio_output_unavailable}
    end
  rescue
    ArgumentError -> {:error, :stdio_output_unavailable}
  end

  def write(_, _, _, _), do: {:error, :stdio_output_unavailable}

  def release(lease, deadline) do
    with {:ok, info} <- OutputLease.info(lease),
         do: Control.call(info.authority, {:release, info.token}, deadline)
  end

  def stats(ref, deadline), do: Control.call(ref, :stats, deadline)

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    # Reference validation uses the exact identity stored in the table.
    ref = initialize_reference(table)
    Process.put({__MODULE__, :reference}, ref)
    :ok = Control.initialize(table)

    if opts[:global] do
      case :persistent_term.get(@anchor, nil) do
        nil -> :persistent_term.put(@anchor, ref)
        _ -> throw(:stdio_output_authority_poisoned)
      end
    end

    Process.send_after(self(), :maintenance, @maintenance)
    {:ok, %{ref: ref, table: table, domains: %{}, aliases: %{}, monitors: %{}}}
  catch
    :stdio_output_authority_poisoned -> {:stop, :stdio_output_unavailable}
  end

  @impl true
  def handle_info(:stdio_output_wake, state) do
    :ets.delete(state.table, :wake)
    {:noreply, drain(state)}
  end

  def handle_info(:maintenance, state) do
    state = state |> reap_domains() |> drain()
    Process.send_after(self(), :maintenance, @maintenance)
    {:noreply, state}
  end

  def handle_info({:stdio_physical_result, sender, nonce, result}, state) do
    case Enum.find(state.domains, fn {_device, domain} ->
           domain.io && domain.io.pid == sender && domain.io.nonce == nonce
         end) do
      {device, domain} ->
        # Only this nonce-authenticated receipt proves the borrowed device has
        # completed its IO request. Keep the charge until our owned sender is
        # also DOWN, so completed but suspended senders cannot accumulate.
        domain = %{domain | io: Map.put(domain.io, :result, {:known, result})}
        Process.exit(sender, :kill)
        {:noreply, state |> put_domain(device, domain) |> reap_domains() |> drain()}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        {:noreply, state}

      {{device, kind, ^pid}, monitors} ->
        state = %{state | monitors: monitors}

        case state.domains[device] do
          nil ->
            {:noreply, state}

          domain ->
            domain = retire_domain(domain, kind, state.table, pid)

            {:noreply, state |> put_domain(device, domain) |> reap_domains() |> drain()}
        end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp retire_domain(%{io: %{pid: pid, result: {:known, result}}} = domain, :sender, table, pid) do
    reply_io(table, domain.io.reply, result)
    %{domain | io: nil, poisoned: domain.poisoned or result != :ok}
  end

  defp retire_domain(%{io: %{pid: pid} = io} = domain, :sender, table, pid) do
    reply_io(table, io.reply, {:error, :stdio_output_uncertain})
    %{domain | poisoned: true, io: %{io | reply: nil}}
  end

  defp retire_domain(domain, :sender, _table, _pid), do: domain
  defp retire_domain(domain, :device, _table, _pid), do: %{domain | poisoned: true}

  defp retire_domain(%{root: pid} = domain, :root, _table, pid),
    do: %{domain | root: nil, starter: nil}

  defp retire_domain(%{writer: pid} = domain, :writer, _table, pid), do: %{domain | writer: nil}

  defp retire_domain(%{starter: pid} = domain, :starter, _table, pid),
    do: if(domain.root == nil, do: %{domain | starter: nil}, else: domain)

  defp retire_domain(domain, _kind, _table, _pid), do: domain

  @impl true
  def format_status(status),
    do: %{status | state: %{stdio_output_devices: map_size(status.state.domains)}, log: []}

  defp initialize_reference(table) do
    identity = make_ref()
    :ets.insert(table, {:identity, identity})
    AuthorityRef.new(self(), table, identity)
  end

  defp drain(state) do
    Enum.reduce(Control.entries(state.table), state, fn {slot, entry}, state ->
      cond do
        expired?(entry) ->
          :atomics.put(entry.phase, 1, 4)
          Control.release(state.table, slot, entry.token)
          state

        Control.waiting?(entry) and acquire_command?(entry.command) ->
          acquire(entry, slot, state)

        Control.claim(entry) ->
          dispatch(entry, slot, state)

        true ->
          state
      end
    end)
  end

  defp dispatch(%{command: {:acquire, _, _, _}} = entry, slot, state),
    do: acquire(entry, slot, state)

  defp dispatch(%{command: {:bind, token, runtime}} = entry, slot, state) do
    with {device, domain} <- find_lease(state, token),
         true <- Control.active?(entry) and not domain.poisoned,
         {:ok, context} <- Initialization.current(Ref.table(runtime)),
         true <- Initialization.current?(Ref.table(runtime), context),
         true <- bindable?(domain, runtime, context),
         true <- native_writer?(entry.caller, runtime),
         true <- domain.io == nil do
      root = Ref.supervisor(runtime)
      domain = %{domain | root: root, writer: entry.caller, bound?: true, epoch: context.epoch}

      state =
        state
        |> ensure_root_monitor(device, root)
        |> monitor(device, :writer, entry.caller)
        |> put_domain(device, domain)

      :ets.insert(
        state.table,
        {{:lease, token},
         %{
           writer: entry.caller,
           epoch: context.epoch,
           frame_limit: min(domain.limits.max_output_frame_bytes, domain.limits.max_output_bytes)
         }}
      )

      finish(state, slot, entry, :ok)
    else
      _ -> finish(state, slot, entry, {:error, :stdio_output_unavailable})
    end
  end

  defp dispatch(%{command: {:execution_boundary, token, runtime, epoch}} = entry, slot, state) do
    with {device, domain} <- find_lease(state, token),
         true <- Control.active?(entry) and not domain.poisoned and domain.io == nil,
         true <- Ref.valid?(runtime) and domain.root == Ref.supervisor(runtime),
         {:ok, %{epoch: ^epoch} = context} <- Initialization.current(Ref.table(runtime)),
         true <- Initialization.current?(Ref.table(runtime), context),
         false <- pending_write?(state.table, token) do
      domain = %{domain | epoch: epoch}
      state = put_domain(state, device, domain)
      update_lease_epoch(state.table, token, epoch)
      finish(state, slot, entry, :ok)
    else
      _ -> finish(state, slot, entry, {:error, :stdio_output_unsettled})
    end
  end

  defp dispatch(%{command: {:write, token, wire, epoch}} = entry, slot, state) do
    with {device, domain} <- find_lease(state, token),
         true <- Control.active?(entry) and not domain.poisoned and domain.io == nil,
         true <- domain.writer == entry.caller and alive?(domain.root),
         true <- domain.epoch == epoch,
         true <-
           byte_size(wire) + 1 <=
             min(domain.limits.max_output_frame_bytes, domain.limits.max_output_bytes) do
      nonce = make_ref()
      authority = self()

      {sender, sender_monitor} =
        spawn_monitor(fn ->
          receive do
            {:stdio_physical_go, ^nonce} ->
              result = StdioFraming.write_frame(device, wire)
              send(authority, {:stdio_physical_result, self(), nonce, result})
          end
        end)

      io = %{
        pid: sender,
        monitor: sender_monitor,
        nonce: nonce,
        result: nil,
        bytes: byte_size(wire) + 1,
        reply: {slot, entry.token}
      }

      domain = %{domain | io: io}

      state =
        %{state | monitors: Map.put(state.monitors, sender_monitor, {device, :sender, sender})}
        |> put_domain(device, domain)

      if Control.active?(entry) and alive?(domain.root) do
        # Recorded custody and full endpoint credit precede physical IO.
        send(sender, {:stdio_physical_go, nonce})
        state
      else
        Process.exit(sender, :kill)
        Process.demonitor(sender_monitor, [:flush])

        state =
          %{state | monitors: Map.delete(state.monitors, sender_monitor)}
          |> put_domain(device, %{domain | io: nil})

        finish(state, slot, entry, {:error, :stdio_output_timeout})
      end
    else
      _ -> finish(state, slot, entry, {:error, :stdio_output_unavailable})
    end
  end

  defp dispatch(%{command: {:release, token}} = entry, slot, state) do
    case find_lease(state, token) do
      {device, %{root: nil, starter: starter} = domain} when starter == entry.caller ->
        finish(put_domain(state, device, %{domain | starter: nil}), slot, entry, :ok)
        |> reap_domains()

      _ ->
        finish(state, slot, entry, {:error, :stdio_output_unavailable})
    end
  end

  defp dispatch(%{command: :stats} = entry, slot, state) do
    result = %{
      devices: map_size(state.domains),
      poisoned: Enum.count(state.domains, fn {_, d} -> d.poisoned end),
      frames: Enum.count(state.domains, fn {_, d} -> d.io != nil end),
      bytes:
        Enum.reduce(state.domains, 0, fn {_, d}, n -> n + if(d.io, do: d.io.bytes, else: 0) end),
      monitors: map_size(state.monitors),
      slots: length(Control.entries(state.table))
    }

    finish(state, slot, entry, result)
  end

  defp dispatch(entry, slot, state),
    do: finish(state, slot, entry, {:error, :stdio_output_unavailable})

  defp acquire(%{command: {:acquire, device, key, limits}} = entry, slot, state) do
    state = reap_domains(state)

    case acquisition_status(state, device, key, entry) do
      :wait ->
        state

      {:error, _} = error ->
        finish(state, slot, entry, error)

      :grant ->
        token = make_ref()

        domain = %{
          token: token,
          keys: [key],
          limits: limits,
          deadline: entry.deadline,
          starter: entry.caller,
          root: nil,
          writer: nil,
          bound?: false,
          epoch: nil,
          io: nil,
          poisoned: false
        }

        lease = OutputLease.new(state.ref, token, device, entry.deadline)

        state =
          %{state | aliases: Map.put(state.aliases, key, device)}
          |> put_domain(device, domain)
          |> monitor(device, :device, device)
          |> monitor(device, :starter, entry.caller)

        finish(state, slot, entry, {:ok, lease})
    end
  end

  defp acquisition_status(state, device, key, entry) do
    cond do
      not Control.active?(entry) -> {:error, :stdio_output_timeout}
      not alive?(device) -> {:error, :stdio_output_unavailable}
      state.aliases[key] && state.aliases[key] != device -> {:error, :stdio_output_device_changed}
      true -> domain_status(state.domains[device], state)
    end
  end

  defp domain_status(%{poisoned: true}, _state), do: {:error, :stdio_output_unavailable}
  defp domain_status(%{io: io}, _state) when not is_nil(io), do: :wait
  defp domain_status(domain, _state) when not is_nil(domain), do: {:error, :stdio_output_in_use}

  defp domain_status(nil, state) do
    if map_size(state.domains) >= @limit or map_size(state.aliases) >= @limit,
      do: {:error, :stdio_output_busy},
      else: :grant
  end

  defp reap_domains(state) do
    Enum.reduce(state.domains, state, fn {device, domain}, state ->
      retired =
        if domain.bound?,
          do: not alive?(domain.root),
          else: not alive?(domain.starter) or domain.deadline <= Deadline.now()

      if retired and domain.io == nil and not domain.poisoned,
        do: remove_domain(state, device),
        else: state
    end)
  end

  defp remove_domain(state, device) do
    domain = state.domains[device]
    :ets.delete(state.table, {:lease, domain.token})

    {retired, monitors} =
      Enum.split_with(state.monitors, fn {_ref, {pid, _, _}} -> pid == device end)

    Enum.each(retired, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)

    %{
      state
      | domains: Map.delete(state.domains, device),
        monitors: Map.new(monitors),
        aliases: Map.drop(state.aliases, domain.keys)
    }
  end

  defp finish(state, slot, entry, result) do
    Control.finish(state.table, slot, entry, result)
    state
  end

  defp reply_io(_table, nil, _result), do: :ok

  defp reply_io(table, {slot, token}, result) do
    case :ets.lookup(table, {:slot, slot}) do
      [{{:slot, ^slot}, %{token: ^token} = entry}] -> Control.finish(table, slot, entry, result)
      _ -> :ok
    end
  end

  defp monitor(state, device, kind, pid) do
    {retired, monitors} =
      Enum.split_with(state.monitors, fn {_, {captured, role, _pid}} ->
        captured == device and role == kind
      end)

    Enum.each(retired, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    ref = Process.monitor(pid)
    %{state | monitors: Map.put(Map.new(monitors), ref, {device, kind, pid})}
  end

  defp ensure_root_monitor(state, device, root) do
    if Enum.any?(state.monitors, fn {_, key} -> key == {device, :root, root} end),
      do: state,
      else: monitor(state, device, :root, root)
  end

  defp bindable?(%{bound?: false, root: nil} = domain, _runtime, context),
    do:
      alive?(domain.starter) and domain.deadline > Deadline.now() and
        context.deadline == domain.deadline

  defp bindable?(%{bound?: true} = domain, runtime, context),
    do:
      domain.root == Ref.supervisor(runtime) and not alive?(domain.writer) and
        domain.epoch == context.epoch

  defp bindable?(_domain, _runtime, _context), do: false

  defp pending_write?(table, token) do
    Enum.any?(Control.entries(table), fn {_slot, entry} ->
      match?({:write, ^token, _, _}, entry.command) and
        :atomics.get(entry.phase, 1) in [0, 1, 2] and
        entry.deadline > Deadline.now() and alive?(entry.caller)
    end)
  end

  defp update_lease_epoch(table, token, epoch) do
    case :ets.lookup(table, {:lease, token}) do
      [{key, value}] -> :ets.insert(table, {key, %{value | epoch: epoch}})
      [] -> :ok
    end
  end

  defp put_domain(state, device, domain),
    do: %{state | domains: Map.put(state.domains, device, domain)}

  defp find_lease(state, token),
    do: Enum.find(state.domains, fn {_, domain} -> domain.token == token end)

  defp acquire_command?({:acquire, _, _, _}), do: true
  defp acquire_command?(_), do: false

  defp expired?(entry),
    do:
      entry.deadline <= Deadline.now() or not alive?(entry.caller) or
        :atomics.get(entry.phase, 1) >= 3

  defp alive?(pid), do: is_pid(pid) and node(pid) == node() and Process.alive?(pid)

  defp native_writer?(writer, runtime) do
    Ref.valid?(runtime) and :proc_lib.translate_initial_call(writer) == {Writer, :init, 1} and
      :ets.lookup(Ref.table(runtime), :stdio_writer) == [{:stdio_writer, writer}]
  end

  defp capture_device(device) when is_pid(device) do
    if alive?(device),
      do: {:ok, device, {:pid, device}},
      else: {:error, :stdio_output_unavailable}
  end

  defp capture_device(device) when device in [:stdio, :standard_io],
    do: capture_device(Process.group_leader())

  defp capture_device(name) when is_atom(name) and not is_nil(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid, {:name, name}}
      _ -> {:error, :stdio_output_unavailable}
    end
  end

  defp capture_device(_), do: {:error, :unsupported_stdio_output_device}

  defp start_default(deadline) do
    if Deadline.remaining(deadline) > 0 do
      case GenServer.start(__MODULE__, [global: true],
             name: __MODULE__,
             timeout: Deadline.remaining(deadline)
           ) do
        {:ok, pid} -> reference(pid)
        {:error, {:already_started, pid}} -> await_default(pid, deadline)
        _ -> {:error, :stdio_output_unavailable}
      end
    else
      {:error, :stdio_output_timeout}
    end
  catch
    :exit, _ -> {:error, :stdio_output_unavailable}
  end

  defp await_default(pid, deadline) do
    case reference(pid) do
      {:ok, _} = ok ->
        ok

      _ ->
        if Deadline.remaining(deadline) > 0 and alive?(pid),
          do:
            (
              Process.sleep(1)
              await_default(pid, deadline)
            ),
          else: {:error, :stdio_output_unavailable}
    end
  end
end
