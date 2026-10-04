defmodule Arbor.MCP.Tasks.Store.ETS do
  @moduledoc """
  Bounded node-local Tasks store with atomic lifecycle operations.

  Entries survive client disconnects, client restarts, connection process
  failures, and worker failures while the Arbor.MCP application remains running.
  They do not survive an application or node restart. Configure another
  `Arbor.MCP.Tasks.Store` implementation when that stronger durability is needed.
  """

  use GenServer

  @behaviour Arbor.MCP.Tasks.Store

  alias Arbor.MCP.Server.Runtime.ServiceAdapter
  alias Arbor.MCP.Tasks.{Extension, Task}

  @name __MODULE__
  @default_max_tasks 10_000
  @default_max_ttl_ms 2_592_000_000

  defmodule Entry do
    @moduledoc false

    @enforce_keys [:task, :owner, :expires_at_ms]
    defstruct [
      :task,
      :owner,
      :expires_at_ms,
      :cancel_requested_at_ms,
      input_responses: %{},
      version: 0
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    server_opts = [timeout: Keyword.get(opts, :init_timeout_ms, :infinity)]

    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts, server_opts)
      name -> GenServer.start_link(__MODULE__, opts, Keyword.put(server_opts, :name, name))
    end
  end

  @doc false
  def runtime_service_capabilities, do: %{bounded_startup: 1}

  @impl Arbor.MCP.Tasks.Store
  def create(%Task{} = task, owner, opts) do
    call(opts, {:create, task, owner})
  end

  @impl Arbor.MCP.Tasks.Store
  def fetch(task_id, owner, opts), do: call(opts, {:fetch, task_id, owner})

  @impl Arbor.MCP.Tasks.Store
  def submit_input(task_id, input_responses, owner, opts) do
    call(opts, {:submit_input, task_id, input_responses, owner})
  end

  @impl Arbor.MCP.Tasks.Store
  def request_cancel(task_id, owner, opts), do: call(opts, {:request_cancel, task_id, owner})

  @impl Arbor.MCP.Tasks.Store
  def transition(task_id, operation, owner, opts) do
    call(opts, {:transition, task_id, operation, owner})
  end

  @impl Arbor.MCP.Tasks.Store
  def take_input_responses(task_id, owner, opts) do
    call(opts, {:take_input_responses, task_id, owner})
  end

  @impl Arbor.MCP.Tasks.Store
  def cancellation_requested?(task_id, owner, opts) do
    call(opts, {:cancellation_requested, task_id, owner})
  end

  @impl GenServer
  def init(opts) do
    with :ok <- ServiceAdapter.watch_owned(opts),
         {:ok, max_tasks} <- positive_limit(Keyword.get(opts, :max_tasks, @default_max_tasks)),
         {:ok, max_ttl_ms} <-
           positive_limit(Keyword.get(opts, :max_ttl_ms, @default_max_ttl_ms)),
         {:ok, now_fun} <- now_fun(Keyword.get(opts, :now_fun)) do
      {:ok,
       %{
         entries: %{},
         max_tasks: max_tasks,
         max_ttl_ms: max_ttl_ms,
         now_fun: now_fun
       }}
    end
  end

  @impl GenServer
  def handle_call(request, _from, state) do
    now = state.now_fun.()
    state = cleanup_expired(state, now)
    handle_request(request, state, now)
  end

  defp handle_request({:create, task, owner}, state, now) do
    with :ok <- valid_owner(owner),
         :ok <- valid_new_task(task, state.max_ttl_ms),
         false <- Map.has_key?(state.entries, task.id),
         true <- map_size(state.entries) < state.max_tasks do
      entry = %Entry{
        task: task,
        owner: owner,
        expires_at_ms: now + task.ttl
      }

      {:reply, {:ok, task}, put_entry(state, entry)}
    else
      true -> {:reply, {:error, :already_exists}, state}
      false -> {:reply, {:error, :store_full}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_request({:fetch, task_id, owner}, state, _now) do
    case authorized_entry(state, task_id, owner) do
      {:ok, entry} -> {:reply, {:ok, entry.task}, state}
      error -> {:reply, error, state}
    end
  end

  defp handle_request({:submit_input, task_id, responses, owner}, state, now) do
    with true <- is_map(responses),
         {:ok, entry} <- authorized_entry(state, task_id, owner),
         {:ok, entry} <- accept_input_responses(entry, responses, now) do
      {:reply, :ok, put_entry(state, entry)}
    else
      false -> {:reply, {:error, :invalid_input_responses}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_request({:request_cancel, task_id, owner}, state, now) do
    case authorized_entry(state, task_id, owner) do
      {:ok, %Entry{task: task} = entry} ->
        entry =
          if Task.terminal?(task) or entry.cancel_requested_at_ms do
            entry
          else
            %{entry | cancel_requested_at_ms: now, version: entry.version + 1}
          end

        {:reply, :ok, put_entry(state, entry)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_request({:transition, task_id, operation, owner}, state, now) do
    with {:ok, entry} <- authorized_entry(state, task_id, owner),
         {:ok, task} <- apply_transition(entry.task, operation, now),
         :ok <- valid_detailed_task(task) do
      entry = %{entry | task: task, version: entry.version + 1}
      {:reply, {:ok, task}, put_entry(state, entry)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_request({:take_input_responses, task_id, owner}, state, _now) do
    case authorized_entry(state, task_id, owner) do
      {:ok, entry} ->
        responses = entry.input_responses
        entry = %{entry | input_responses: %{}, version: entry.version + 1}
        {:reply, {:ok, responses}, put_entry(state, entry)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_request({:cancellation_requested, task_id, owner}, state, _now) do
    case authorized_entry(state, task_id, owner) do
      {:ok, entry} -> {:reply, {:ok, not is_nil(entry.cancel_requested_at_ms)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp accept_input_responses(%Entry{task: %{state: :input_required}} = entry, responses, now) do
    outstanding = entry.task.input_requests || %{}
    accepted = Map.take(responses, Map.keys(outstanding))

    if map_size(accepted) == 0 do
      {:ok, entry}
    else
      remaining = Map.drop(outstanding, Map.keys(accepted))

      task =
        if map_size(remaining) == 0 do
          {:ok, task} = Task.transition(entry.task, :working)
          task
        else
          %{entry.task | input_requests: remaining, last_updated_at: iso8601(now)}
        end

      {:ok,
       %{
         entry
         | task: task,
           input_responses: Map.merge(entry.input_responses, accepted),
           version: entry.version + 1
       }}
    end
  end

  defp accept_input_responses(entry, _responses, _now), do: {:ok, entry}

  defp apply_transition(task, {:complete, result}, _now) when is_map(result),
    do: normalize_transition(Task.complete(task, result))

  defp apply_transition(task, {:fail, error}, _now) when is_map(error),
    do: normalize_transition(Task.fail(task, error))

  defp apply_transition(task, {:require_input, requests}, _now) when is_map(requests),
    do: normalize_transition(Task.require_input(task, requests))

  defp apply_transition(task, :cancelled, _now),
    do: normalize_transition(Task.transition(task, :cancelled))

  defp apply_transition(task, {:status_message, message}, now)
       when is_nil(message) or is_binary(message) do
    if Task.terminal?(task) do
      {:error, :invalid_transition}
    else
      {:ok, %{task | status_message: message, last_updated_at: iso8601(now)}}
    end
  end

  defp apply_transition(_task, _operation, _now), do: {:error, :invalid_transition}

  defp normalize_transition({:ok, task}), do: {:ok, task}
  defp normalize_transition({:error, _reason}), do: {:error, :invalid_transition}

  defp valid_new_task(%Task{ttl: ttl} = task, max_ttl_ms)
       when is_integer(ttl) and ttl >= 0 and ttl <= max_ttl_ms do
    valid_detailed_task(task)
  end

  defp valid_new_task(%Task{ttl: ttl}, _max_ttl_ms) when is_integer(ttl),
    do: {:error, :ttl_out_of_range}

  defp valid_new_task(%Task{}, _max_ttl_ms), do: {:error, :invalid_task}

  defp valid_detailed_task(task) do
    case Extension.validate_task_result(Task.to_map(task, :modern), :detailed) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_task}
    end
  end

  defp valid_owner(%{principal_id: principal, tenant_id: tenant, audience: audience}) do
    if Enum.all?([principal, tenant, audience], &(is_nil(&1) or valid_owner_value?(&1))),
      do: :ok,
      else: {:error, :invalid_task}
  end

  defp valid_owner(_owner), do: {:error, :invalid_task}
  defp valid_owner_value?(value), do: is_binary(value) and byte_size(value) > 0

  defp authorized_entry(state, task_id, owner) do
    case Map.get(state.entries, task_id) do
      %Entry{owner: ^owner} = entry -> {:ok, entry}
      _missing_or_other_owner -> {:error, :not_found_or_unauthorized}
    end
  end

  defp put_entry(state, %Entry{task: task} = entry) do
    %{state | entries: Map.put(state.entries, task.id, entry)}
  end

  defp cleanup_expired(state, now) do
    entries = Map.reject(state.entries, fn {_id, entry} -> entry.expires_at_ms <= now end)
    %{state | entries: entries}
  end

  defp positive_limit(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_limit(_value), do: {:error, :invalid_store_limit}

  defp now_fun(nil), do: {:ok, fn -> System.system_time(:millisecond) end}
  defp now_fun(fun) when is_function(fun, 0), do: {:ok, fun}
  defp now_fun(_value), do: {:error, :invalid_now_fun}

  defp iso8601(milliseconds) do
    milliseconds
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp call(opts, request) do
    server = Keyword.get(opts, :server, @name)
    GenServer.call(server, request)
  catch
    :exit, _reason -> {:error, :task_store_unavailable}
  end
end
