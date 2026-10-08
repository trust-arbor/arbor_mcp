defmodule Arbor.MCP.Types.V20251125 do
  @moduledoc """
  Type definitions for MCP protocol version 2025-11-25.

  This module contains type definitions specific to the 2025-11-25
  version of the Model Context Protocol specification.

  Key changes from 2025-06-18:
  - Tasks: experimental async state machines for long-running tool calls
  - URL-mode elicitation: server can send URL instead of form schema
  - Icons metadata on tools, resources, prompts, and serverInfo
  - Tool calling in sampling (tools and toolChoice in createMessage)
  - Enhanced OAuth/OIDC authorization with incremental scope
  - Tool name validation (alphanumeric, dots, hyphens, underscores)
  - title/description fields on Implementation
  - size/lastModified fields on resource annotations
  """

  @protocol_version "2025-11-25"
  def protocol_version, do: @protocol_version

  # Re-export common types
  @type json_value :: any()
  @type json_schema :: map()
  @type request_id :: Arbor.MCP.Types.request_id()
  @type cursor :: Arbor.MCP.Types.cursor()
  @type progress_token :: Arbor.MCP.Types.progress_token()
  @type log_level :: Arbor.MCP.Types.log_level()

  @typedoc """
  Meta field for extensibility.
  """
  @type meta :: %{optional(String.t()) => any()}

  # --- Icons ---

  @typedoc """
  Icon metadata for tools, resources, prompts, and server info.
  """
  @type icon :: %{
          required(:src) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:sizes) => String.t(),
          optional(:theme) => String.t()
        }

  # --- Implementation ---

  @typedoc """
  Implementation info with title and description fields (new in 2025-11-25).
  """
  @type implementation :: %{
          required(:name) => String.t(),
          required(:version) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:websiteUrl) => String.t(),
          optional(:icons) => [icon()]
        }

  # --- Capabilities ---

  @typedoc """
  Client capabilities for 2025-11-25.
  """
  @type client_capabilities :: %{
          optional(:experimental) => %{String.t() => any()},
          optional(:sampling) => %{String.t() => any()},
          optional(:roots) => %{
            optional(:listChanged) => boolean()
          },
          optional(:elicitation) => %{},
          optional(:_meta) => meta()
        }

  @typedoc """
  Server capabilities for 2025-11-25.
  Adds tasks capability.
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
            optional(:listChanged) => boolean(),
            optional(:outputSchema) => boolean()
          },
          optional(:logging) => %{},
          optional(:completions) => %{},
          optional(:tasks) => %{},
          optional(:_meta) => meta()
        }

  # --- Tool ---

  @typedoc """
  Tool annotations.
  """
  @type tool_annotations :: %{
          optional(:title) => String.t(),
          optional(:readOnlyHint) => boolean(),
          optional(:destructiveHint) => boolean(),
          optional(:idempotentHint) => boolean(),
          optional(:openWorldHint) => boolean()
        }

  @typedoc """
  Task support configuration on a tool.
  """
  @type task_support :: %{
          optional(:taskSupport) => :required | :optional | :forbidden
        }

  @typedoc """
  Tool definition with icons and execution/task support (new in 2025-11-25).
  """
  @type tool :: %{
          required(:name) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          required(:inputSchema) => json_schema(),
          optional(:outputSchema) => json_schema(),
          optional(:annotations) => tool_annotations(),
          optional(:icons) => [icon()],
          optional(:execution) => task_support(),
          optional(:_meta) => meta()
        }

  # --- Resource ---

  @typedoc """
  Resource with icons, size, and lastModified (new in 2025-11-25).
  """
  @type resource :: %{
          required(:uri) => String.t(),
          optional(:title) => String.t(),
          optional(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:mimeType) => String.t(),
          optional(:annotations) => resource_annotations(),
          optional(:icons) => [icon()],
          optional(:size) => integer(),
          optional(:lastModified) => String.t(),
          optional(:_meta) => meta()
        }

  @typedoc """
  Resource annotations with lastModified (new in 2025-11-25).
  """
  @type resource_annotations :: %{
          optional(:audience) => [Arbor.MCP.Types.role()],
          optional(:priority) => float(),
          optional(:lastModified) => String.t()
        }

  # --- Prompt ---

  @typedoc """
  Prompt with icons (new in 2025-11-25).
  """
  @type prompt :: %{
          required(:name) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:arguments) => [Arbor.MCP.Types.prompt_argument()],
          optional(:annotations) => Arbor.MCP.Types.annotations(),
          optional(:icons) => [icon()],
          optional(:_meta) => meta()
        }

  # --- Tool result ---

  @typedoc """
  Enhanced tool result.
  """
  @type call_tool_result :: %{
          optional(:content) => [Arbor.MCP.Types.content()],
          optional(:structuredContent) => any(),
          optional(:resourceLinks) => [Arbor.MCP.Types.V20250618.resource_link()],
          optional(:isError) => boolean(),
          optional(:_meta) => meta()
        }

  # --- Tasks ---

  @typedoc """
  Task state enum.
  """
  @type task_state :: :working | :input_required | :completed | :failed | :cancelled

  @typedoc """
  Task struct representing an async operation.
  """
  @type task :: %{
          required(:taskId) => String.t(),
          required(:status) => task_state(),
          optional(:statusMessage) => String.t(),
          required(:createdAt) => String.t(),
          required(:lastUpdatedAt) => String.t(),
          required(:ttl) => integer(),
          optional(:pollInterval) => integer()
        }

  @typedoc """
  Result of creating a task (immediate response to tools/call with task support).
  """
  @type create_task_result :: %{
          required(:taskId) => String.t(),
          required(:state) => task_state(),
          optional(:metadata) => map()
        }

  # --- URL Elicitation ---

  @typedoc """
  URL-mode elicitation request (new in 2025-11-25).
  Server sends a URL for the client to navigate to instead of a form schema.
  """
  @type url_elicit_request :: %{
          required(:message) => String.t(),
          required(:url) => String.t(),
          required(:mode) => String.t(),
          required(:elicitationId) => String.t(),
          optional(:_meta) => meta()
        }

  # --- Tool calling in sampling ---

  @typedoc """
  Tool choice for sampling/createMessage.
  """
  @type tool_choice :: %{
          optional(:mode) => String.t()
        }

  @typedoc """
  Tool use content type (model using a tool).
  """
  @type tool_use_content :: %{
          required(:type) => String.t(),
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:input) => map()
        }

  @typedoc """
  Tool result content type (result of tool execution).
  """
  @type tool_result_content :: %{
          required(:type) => String.t(),
          required(:toolUseId) => String.t(),
          required(:content) => [Arbor.MCP.Types.content()],
          optional(:isError) => boolean()
        }

  # --- Elicitation result ---

  @typedoc """
  Elicitation result (updated for 2025-11-25 to support URL mode).
  """
  @type elicit_result :: %{
          required(:action) => String.t(),
          optional(:content) => %{String.t() => any()},
          optional(:_meta) => meta()
        }
end
