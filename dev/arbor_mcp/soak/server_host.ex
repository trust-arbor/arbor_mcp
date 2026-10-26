defmodule Arbor.MCP.Soak.ServerHost do
  @moduledoc false

  def run do
    redirect_logger()
    {:ok, _} = Application.ensure_all_started(:arbor_mcp)

    mode =
      case System.get_env("ARBOR_SOAK_ERA") do
        "modern" -> :modern_only
        _ -> :legacy_only
      end

    {:ok, _server} =
      Arbor.MCP.Server.start_link(
        handler: Arbor.MCP.Soak.Handler,
        transport: :stdio,
        protocol_mode: mode,
        mrtr: mode == :modern_only,
        request_state: [active_key_id: "soak", keys: %{"soak" => :binary.copy(<<83>>, 32)}]
      )

    Process.sleep(:infinity)
  end

  defp redirect_logger do
    {:ok, %{module: :logger_std_h} = handler} = :logger.get_handler_config(:default)

    config =
      handler
      |> Map.drop([:id, :module])
      |> Map.update!(:config, &Map.put(&1, :type, :standard_error))

    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, config)
  end
end
