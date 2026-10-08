defmodule Arbor.MCP.Tasks.Extension do
  @moduledoc """
  Capability and wire helpers for the MCP Tasks extension.

  The extension is defined for the modern protocol era under
  `io.modelcontextprotocol/tasks`. It is deliberately separate from the
  experimental `tasks` capability used by MCP 2025-11-25; declaring one never
  implies support for the other.
  """

  @identifier "io.modelcontextprotocol/tasks"
  @result_type "task"
  @request_methods ~w(tasks/get tasks/update tasks/cancel)
  @notification_method "notifications/tasks"
  @statuses ~w(working input_required completed failed cancelled)

  @type validation_error :: {:invalid_task_field, String.t()}

  @doc "Returns the canonical extension identifier."
  @spec identifier() :: String.t()
  def identifier, do: @identifier

  @doc "Returns the result discriminator reserved by the extension."
  @spec result_type() :: String.t()
  def result_type, do: @result_type

  @doc "Returns the client-to-server methods defined by the extension."
  @spec request_methods() :: [String.t()]
  def request_methods, do: @request_methods

  @doc "Returns the task-state notification method."
  @spec notification_method() :: String.t()
  def notification_method, do: @notification_method

  @doc "Returns the capability fragment required by modern task operations."
  @spec required_capabilities() :: map()
  def required_capabilities do
    %{"extensions" => %{@identifier => %{}}}
  end

  @doc "Adds the Tasks extension to a client or server capabilities object."
  @spec put_capability(map()) :: map()
  def put_capability(capabilities \\ %{}) when is_map(capabilities) do
    extensions = capability_value(capabilities, "extensions")
    extensions = if is_map(extensions), do: extensions, else: %{}

    capabilities
    |> Map.delete(:extensions)
    |> Map.put("extensions", Map.put(extensions, @identifier, %{}))
  end

  @doc false
  @spec put_handler_capability(map(), module() | term()) :: map()
  def put_handler_capability(capabilities, handler)
      when is_map(capabilities) and is_atom(handler) do
    if Code.ensure_loaded?(handler) and
         function_exported?(handler, :__task_store_enabled__, 0) and
         handler.__task_store_enabled__() do
      put_capability(capabilities)
    else
      capabilities
    end
  rescue
    _error -> capabilities
  end

  def put_handler_capability(capabilities, _handler) when is_map(capabilities), do: capabilities

  @doc "Returns whether a capabilities object declares the modern extension."
  @spec declared?(term()) :: boolean()
  def declared?(capabilities) when is_map(capabilities) do
    case capability_value(capabilities, "extensions") do
      extensions when is_map(extensions) ->
        case capability_value(extensions, @identifier) do
          settings when is_map(settings) -> true
          _other -> false
        end

      _other ->
        false
    end
  end

  def declared?(_capabilities), do: false

  @doc "Returns extension result types enabled by the declared capabilities."
  @spec allowed_result_types(term()) :: [String.t()]
  def allowed_result_types(capabilities) do
    if declared?(capabilities), do: [@result_type], else: []
  end

  @doc "Validates a task handle or detailed task-state result."
  @spec validate_task_result(map(), :create | :detailed) ::
          :ok | {:error, validation_error()}
  def validate_task_result(result, mode \\ :create)

  def validate_task_result(result, mode)
      when is_map(result) and mode in [:create, :detailed] do
    with :ok <- required_binary(result, "taskId"),
         :ok <- valid_status(result),
         :ok <- required_timestamp(result, "createdAt"),
         :ok <- required_timestamp(result, "lastUpdatedAt"),
         :ok <- required_non_negative_integer(result, "ttlMs"),
         :ok <- optional_non_negative_integer(result, "pollIntervalMs"),
         :ok <- optional_binary(result, "statusMessage") do
      validate_detailed_fields(result, mode)
    end
  end

  def validate_task_result(_result, _mode),
    do: {:error, {:invalid_task_field, "task"}}

  defp capability_value(capabilities, key) do
    case Map.fetch(capabilities, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(capabilities, fn {candidate, value} ->
          if key_string(candidate) == key, do: value
        end)
    end
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(_key), do: nil

  defp valid_status(result) do
    case field(result, "status") do
      status when status in @statuses -> :ok
      status when is_atom(status) -> valid_status(%{"status" => Atom.to_string(status)})
      _other -> invalid("status")
    end
  end

  defp required_binary(result, key) do
    case field(result, key) do
      value when is_binary(value) and value != "" -> :ok
      _other -> invalid(key)
    end
  end

  defp optional_binary(result, key) do
    case field(result, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _other -> invalid(key)
    end
  end

  defp required_timestamp(result, key) do
    case field(result, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _datetime, _offset} -> :ok
          _invalid -> invalid(key)
        end

      _other ->
        invalid(key)
    end
  end

  defp required_non_negative_integer(result, key) do
    case field(result, key) do
      value when is_integer(value) and value >= 0 -> :ok
      _other -> invalid(key)
    end
  end

  defp optional_non_negative_integer(result, key) do
    case field(result, key) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      _other -> invalid(key)
    end
  end

  defp validate_detailed_fields(_result, :create), do: :ok

  defp validate_detailed_fields(result, :detailed) do
    case field(result, "status") |> normalize_status() do
      "input_required" -> required_object(result, "inputRequests")
      "completed" -> required_object(result, "result")
      "failed" -> required_error(result)
      _other -> :ok
    end
  end

  defp required_object(result, key) do
    case field(result, key) do
      value when is_map(value) -> :ok
      _other -> invalid(key)
    end
  end

  defp required_error(result) do
    case field(result, "error") do
      error when is_map(error) ->
        if is_integer(field(error, "code")) and is_binary(field(error, "message")),
          do: :ok,
          else: invalid("error")

      _other ->
        invalid("error")
    end
  end

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn {candidate, value} ->
          if key_string(candidate) == key, do: {:found, value}
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status), do: status
  defp invalid(key), do: {:error, {:invalid_task_field, key}}
end
