defmodule Arbor.MCP.Tasks.Task do
  @moduledoc """
  Task struct and state machine validation for MCP Tasks.

  Tasks represent async operations initiated by tool calls. This module
  provides a pure data structure and state transition validation functions.
  `Arbor.MCP.Tasks` and `Arbor.MCP.Tasks.Store` provide the optional durable lifecycle
  boundary; the task struct itself does not own a process.

  ## State Machine

  Valid states: `:working`, `:input_required`, `:completed`, `:failed`, `:cancelled`

  Valid transitions:
  - `:working` -> `:input_required` | `:completed` | `:failed` | `:cancelled`
  - `:input_required` -> `:working` | `:cancelled`
  - `:completed` -> (terminal state)
  - `:failed` -> (terminal state)
  - `:cancelled` -> (terminal state)

  ## Usage

      task = Arbor.MCP.Tasks.Task.new("my-tool", %{"arg" => "value"})
      {:ok, task} = Arbor.MCP.Tasks.Task.transition(task, :completed)
  """

  alias Arbor.MCP.Internal.MapBuilder

  @type t :: %__MODULE__{
          id: String.t(),
          state: state(),
          status_message: String.t() | nil,
          tool_name: String.t(),
          arguments: map(),
          created_at: String.t(),
          last_updated_at: String.t() | nil,
          ttl: integer() | nil,
          poll_interval: integer() | nil,
          result: map() | nil,
          input_requests: map() | nil,
          error: map() | nil,
          metadata: map()
        }

  @type state :: :working | :input_required | :completed | :failed | :cancelled

  @enforce_keys [:id, :state, :tool_name]
  defstruct [
    :id,
    :tool_name,
    :ttl,
    :poll_interval,
    :result,
    :input_requests,
    :error,
    :status_message,
    :last_updated_at,
    state: :working,
    arguments: %{},
    created_at: nil,
    metadata: %{}
  ]

  @terminal_states [:completed, :failed, :cancelled]

  @valid_transitions %{
    working: [:input_required, :completed, :failed, :cancelled],
    input_required: [:working, :cancelled]
  }

  @doc """
  Creates a new task in the `:working` state.

  ## Parameters
  - `tool_name` - Name of the tool this task is executing
  - `arguments` - Tool arguments
  - `opts` - Optional fields: `:id`, `:ttl`, `:metadata`
  """
  @spec new(String.t(), map(), keyword()) :: t()
  def new(tool_name, arguments \\ %{}, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      state: :working,
      tool_name: tool_name,
      arguments: arguments,
      created_at: now,
      last_updated_at: now,
      ttl: Keyword.get(opts, :ttl),
      poll_interval: Keyword.get(opts, :poll_interval),
      status_message: Keyword.get(opts, :status_message),
      input_requests: Keyword.get(opts, :input_requests),
      error: Keyword.get(opts, :error),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Attempts a state transition.

  Returns `{:ok, updated_task}` if the transition is valid,
  `{:error, reason}` if invalid.
  """
  @spec transition(t(), state()) :: {:ok, t()} | {:error, String.t()}
  def transition(%__MODULE__{state: current} = task, new_state) do
    if valid_transition?(current, new_state) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      input_requests =
        if new_state == :input_required, do: task.input_requests, else: nil

      {:ok,
       %{
         task
         | state: new_state,
           last_updated_at: now,
           input_requests: input_requests
       }}
    else
      {:error, "Invalid transition from #{current} to #{new_state}"}
    end
  end

  @doc """
  Transitions and sets the result (for completed tasks).
  """
  @spec complete(t(), map()) :: {:ok, t()} | {:error, String.t()}
  def complete(%__MODULE__{} = task, result) do
    case transition(task, :completed) do
      {:ok, task} -> {:ok, %{task | result: result}}
      error -> error
    end
  end

  @doc """
  Transitions to failed state with error info.
  """
  @spec fail(t(), map()) :: {:ok, t()} | {:error, String.t()}
  def fail(%__MODULE__{} = task, error_result) do
    case transition(task, :failed) do
      # Keep `result` populated for callers using the experimental 2025-11-25
      # representation while exposing the dedicated modern `error` field.
      {:ok, task} -> {:ok, %{task | error: error_result, result: error_result}}
      error -> error
    end
  end

  @doc "Transitions a task to `input_required` with outstanding input requests."
  @spec require_input(t(), map()) :: {:ok, t()} | {:error, String.t()}
  def require_input(%__MODULE__{} = task, input_requests) when is_map(input_requests) do
    case transition(task, :input_required) do
      {:ok, task} -> {:ok, %{task | input_requests: input_requests}}
      error -> error
    end
  end

  @doc """
  Checks if a transition from one state to another is valid.
  """
  @spec valid_transition?(state(), state()) :: boolean()
  def valid_transition?(from, to) do
    case Map.get(@valid_transitions, from) do
      nil -> false
      valid_targets -> to in valid_targets
    end
  end

  @doc """
  Checks if the task is in a terminal state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  @doc """
  Returns all valid states.
  """
  @spec states() :: [state()]
  def states, do: [:working, :input_required | @terminal_states]

  @doc """
  Returns all terminal states.
  """
  @spec terminal_states() :: [state()]
  def terminal_states, do: @terminal_states

  @doc """
  Converts a task to a map suitable for protocol serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = task) do
    base = %{
      "taskId" => task.id,
      "status" => Atom.to_string(task.state),
      "toolName" => task.tool_name
    }

    base
    |> MapBuilder.put_unless("arguments", task.arguments, %{})
    |> MapBuilder.put_if_present("createdAt", task.created_at)
    |> MapBuilder.put_if_present("lastUpdatedAt", task.last_updated_at)
    |> MapBuilder.put_if_present("ttl", task.ttl)
    |> MapBuilder.put_if_present("pollInterval", task.poll_interval)
    |> MapBuilder.put_if_present("statusMessage", task.status_message)
    |> MapBuilder.put_if_present("result", task.result)
    |> MapBuilder.put_unless("metadata", task.metadata, %{})
  end

  @doc "Converts a task to the wire representation for a protocol era or version."
  @spec to_map(t(), :legacy | :modern | String.t()) :: map()
  def to_map(%__MODULE__{} = task, era_or_version)
      when era_or_version in [:modern, "2026-07-28"] do
    %{
      "taskId" => task.id,
      "status" => Atom.to_string(task.state)
    }
    |> MapBuilder.put_if_present("createdAt", task.created_at)
    |> MapBuilder.put_if_present("lastUpdatedAt", task.last_updated_at)
    |> MapBuilder.put_if_present("ttlMs", task.ttl)
    |> MapBuilder.put_if_present("pollIntervalMs", task.poll_interval)
    |> MapBuilder.put_if_present("statusMessage", task.status_message)
    |> MapBuilder.put_if_present("inputRequests", modern_input_requests(task))
    |> MapBuilder.put_if_present("result", modern_result(task))
    |> MapBuilder.put_if_present("error", task.error)
  end

  def to_map(%__MODULE__{} = task, _legacy_or_version), do: to_map(task)

  @doc """
  Parses a state string to a state atom.
  """
  @spec parse_state(String.t()) :: {:ok, state()} | {:error, String.t()}
  def parse_state("working"), do: {:ok, :working}
  def parse_state("input_required"), do: {:ok, :input_required}
  def parse_state("completed"), do: {:ok, :completed}
  def parse_state("failed"), do: {:ok, :failed}
  def parse_state("cancelled"), do: {:ok, :cancelled}
  def parse_state(other), do: {:error, "Unknown task state: #{other}"}

  # Private helpers

  defp generate_id do
    "task_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp modern_result(%__MODULE__{state: :completed, result: result}), do: result
  defp modern_result(%__MODULE__{}), do: nil

  defp modern_input_requests(%__MODULE__{state: :input_required, input_requests: requests}),
    do: requests

  defp modern_input_requests(%__MODULE__{}), do: nil
end
