defmodule Arbor.MCP.Approval do
  @moduledoc """
  Behaviour for implementing approval handlers in MCP clients.

  This behaviour defines the callback for handling approval requests
  when a server wants to perform actions that require user consent.
  """

  @type approval_type :: :sampling | :tool_call | :resource_access | atom()
  @type approval_data :: map()
  @type approval_opts :: keyword()
  @type approval_result :: {:approved, approval_data()} | {:denied, reason :: String.t()}

  @doc """
  Requests approval for an action.

  ## Parameters

  - `type` - The type of approval being requested (e.g., :sampling, :tool_call)
  - `data` - The data associated with the approval request
  - `opts` - Additional options for the approval handler

  ## Returns

  - `{:approved, data}` - The request was approved, possibly with modified data
  - `{:denied, reason}` - The request was denied with a reason

  ## Examples

      def request_approval(:sampling, %{"messages" => messages}, opts) do
        # Show UI to user for approval
        case get_user_consent(messages) do
          :yes -> {:approved, %{"messages" => messages}}
          :no -> {:denied, "User declined the request"}
        end
      end
  """
  @callback request_approval(approval_type(), approval_data(), approval_opts()) ::
              approval_result()
end
