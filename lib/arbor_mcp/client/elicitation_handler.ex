defmodule Arbor.MCP.Client.ElicitationHandler do
  @moduledoc """
  Default elicitation handler for MCP clients.

  When a server sends an `elicitation/create` request, it's asking the client
  to collect user input (text, numbers, selections, etc.) based on a JSON Schema.
  This module provides the handler interface and a configurable default.

  ## Usage

  Implement the `c:Arbor.MCP.Client.Handler.handle_elicitation_create/3` callback in
  your handler:

      defmodule MyApp.MCPHandler do
        use Arbor.MCP.Client.Handler

        @impl true
        def handle_elicitation_create(message, requested_schema, state) do
          # Present the elicitation to your UI
          case MyApp.UI.prompt_user(message, requested_schema) do
            {:ok, user_data} ->
              {:ok, %{"action" => "accept", "content" => user_data}, state}
            :cancelled ->
              {:ok, %{"action" => "cancel"}, state}
            :declined ->
              {:ok, %{"action" => "decline"}, state}
          end
        end
      end

  ## Actions

  The response `action` field must be one of:
  - `"accept"` — user provided data (include `content` with the values)
  - `"decline"` — user chose not to provide data
  - `"cancel"` — user cancelled the operation

  ## Schema Defaults

  When auto-accept is enabled (`:elicitation_auto_accept` config),
  the handler populates default values from the schema:

      config :arbor_mcp, elicitation_auto_accept: true

  This is intended for automated testing only. In production, always
  present elicitations to the user.
  """

  @doc """
  Process an elicitation request and return a response.

  Called by the request handler when no custom handler is defined.
  Behavior depends on `:elicitation_auto_accept` config:

  - `true` — auto-accept with defaults from schema (testing mode)
  - `false` (default) — decline (no user to present to)
  """
  @spec handle(String.t(), map()) :: map()
  def handle(message, requested_schema) do
    if Application.get_env(:arbor_mcp, :elicitation_auto_accept, false) do
      accept_with_defaults(requested_schema)
    else
      decline(message)
    end
  end

  @doc """
  Accept an elicitation with default values from the schema.
  """
  @spec accept_with_defaults(map()) :: map()
  def accept_with_defaults(requested_schema) do
    content = Arbor.MCP.Testing.SchemaGenerator.generate_args(requested_schema)
    %{"action" => "accept", "content" => content}
  end

  @doc """
  Decline an elicitation.
  """
  @spec decline(String.t()) :: map()
  def decline(_message) do
    %{"action" => "decline"}
  end

  @doc """
  Cancel an elicitation.
  """
  @spec cancel() :: map()
  def cancel do
    %{"action" => "cancel"}
  end
end
