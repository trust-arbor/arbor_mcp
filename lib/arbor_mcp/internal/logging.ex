defmodule Arbor.MCP.Internal.Logging do
  @moduledoc false

  # Enhanced logging utilities for Arbor.MCP that integrate with Elixir's Logger system.
  #
  # This module provides:
  # 1. Automatic conversion between MCP log levels and Elixir Logger levels
  # 2. Global log level configuration for MCP servers
  # 3. Structured logging with MCP-compliant format
  # 4. Integration with Logger configuration
  #
  # ## Log Level Mapping
  #
  # MCP log levels are mapped to Elixir Logger levels as follows:
  #
  # | MCP Level | Elixir Level | Description |
  # |-----------|-------------|-------------|
  # | debug     | :debug      | Detailed debugging information |
  # | info      | :info       | General informational messages |
  # | notice    | :info       | Normal but significant events |
  # | warning   | :warning    | Warning conditions |
  # | error     | :error      | Error conditions |
  # | critical  | :error      | Critical conditions |
  # | alert     | :error      | Action must be taken immediately |
  # | emergency | :error      | System is unusable |
  #
  # ## Usage
  #
  #     # Configure global log level for MCP
  #     Arbor.MCP.Logging.set_global_level("debug")
  #
  #     # Log with MCP format (will also log to Elixir Logger)
  #     Arbor.MCP.Logging.log(server, "info", "Operation completed", %{duration: 123})
  #
  #     # Check if a level is enabled
  #     if Arbor.MCP.Logging.level_enabled?("debug") do
  #       # Expensive debug computation
  #       Arbor.MCP.Logging.debug(server, "Debug info", expensive_data())
  #     end
  #
  # ## Security
  #
  # This module automatically sanitizes log data to remove sensitive information
  # such as passwords, tokens, and keys from log messages.

  require Logger

  @type mcp_log_level :: String.t()
  @type logger_level :: :debug | :info | :warning | :error

  # RFC 5424 log levels supported by MCP
  @mcp_levels ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]

  # Mapping from MCP levels to Elixir Logger levels
  @level_mapping %{
    "debug" => :debug,
    "info" => :info,
    # Map notice to info
    "notice" => :info,
    "warning" => :warning,
    "error" => :error,
    # Map critical to error
    "critical" => :error,
    # Map alert to error
    "alert" => :error,
    # Map emergency to error
    "emergency" => :error
  }

  # Global state for log level configuration
  @global_log_level_key {__MODULE__, :global_log_level}

  @doc """
  Sets the global minimum log level for all MCP servers.

  Valid levels: #{inspect(@mcp_levels)}

  ## Examples

      Arbor.MCP.Logging.set_global_level("debug")
      Arbor.MCP.Logging.set_global_level("error")
  """
  @spec set_global_level(mcp_log_level()) :: :ok | {:error, String.t()}
  def set_global_level(level) when level in @mcp_levels do
    :persistent_term.put(@global_log_level_key, level)

    # Also configure Elixir Logger if possible
    case Map.get(@level_mapping, level) do
      nil ->
        :ok

      logger_level ->
        try do
          Logger.configure(level: logger_level)
          :ok
        rescue
          # Ignore if Logger configuration fails
          _ -> :ok
        end
    end
  end

  def set_global_level(level) do
    {:error, "Invalid log level: #{level}. Valid levels: #{inspect(@mcp_levels)}"}
  end

  @doc """
  Gets the current global minimum log level.

  Returns "info" if no level has been set.

  ## Examples

      Arbor.MCP.Logging.get_global_level()
      #=> "info"
  """
  @spec get_global_level() :: mcp_log_level()
  def get_global_level do
    :persistent_term.get(@global_log_level_key, "info")
  end

  @doc """
  Checks if a given log level is enabled based on the global configuration.

  ## Examples

      Arbor.MCP.Logging.level_enabled?("debug")
      #=> true or false
  """
  @spec level_enabled?(mcp_log_level()) :: boolean()
  def level_enabled?(level) when level in @mcp_levels do
    current_level = get_global_level()
    level_value(level) >= level_value(current_level)
  end

  def level_enabled?(_level), do: false

  @doc """
  Logs a message at the specified level to both MCP clients and Elixir Logger.

  The message will only be sent if the level meets the global minimum log level.

  ## Examples

      Arbor.MCP.Logging.log(server, "info", "Operation completed")
      Arbor.MCP.Logging.log(server, "error", "Failed to connect", %{host: "localhost"})
  """
  @spec log(GenServer.server() | nil, mcp_log_level(), String.t(), map() | nil) :: :ok
  def log(server, level, message, data \\ nil)

  def log(server, level, message, data) when level in @mcp_levels do
    if level_enabled?(level) do
      # Sanitize data for security
      sanitized_data = sanitize_log_data(data)
      sanitized_message = sanitize_log_message(message)

      # Log to Elixir Logger
      log_to_elixir_logger(level, sanitized_message, sanitized_data)

      # Send to MCP clients if server is provided
      if server do
        try do
          Arbor.MCP.Server.send_log_message(server, level, sanitized_message, sanitized_data)
        rescue
          # Ignore if server is not available
          _ -> :ok
        end
      end
    end

    :ok
  end

  def log(_server, level, _message, _data) do
    Logger.warning("Invalid MCP log level: #{level}")
    :ok
  end

  @doc """
  Convenience function for debug-level logging.
  """
  @spec debug(GenServer.server() | nil, String.t(), map() | nil) :: :ok
  def debug(server, message, data \\ nil) do
    log(server, "debug", message, data)
  end

  @doc """
  Convenience function for info-level logging.
  """
  @spec info(GenServer.server() | nil, String.t(), map() | nil) :: :ok
  def info(server, message, data \\ nil) do
    log(server, "info", message, data)
  end

  @doc """
  Convenience function for warning-level logging.
  """
  @spec warning(GenServer.server() | nil, String.t(), map() | nil) :: :ok
  def warning(server, message, data \\ nil) do
    log(server, "warning", message, data)
  end

  @doc """
  Convenience function for error-level logging.
  """
  @spec error(GenServer.server() | nil, String.t(), map() | nil) :: :ok
  def error(server, message, data \\ nil) do
    log(server, "error", message, data)
  end

  @doc """
  Convenience function for critical-level logging.
  """
  @spec critical(GenServer.server() | nil, String.t(), map() | nil) :: :ok
  def critical(server, message, data \\ nil) do
    log(server, "critical", message, data)
  end

  @doc """
  Validates if a log level string is valid according to MCP specification.

  ## Examples

      Arbor.MCP.Logging.valid_level?("info")
      #=> true

      Arbor.MCP.Logging.valid_level?("verbose")
      #=> false
  """
  @spec valid_level?(String.t()) :: boolean()
  def valid_level?(level) when is_binary(level) do
    level in @mcp_levels
  end

  def valid_level?(_), do: false

  @doc """
  Returns a list of all valid MCP log levels.

  ## Examples

      Arbor.MCP.Logging.valid_levels()
      #=> ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
  """
  @spec valid_levels() :: [mcp_log_level()]
  def valid_levels, do: @mcp_levels

  # Private helper functions

  # Converts log level to numeric value for comparison
  defp level_value("debug"), do: 0
  defp level_value("info"), do: 1
  defp level_value("notice"), do: 2
  defp level_value("warning"), do: 3
  defp level_value("error"), do: 4
  defp level_value("critical"), do: 5
  defp level_value("alert"), do: 6
  defp level_value("emergency"), do: 7
  # Default to info level
  defp level_value(_), do: 1

  # Logs to Elixir Logger with appropriate level
  defp log_to_elixir_logger(mcp_level, message, data) do
    logger_level = Map.get(@level_mapping, mcp_level, :info)

    case logger_level do
      :debug -> Logger.debug(format_logger_message(message, data))
      :info -> Logger.info(format_logger_message(message, data))
      :warning -> Logger.warning(format_logger_message(message, data))
      :error -> Logger.error(format_logger_message(message, data))
    end
  end

  # Formats message for Elixir Logger
  defp format_logger_message(message, nil), do: "[MCP] #{message}"
  defp format_logger_message(message, data), do: "[MCP] #{message} - #{inspect(data)}"

  # Security: sanitize log data to remove sensitive information
  defp sanitize_log_data(nil), do: nil

  defp sanitize_log_data(data) when is_map(data) do
    data
    |> Enum.reject(fn {key, _value} ->
      key_str = to_string(key) |> String.downcase()

      String.contains?(key_str, "password") or
        String.contains?(key_str, "secret") or
        String.contains?(key_str, "token") or
        String.contains?(key_str, "key") or
        String.contains?(key_str, "auth") or
        String.contains?(key_str, "credential")
    end)
    |> Enum.into(%{})
  end

  defp sanitize_log_data(data), do: data

  # Security: sanitize log messages
  defp sanitize_log_message(message) when is_binary(message) do
    message
    |> String.replace(~r/password[:\s=]+\S+/i, "password=***")
    |> String.replace(~r/token[:\s=]+\S+/i, "token=***")
    |> String.replace(~r/secret[:\s=]+\S+/i, "secret=***")
    |> String.replace(~r/key[:\s=]+\S+/i, "key=***")
    |> String.replace(~r/auth[:\s=]+\S+/i, "auth=***")
  end

  defp sanitize_log_message(message), do: message
end
