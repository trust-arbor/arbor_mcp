defmodule Arbor.MCP.Client.Middleware do
  @moduledoc """
  Middleware pipeline for cross-cutting concerns in the ArborMCP client.

  This module will provide a composable middleware system for:
  - Telemetry and metrics
  - Rate limiting
  - Circuit breaking
  - Request/response logging
  - Error handling

  Currently a placeholder for future implementation.
  """

  @type middleware :: module()
  @type context :: map()

  @callback call(context, next :: fun()) :: {:ok, context} | {:error, term()}

  @doc """
  Executes a pipeline of middleware.
  """
  def execute(context, middleware_list) do
    Enum.reduce_while(middleware_list, {:ok, context}, fn middleware, {:ok, ctx} ->
      case middleware.call(ctx, fn c -> {:ok, c} end) do
        {:ok, new_ctx} -> {:cont, {:ok, new_ctx}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
