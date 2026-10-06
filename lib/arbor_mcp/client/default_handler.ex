defmodule Arbor.MCP.Client.DefaultHandler do
  @moduledoc """
  This module provides ArborMCP extensions beyond the standard MCP specification.

  Default implementation of the Arbor.MCP.Client.Handler behaviour.

  This handler provides a basic implementation that can be extended or replaced
  by applications. It includes support for human-in-the-loop approval through
  the Arbor.MCP.Approval behaviour.

  ## Options

  - `:approval_handler` - Module implementing Arbor.MCP.Approval behaviour (required for createMessage)
  - `:roots` - List of root directories to expose (default: current directory)
  - `:model_selector` - Function to select which model to use for sampling

  ## Example

      # Start a client with the default handler
      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: {:stdio, "my-server"},
        handler: {Arbor.MCP.Client.DefaultHandler, [
          approval_handler: MyApprovalHandler,
          roots: [%{uri: "file:///home/user", name: "Home"}]
        ]}
      )
  """

  @behaviour Arbor.MCP.Client.Handler

  require Logger
  alias Arbor.RPC.LogSummary

  @impl true
  def init(opts) do
    state = %{
      approval_handler: Keyword.get(opts, :approval_handler),
      roots: Keyword.get(opts, :roots, default_roots()),
      model_selector: Keyword.get(opts, :model_selector, &default_model_selector/1),
      approval_opts: opts
    }

    {:ok, state}
  end

  @impl true
  def handle_ping(state) do
    {:ok, %{}, state}
  end

  @impl true
  def handle_list_roots(state) do
    {:ok, state.roots, state}
  end

  @impl true
  def handle_create_message(params, state) do
    case state.approval_handler do
      nil ->
        {:error,
         %{
           "code" => -32603,
           "message" => "No approval handler configured for createMessage requests"
         }, state}

      handler ->
        # Request approval for the sampling
        approval_opts = Map.get(state, :approval_opts, [])

        case handler.request_approval(:sampling, params, approval_opts) do
          {:approved, approved_params} ->
            # Simulate LLM sampling (in real implementation, this would call an actual LLM)
            model = state.model_selector.(approved_params)

            result = %{
              "role" => "assistant",
              "content" => %{
                "type" => "text",
                "text" =>
                  "This is a simulated response. In a real implementation, this would be the LLM's response."
              },
              "model" => model
            }

            # Request approval for the response
            response_opts = Keyword.put(approval_opts, :sampling_params, approved_params)

            case handler.request_approval(:response, result, response_opts) do
              {:approved, final_result} ->
                {:ok, final_result, state}

              {:denied, reason} ->
                {:error,
                 %{
                   "code" => -32603,
                   "message" => "Response approval denied: #{reason}"
                 }, state}

              {:modified, modified_result} ->
                {:ok, modified_result, state}
            end

          {:denied, reason} ->
            {:error,
             %{
               "code" => -32603,
               "message" => "Sampling approval denied: #{reason}"
             }, state}

          {:modified, modified_params} ->
            # Proceed with modified parameters
            handle_create_message(modified_params, state)
        end
    end
  rescue
    error ->
      Logger.error("Error in handle_create_message", reason: LogSummary.describe(error))

      {:error,
       %{
         "code" => -32603,
         "message" => "Internal error handling createMessage request"
       }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # Private functions

  defp default_roots do
    [
      %{
        uri: "file://#{File.cwd!()}",
        name: "Current Directory"
      }
    ]
  end

  defp default_model_selector(_params) do
    "default-model"
  end
end
