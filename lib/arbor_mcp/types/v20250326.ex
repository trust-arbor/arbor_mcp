defmodule Arbor.MCP.Types.V20250326 do
  @moduledoc """
  Type definitions for MCP protocol version 2025-03-26.

  This module contains type definitions specific to the 2025-03-26
  version of the Model Context Protocol specification.
  """

  # Re-export common types
  @type json_value :: any()
  # JSON Schema type - for now just a map
  @type json_schema :: map()
  @type request_id :: Arbor.MCP.Types.request_id()
  @type error_code :: Arbor.MCP.Types.error_code()
  @type cursor :: Arbor.MCP.Types.cursor()
  # Message types
  @type message :: %{
          role: :user | :assistant,
          content: content() | [content()]
        }
  @type content :: Arbor.MCP.Types.content()
  @type content_type :: Arbor.MCP.Types.content_type()
  @type text_content :: Arbor.MCP.Types.text_content()
  @type image_content :: Arbor.MCP.Types.image_content()
  @type audio_content :: Arbor.MCP.Types.audio_content()
  # Resource content
  @type resource_content :: %{
          required(:uri) => String.t(),
          optional(atom()) => any()
        }

  # Version-specific protocol version
  @protocol_version "2025-03-26"
  def protocol_version, do: @protocol_version

  # Full capabilities from 2025-03-26 spec
  @type client_capabilities :: %{
          optional(:experimental) => %{String.t() => any()},
          optional(:sampling) => %{String.t() => any()},
          optional(:roots) => %{
            optional(:listChanged) => boolean()
          }
        }

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
          }
        }

  # Tool without output schema (stable spec)
  @type tool :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          required(:inputSchema) => json_schema()
        }

  # Resource with subscription support
  @type resource :: %{
          required(:uri) => String.t(),
          optional(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:mimeType) => String.t()
        }

  # Subscription types
  @type resource_updated_notification :: %{
          required(:method) => String.t(),
          required(:params) => %{
            required(:uri) => String.t()
          }
        }

  # Logging with setLevel support
  @type log_level ::
          :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency

  @type set_level_request :: %{
          required(:method) => String.t(),
          required(:params) => %{
            required(:level) => log_level()
          }
        }

  # Standard create message params
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
