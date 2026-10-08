defmodule Arbor.MCP.Client.Operations.Tasks do
  @moduledoc """
  Client operations for legacy tasks and the modern Tasks extension.

  `tasks/get` and `tasks/cancel` are available in both task eras. The modern
  `tasks/update` method is used to satisfy outstanding `inputRequests`. Modern
  requests are accepted only when the client configured the
  `io.modelcontextprotocol/tasks` extension capability.
  """

  alias Arbor.MCP.Client.Internal.Request, as: ClientRequest

  alias Arbor.MCP.Client.Types

  @doc "Reads the full current state of one task."
  @spec get(Types.client(), String.t(), Types.request_opts()) :: Types.mcp_response()
  def get(client, task_id, opts \\ []) do
    ClientRequest.make_request(
      client,
      "tasks/get",
      %{"taskId" => task_id},
      map_opts(opts),
      5_000
    )
  end

  @doc "Submits responses to a modern task's outstanding input requests."
  @spec update(Types.client(), String.t(), map(), Types.request_opts()) ::
          Types.mcp_response()
  def update(client, task_id, input_responses, opts \\ []) do
    params = %{"taskId" => task_id, "inputResponses" => input_responses}

    ClientRequest.make_request(
      client,
      "tasks/update",
      params,
      map_opts(opts),
      5_000
    )
  end

  @doc "Requests cooperative cancellation of one task."
  @spec cancel(Types.client(), String.t(), Types.request_opts()) :: Types.mcp_response()
  def cancel(client, task_id, opts \\ []) do
    ClientRequest.make_request(
      client,
      "tasks/cancel",
      %{"taskId" => task_id},
      map_opts(opts),
      5_000
    )
  end

  defp map_opts(opts), do: Keyword.put_new(opts, :format, :map)
end
