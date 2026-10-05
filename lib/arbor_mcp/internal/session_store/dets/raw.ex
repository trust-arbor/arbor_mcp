defmodule Arbor.MCP.Internal.SessionStore.DETS.Raw do
  @moduledoc false

  # Opt-in durable backend. One SessionManager owns a storage_path. Restarting
  # that process with the same path reopens the files and retains sessions,
  # events, claimed request IDs, and the event clock. Two runtimes must not
  # share the same files; DETS rejects a second open.

  @behaviour Arbor.MCP.Internal.SessionStore

  defstruct [:sessions, :events, :request_ids, :meta, :path, :names, backend: :dets]

  @impl Arbor.MCP.Internal.SessionStore
  def open(config) do
    path = storage_path(config)

    if is_binary(path) and path != "" do
      open_path(Path.expand(path), Map.get(config, :dets_operation_live?, fn -> true end))
    else
      {:error, :storage_path_required}
    end
  end

  @impl Arbor.MCP.Internal.SessionStore
  def close(%__MODULE__{} = store), do: close_tables(store.names)

  defp close_tables(names) do
    Enum.reduce(names, :ok, fn name, result ->
      closed =
        case :dets.info(name, :owner) do
          :undefined -> {:error, :table_unavailable}
          _owner -> :dets.close(name)
        end

      case {result, closed} do
        {:ok, :ok} -> :ok
        {{:error, _reason}, _later} -> result
        {:ok, {:error, reason}} -> {:error, reason}
      end
    end)
  end

  @impl Arbor.MCP.Internal.SessionStore
  def lookup(store, table, key) do
    case :dets.lookup(table_ref(store, table), key) do
      objects when is_list(objects) -> objects
      {:error, reason} -> raise "DETS lookup failed: #{inspect(reason)}"
    end
  end

  @impl Arbor.MCP.Internal.SessionStore
  def insert(store, table, object) do
    :ok = :dets.insert(table_ref(store, table), object)
    sync_table(store, table)
    true
  end

  @impl Arbor.MCP.Internal.SessionStore
  def insert_new(store, table, object) do
    case :dets.insert_new(table_ref(store, table), object) do
      true ->
        sync_table(store, table)
        true

      false ->
        false

      {:error, reason} ->
        raise "DETS insert_new failed: #{inspect(reason)}"
    end
  end

  @impl Arbor.MCP.Internal.SessionStore
  def delete(store, table, key) do
    :ok = :dets.delete(table_ref(store, table), key)
    sync_table(store, table)
    true
  end

  @impl Arbor.MCP.Internal.SessionStore
  def member(store, table, key) do
    case :dets.member(table_ref(store, table), key) do
      result when is_boolean(result) -> result
      {:error, reason} -> raise "DETS member failed: #{inspect(reason)}"
    end
  end

  @impl Arbor.MCP.Internal.SessionStore
  def match(store, table, pattern) do
    case :dets.match(table_ref(store, table), pattern) do
      objects when is_list(objects) -> objects
      {:error, reason} -> raise "DETS match failed: #{inspect(reason)}"
    end
  end

  @impl Arbor.MCP.Internal.SessionStore
  def match_delete(store, table, pattern) do
    :ok = :dets.match_delete(table_ref(store, table), pattern)
    sync_table(store, table)
    true
  end

  @impl Arbor.MCP.Internal.SessionStore
  def all(store, table) do
    :dets.foldl(fn object, acc -> [object | acc] end, [], table_ref(store, table))
    |> Enum.reverse()
  end

  @impl Arbor.MCP.Internal.SessionStore
  def info(store, table, item) do
    :dets.info(table_ref(store, table), item)
  end

  @impl Arbor.MCP.Internal.SessionStore
  def event_clock(store) do
    case :dets.lookup(store.meta, :event_clock) do
      [{:event_clock, clock}] when is_integer(clock) and clock >= 0 ->
        clock

      _missing ->
        max_stored_sequence(store)
    end
  end

  @impl Arbor.MCP.Internal.SessionStore
  def put_event_clock(store, clock) when is_integer(clock) and clock >= 0 do
    :ok = :dets.insert(store.meta, {:event_clock, clock})
    :ok = :dets.sync(store.meta)
    store
  end

  defp open_path(path, live?) do
    File.mkdir_p!(path)

    if files_already_open?(path) do
      {:error, :storage_in_use}
    else
      open_tables(path, live?)
    end
  end

  defp open_tables(path, live?) do
    names = table_names()
    tables = [:sessions, :events, :request_ids, :meta]

    case open_each(path, names, tables, [], live?) do
      {:ok, opened} ->
        store = struct!(__MODULE__, Map.merge(names, %{path: path, names: opened}))

        try do
          {:ok, repair_process_local_flags(store, live?)}
        catch
          :throw, :storage_io_timeout -> open_failed(:storage_io_timeout, opened)
        end

      {:error, reason, opened} ->
        open_failed(reason, opened)
    end
  end

  defp open_failed(reason, opened) do
    case close_tables(opened) do
      :ok ->
        {:error, normalize_open_error(reason)}

      {:error, _cleanup_reason} ->
        {:error, {:storage_cleanup_unconfirmed, normalize_open_error(reason)}}
    end
  end

  defp open_each(_path, _names, [], opened, _live?), do: {:ok, Enum.reverse(opened)}

  defp open_each(path, names, [table | rest], opened, live?) do
    if live?.() do
      case open_table(Map.fetch!(names, table), Path.join(path, "#{table}.dets")) do
        {:ok, name} -> open_each(path, names, rest, [name | opened], live?)
        {:error, reason} -> {:error, reason, opened}
      end
    else
      {:error, :storage_io_timeout, opened}
    end
  end

  defp normalize_open_error({:already_open, _file}), do: :storage_in_use
  defp normalize_open_error(reason), do: reason

  defp open_table(name, file) do
    :dets.open_file(name,
      file: String.to_charlist(file),
      type: :set,
      access: :read_write,
      auto_save: :infinity,
      repair: true
    )
  end

  defp storage_path(config) do
    Map.get(config, :storage_path) || Map.get(config, :dets_path)
  end

  # DETS accepts any term as a table name. Fresh references isolate each open
  # without creating permanent atoms. File exclusivity is still enforced by
  # files_already_open?/1 and by DETS rejecting a second open of the same file.
  defp table_names do
    %{
      sessions: make_ref(),
      events: make_ref(),
      request_ids: make_ref(),
      meta: make_ref()
    }
  end

  defp files_already_open?(path) do
    expected =
      ["sessions.dets", "events.dets", "request_ids.dets", "meta.dets"]
      |> Enum.map(&String.to_charlist(Path.join(path, &1)))
      |> MapSet.new()

    Enum.any?(:dets.all(), fn name ->
      case :dets.info(name, :filename) do
        file when is_list(file) -> MapSet.member?(expected, file)
        _other -> false
      end
    end)
  end

  defp table_ref(%__MODULE__{sessions: table}, :sessions), do: table
  defp table_ref(%__MODULE__{events: table}, :events), do: table
  defp table_ref(%__MODULE__{request_ids: table}, :request_ids), do: table

  defp sync_table(store, table) do
    :ok = :dets.sync(table_ref(store, table))
  end

  # initialization_claimed is process-local (owner monitors live on
  # SessionManager). A durable row that still says claimed after a restart
  # has no owner; clear the flag so a later initialize can proceed.
  defp repair_process_local_flags(store, live?) do
    store
    |> all(:sessions)
    |> Enum.each(fn
      {session_id, %{initialization_claimed: true, initialized: false} = session} ->
        if not live?.(), do: throw(:storage_io_timeout)
        insert(store, :sessions, {session_id, %{session | initialization_claimed: false}})

      _other ->
        :ok
    end)

    store
  end

  defp max_stored_sequence(store) do
    store
    |> all(:events)
    |> Enum.reduce(0, fn
      {_key, event}, acc when is_map(event) ->
        max(acc, Map.get(event, :__ex_mcp_sequence__, 0))

      _other, acc ->
        acc
    end)
  end
end
