defmodule Arbor.MCP.SessionStoreContract do
  @moduledoc false

  # Test-only facade over the SessionManager call surface.
  # This is the accepted 1.x event-store contract from https://github.com/trust-arbor/arbor_mcp/blob/v1.6.0/docs/STORE_ADAPTER.md.

  @doc false
  def start_dets_isolated!(opts \\ []) do
    {path, opts} = Keyword.pop(opts, :storage_path)

    path =
      if is_binary(path) and path != "" do
        path
      else
        dir =
          Path.join(
            System.tmp_dir!(),
            "ex_mcp_session_dets_#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(dir)
        ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
        dir
      end

    opts
    |> Keyword.put(:storage_backend, :dets)
    |> Keyword.put(:storage_path, path)
    |> start_isolated!()
    |> Map.put(:storage_path, path)
  end

  @doc false
  def start_isolated!(opts \\ []) do
    {child_id, opts} = Keyword.pop(opts, :id)

    name =
      Keyword.get_lazy(opts, :name, fn ->
        :"session_store_contract_#{System.unique_integer([:positive])}"
      end)

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:cleanup_interval_ms, 60_000)

    child_id = child_id || {Arbor.MCP.SessionManager, name}

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Arbor.MCP.SessionManager, opts},
        id: child_id
      )

    %{name: name, pid: pid, id: child_id}
  end

  @doc false
  def create_session(store, metadata \\ %{}) do
    GenServer.call(store, {:create_session, metadata})
  end

  @doc false
  def get_session(store, session_id) do
    GenServer.call(store, {:get_session, session_id})
  end

  @doc false
  def terminate_session(store, session_id) do
    GenServer.call(store, {:terminate_session, session_id})
  end

  @doc false
  def append_event(store, session_id, type, data) do
    GenServer.call(store, {:append_event, session_id, type, data})
  end

  @doc false
  def store_event(store, session_id, event_data) do
    GenServer.call(store, {:store_event, session_id, event_data})
  end

  @doc false
  def replay_events_after(store, session_id, cursor \\ nil) do
    GenServer.call(store, {:replay_events_after, session_id, cursor})
  end

  @doc false
  def claim_request_id(store, session_id, request_id) do
    GenServer.call(store, {:claim_request_id, session_id, request_id})
  end

  @doc false
  def get_stats(store) do
    GenServer.call(store, :get_stats)
  end
end
