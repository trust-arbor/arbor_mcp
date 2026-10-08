defmodule Arbor.MCP.Types.V20250618 do
  @moduledoc """
  Type definitions for MCP protocol version 2025-06-18.

  This module contains type definitions specific to the 2025-06-18
  version of the Model Context Protocol specification.

  Key changes from 2025-03-26:
  - Removed JSON-RPC batching support
  - Added structured tool output (structuredOutput field)
  - OAuth 2.1 Resource Server classification
  - Elicitation support (now stable)
  - Resource links in tool results
  - MCP-Protocol-Version header requirement for HTTP
  - _meta fields for extensibility
  - context field in completion requests
  - title fields for human-friendly display names
  """

  # Protocol version constant
  @protocol_version "2025-06-18"
  def protocol_version, do: @protocol_version

  # Re-export common types that haven't changed
  @type json_value :: any()
  @type json_schema :: map()
  @type request_id :: Arbor.MCP.Types.request_id()
  @type cursor :: Arbor.MCP.Types.cursor()
  @type progress_token :: Arbor.MCP.Types.progress_token()
  @type log_level :: Arbor.MCP.Types.log_level()

  @typedoc """
  Meta field for extensibility. Can be added to most protocol objects.
  """
  @type meta :: %{optional(String.t()) => any()}

  @typedoc """
  Client capabilities for 2025-06-18.
  Elicitation is now a stable feature.
  """
  @type client_capabilities :: %{
          optional(:experimental) => %{String.t() => any()},
          optional(:sampling) => %{String.t() => any()},
          optional(:roots) => %{
            optional(:listChanged) => boolean()
          },
          # Elicitation capability (stable in 2025-06-18)
          optional(:elicitation) => %{},
          optional(:_meta) => meta()
        }

  @typedoc """
  Server capabilities for 2025-06-18.
  Note: No batch support in this version.
  """
  @type server_capabilities :: %{
          optional(:experimental) => %{String.t() => any()},
          optional(:prompts) => %{
            optional(:listChanged) => boolean()
          },
          optional(:resources) => %{
            optional(:subscribe) => boolean(),
            optional(:listChanged) => boolean()
          },
          optional(:tools) => %{
            optional(:listChanged) => boolean()
          },
          optional(:logging) => %{
            optional(:setLevel) => boolean()
          },
          optional(:completions) => %{},
          optional(:_meta) => meta()
        }

  @typedoc """
  Tool definition with output schema support and title field.
  """
  @type tool :: %{
          required(:name) => String.t(),
          # New: human-friendly display name
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          required(:inputSchema) => json_schema(),
          # Structured output support
          optional(:outputSchema) => json_schema(),
          optional(:annotations) => tool_annotations(),
          optional(:_meta) => meta()
        }

  @type tool_annotations :: %{
          optional(:readOnlyHint) => boolean(),
          optional(:destructiveHint) => boolean(),
          optional(:idempotentHint) => boolean(),
          optional(:openWorldHint) => boolean()
        }

  @typedoc """
  Enhanced tool result with structured output and resource links.
  """
  @type call_tool_result :: %{
          optional(:content) => [Arbor.MCP.Types.content()],
          # New: structured output
          optional(:structuredOutput) => any(),
          # New: resource links
          optional(:resourceLinks) => [resource_link()],
          optional(:isError) => boolean(),
          optional(:_meta) => meta()
        }

  @typedoc """
  Resource link in tool results.
  """
  @type resource_link :: %{
          required(:uri) => String.t(),
          optional(:title) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:_meta) => meta()
        }

  @typedoc """
  Resource with title field.
  """
  @type resource :: %{
          required(:uri) => String.t(),
          # New: human-friendly display name
          optional(:title) => String.t(),
          # Programmatic identifier
          optional(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:annotations) => Arbor.MCP.Types.annotations(),
          optional(:_meta) => meta()
        }

  @typedoc """
  Prompt with title field.
  """
  @type prompt :: %{
          required(:name) => String.t(),
          # New: human-friendly display name
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:arguments) => [Arbor.MCP.Types.prompt_argument()],
          optional(:annotations) => Arbor.MCP.Types.annotations(),
          optional(:_meta) => meta()
        }

  @typedoc """
  Completion request with context field.
  """
  @type completion_request :: %{
          required(:ref) => String.t(),
          required(:argument) => %{
            required(:name) => String.t(),
            required(:value) => String.t()
          },
          # New: context field
          optional(:context) => %{String.t() => any()},
          optional(:_meta) => meta()
        }

  @typedoc """
  OAuth 2.1 protected resource metadata.
  Server metadata for OAuth 2.1 Resource Server classification.
  """
  @type protected_resource_metadata :: %{
          required(:authorization_server) => String.t(),
          required(:resource) => String.t(),
          optional(:scopes) => [String.t()],
          optional(:_meta) => meta()
        }

  # Elicitation types (stable in 2025-06-18)
  @typedoc """
  Primitive schema for elicitation fields.
  """
  @type primitive_schema :: %{
          required(:type) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:enum) => [String.t()],
          optional(:enumNames) => [String.t()],
          optional(:default) => any(),
          optional(:minLength) => integer(),
          optional(:maxLength) => integer(),
          optional(:minimum) => number(),
          optional(:maximum) => number(),
          optional(:format) => String.t()
        }

  @typedoc """
  Elicitation request (stable feature).
  """
  @type elicit_request :: %{
          required(:message) => String.t(),
          required(:requestedSchema) => %{
            required(:type) => String.t(),
            required(:properties) => %{String.t() => primitive_schema()},
            optional(:required) => [String.t()]
          },
          optional(:_meta) => meta()
        }

  @typedoc """
  Elicitation result.
  """
  @type elicit_result :: %{
          # "accept", "decline", or "cancel"
          required(:action) => String.t(),
          optional(:content) => %{String.t() => any()},
          optional(:_meta) => meta()
        }

  # Note: The following types are REMOVED in 2025-06-18:
  # - jsonrpc_batch_request
  # - jsonrpc_batch_response
  # Batch processing is no longer supported in this version.
end
