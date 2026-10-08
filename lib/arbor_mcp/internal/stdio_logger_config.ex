defmodule Arbor.MCP.Internal.StdioLoggerConfig do
  @moduledoc """
  Explicit legacy host opt-in for suppressing VM-wide stdio diagnostics.

  `configure/0` retains its existing behavior: it sets `:arbor_mcp`
  `:stdio_mode`, Elixir Logger's level, the `:logger` application level, and the
  OTP primary logger level to `:emergency`. It does not route logs to stderr.
  Unrelated applications in the same BEAM VM also lose normal logging.

  ArborMCP 2.0 never calls this utility during application startup or
  transport connection. The exported function remains for callers that
  explicitly choose the legacy suppression policy. Prefer host-owned stderr
  handlers configured before application startup, preserving normal log levels.
  """

  @doc """
  Applies the legacy VM-global `:emergency` logging threshold explicitly.

  This mutates Logger/Application/OTP logger settings without routing handlers.
  Emergency reports and direct IO can still reach stdout. The host remains
  responsible for a JSON-RPC-only protocol stream.
  """
  def configure do
    # Set stdio mode flag
    Application.put_env(:arbor_mcp, :stdio_mode, true)

    # Configure Logger
    Logger.configure(level: :emergency)

    # Configure application-level logging
    Application.put_env(:logger, :level, :emergency)

    # Configure OTP logger
    :logger.set_primary_config(:level, :emergency)

    :ok
  end
end
