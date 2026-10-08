defmodule Arbor.MCP.Types.V20241105 do
  @moduledoc """
  Type definitions for MCP protocol version 2024-11-05.

  This module contains type definitions specific to the 2024-11-05
  version of the Model Context Protocol specification.
  """

  # Re-export common types that haven't changed
  @type json_value :: any()
  @type json_schema :: map()
  @type request_id :: Arbor.MCP.Types.request_id()
  @type error_code :: Arbor.MCP.Types.error_code()
  @type cursor :: Arbor.MCP.Types.cursor()

  # Version-specific protocol version
  @protocol_version "2024-11-05"
  def protocol_version, do: @protocol_version

  # Client capabilities for 2024-11-05
  @type client_capabilities :: %{
          optional(:experimental) => %{String.t() => any()},
          optional(:sampling) => %{String.t() => any()},
          optional(:roots) => %{
            optional(:listChanged) => boolean()
          }
        }

  # Server capabilities for 2024-11-05 (no subscription support)
  @type server_capabilities :: %{
          optional(:experimental) => %{String.t() => any()},
          optional(:prompts) => %{
            optional(:listChanged) => boolean()
          },
          optional(:resources) => %{
            # No subscribe capability in 2024-11-05
            optional(:listChanged) => boolean()
          },
          optional(:tools) => %{
            optional(:listChanged) => boolean()
          },
          optional(:logging) => %{String.t() => any()}
        }

  # Tool definition without output schema (not in 2024-11-05)
  @type tool :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          required(:inputSchema) => json_schema()
        }

  # Resource without subscription fields
  @type resource :: %{
          required(:uri) => String.t(),
          optional(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:mimeType) => String.t()
        }

  # Content types in 2024-11-05 (no component type)
  @type text_content :: %{
          required(:type) => :text,
          required(:text) => String.t()
        }

  @type image_content :: %{
          required(:type) => :image,
          required(:data) => String.t(),
          required(:mimeType) => String.t()
        }

  @type resource_content :: %{
          required(:type) => :resource,
          required(:resource) => resource()
        }

  @type content :: text_content() | image_content() | resource_content()

  # Messages without annotations
  @type message :: %{
          required(:role) => :user | :assistant,
          required(:content) => content() | [content()]
        }

  # Sampling without output schema
  @type create_message_params :: %{
          required(:messages) => [message()],
          optional(:modelPreferences) => model_preferences(),
          optional(:systemPrompt) => String.t(),
          optional(:maxTokens) => pos_integer()
        }

  @type model_preferences :: %{
          optional(:hints) => [model_hint()],
          optional(:costPriority) => float(),
          optional(:speedPriority) => float(),
          optional(:intelligencePriority) => float()
        }

  @type model_hint :: %{
          optional(:name) => String.t()
        }
end
