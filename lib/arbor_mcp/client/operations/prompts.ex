defmodule Arbor.MCP.Client.Operations.Prompts do
  @moduledoc """
  Prompt operations for ArborMCP client.

  This module handles all prompt-related operations including listing available
  prompts and retrieving specific prompts with their arguments.
  """

  alias Arbor.MCP.Client.Internal.Request, as: ClientRequest

  alias Arbor.MCP.Client.Types
  alias Arbor.MCP.Internal.RequestParams

  @doc """
  Lists all available prompts from the MCP server.

  ## Options

  - `:cursor` - Pagination cursor for retrieving additional results
  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, prompts} = Arbor.MCP.Client.Operations.Prompts.list_prompts(client)
      {:ok, prompts} = Arbor.MCP.Client.Operations.Prompts.list_prompts(client, cursor: "page2")
  """
  @spec list_prompts(Types.client(), Types.request_opts()) :: Types.mcp_response()
  def list_prompts(client, opts \\ []) do
    ClientRequest.make_request(
      client,
      "prompts/list",
      RequestParams.cursor_from_opts(opts),
      opts,
      5_000
    )
  end

  @doc """
  Gets a specific prompt from the MCP server, optionally with arguments.

  ## Parameters

  - `client` - The client process.
  - `prompt_name` - The name of the prompt to retrieve.
  - `arguments` - A map of arguments to pass to the prompt.
  - `opts` - A keyword list of options.

  ## Options

  - `:timeout` - Request timeout (default: 5000)
  - `:format` - Response format (default: :struct)

  ## Examples

      {:ok, prompt} = Arbor.MCP.Client.Operations.Prompts.get_prompt(client, "my_prompt")
      {:ok, prompt} = Arbor.MCP.Client.Operations.Prompts.get_prompt(client, "my_prompt", %{"name" => "World"})
  """
  @spec get_prompt(Types.client(), String.t(), map(), Types.request_opts()) ::
          Types.mcp_response()
  def get_prompt(client, prompt_name, arguments \\ %{}, opts \\ []) do
    params =
      prompt_name
      |> RequestParams.named(arguments)
      |> RequestParams.with_opts_meta(opts)

    ClientRequest.make_request(client, "prompts/get", params, opts, 5_000)
  end
end
