defmodule Arbor.MCP.Server.HTTP.Cowboy.SafeLogger do
  @moduledoc false
  require Logger

  # Ranch's default diagnostics print reference, socket options and protocol
  # arguments. Preserve severity without forwarding those trusted-host values.
  for level <- [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency] do
    def unquote(level)(_format, _arguments),
      do: Logger.log(unquote(level), "MCP owned Cowboy listener diagnostic")
  end
end
