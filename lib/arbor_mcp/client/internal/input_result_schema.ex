defmodule Arbor.MCP.Client.Internal.InputResultSchema do
  @moduledoc false
  # The results an MRTR input response may be, by the MCP 2026-07-28 schema:
  # `ElicitResult`, `CreateMessageResult` and `ListRootsResult`, with every
  # definition they reference. They are a copy of the definitions in
  # docs/mcp-specs/2026-07-28/schema.json, which isn't in the Hex package; a
  # test keeps the copy equal to that file, so a spec sync that changes them
  # fails until this copy follows.

  alias Arbor.MCP.Content.SchemaPolicy.ModernResolver

  @results ["ElicitResult", "CreateMessageResult", "ListRootsResult"]

  @definitions %{
    "Annotations" => %{
      "description" =>
        "Optional annotations for the client. The client can use annotations to inform how objects are used or displayed",
      "properties" => %{
        "audience" => %{
          "description" =>
            "Describes who the intended audience of this object or data is.\n\nIt can include multiple entries to indicate content useful for multiple audiences (e.g., `[\"user\", \"assistant\"]`).",
          "items" => %{"$ref" => "#/$defs/Role"},
          "type" => "array"
        },
        "lastModified" => %{
          "description" =>
            "The moment the resource was last modified, as an ISO 8601 formatted string.\n\nShould be an ISO 8601 formatted string (e.g., \"2025-01-12T15:00:58Z\").\n\nExamples: last activity timestamp in an open file, timestamp when the resource\nwas attached, etc.",
          "type" => "string"
        },
        "priority" => %{
          "description" =>
            "Describes how important this data is for operating the server.\n\nA value of 1 means \"most important,\" and indicates that the data is\neffectively required, while 0 means \"least important,\" and indicates that\nthe data is entirely optional.",
          "maximum" => 1,
          "minimum" => 0,
          "type" => "number"
        }
      },
      "type" => "object"
    },
    "AudioContent" => %{
      "description" => "Audio provided to or from an LLM.",
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "annotations" => %{
          "$ref" => "#/$defs/Annotations",
          "description" => "Optional annotations for the client."
        },
        "data" => %{
          "description" => "The base64-encoded audio data.",
          "format" => "byte",
          "type" => "string"
        },
        "mimeType" => %{
          "description" =>
            "The MIME type of the audio. Different providers may support different audio types.",
          "type" => "string"
        },
        "type" => %{"const" => "audio", "type" => "string"}
      },
      "required" => ["data", "mimeType", "type"],
      "type" => "object"
    },
    "BlobResourceContents" => %{
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "blob" => %{
          "description" => "A base64-encoded string representing the binary data of the item.",
          "format" => "byte",
          "type" => "string"
        },
        "mimeType" => %{
          "description" => "The MIME type of this resource, if known.",
          "type" => "string"
        },
        "uri" => %{
          "description" => "The URI of this resource.",
          "format" => "uri",
          "type" => "string"
        }
      },
      "required" => ["blob", "uri"],
      "type" => "object"
    },
    "ContentBlock" => %{
      "anyOf" => [
        %{"$ref" => "#/$defs/TextContent"},
        %{"$ref" => "#/$defs/ImageContent"},
        %{"$ref" => "#/$defs/AudioContent"},
        %{"$ref" => "#/$defs/ResourceLink"},
        %{"$ref" => "#/$defs/EmbeddedResource"}
      ]
    },
    "CreateMessageResult" => %{
      "description" =>
        "The result returned by the client for a {@link CreateMessageRequestsampling/createMessage} request.\nThe client should inform the user before returning the sampled message, to allow them\nto inspect the response (human in the loop) and decide whether to allow the server to see it.",
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "content" => %{
          "anyOf" => [
            %{"$ref" => "#/$defs/TextContent"},
            %{"$ref" => "#/$defs/ImageContent"},
            %{"$ref" => "#/$defs/AudioContent"},
            %{"$ref" => "#/$defs/ToolUseContent"},
            %{"$ref" => "#/$defs/ToolResultContent"},
            %{"items" => %{"$ref" => "#/$defs/SamplingMessageContentBlock"}, "type" => "array"}
          ]
        },
        "model" => %{
          "description" => "The name of the model that generated the message.",
          "type" => "string"
        },
        "role" => %{"$ref" => "#/$defs/Role"},
        "stopReason" => %{
          "description" =>
            "The reason why sampling stopped, if known.\n\nStandard values:\n- `\"endTurn\"`: Natural end of the assistant's turn\n- `\"stopSequence\"`: A stop sequence was encountered\n- `\"maxTokens\"`: Maximum token limit was reached\n- `\"toolUse\"`: The model wants to use one or more tools\n\nThis field is an open string to allow for provider-specific stop reasons.",
          "type" => "string"
        }
      },
      "required" => ["content", "model", "role"],
      "type" => "object"
    },
    "ElicitResult" => %{
      "description" =>
        "The result returned by the client for an {@link ElicitRequestelicitation/create} request.",
      "properties" => %{
        "action" => %{
          "description" =>
            "The user action in response to the elicitation.\n- `\"accept\"`: User submitted the form/confirmed the action\n- `\"decline\"`: User explicitly declined the action\n- `\"cancel\"`: User dismissed without making an explicit choice",
          "enum" => ["accept", "cancel", "decline"],
          "type" => "string"
        },
        "content" => %{
          "additionalProperties" => %{
            "anyOf" => [
              %{"items" => %{"type" => "string"}, "type" => "array"},
              %{"type" => ["string", "integer", "boolean"]}
            ]
          },
          "description" =>
            "The submitted form data, only present when action is `\"accept\"` and mode was `\"form\"`.\nContains values matching the requested schema.\nOmitted for out-of-band mode responses.",
          "type" => "object"
        }
      },
      "required" => ["action"],
      "type" => "object"
    },
    "EmbeddedResource" => %{
      "description" =>
        "The contents of a resource, embedded into a prompt or tool call result.\n\nIt is up to the client how best to render embedded resources for the benefit\nof the LLM and/or the user.",
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "annotations" => %{
          "$ref" => "#/$defs/Annotations",
          "description" => "Optional annotations for the client."
        },
        "resource" => %{
          "anyOf" => [
            %{"$ref" => "#/$defs/TextResourceContents"},
            %{"$ref" => "#/$defs/BlobResourceContents"}
          ]
        },
        "type" => %{"const" => "resource", "type" => "string"}
      },
      "required" => ["resource", "type"],
      "type" => "object"
    },
    "Icon" => %{
      "description" => "An optionally-sized icon that can be displayed in a user interface.",
      "properties" => %{
        "mimeType" => %{
          "description" =>
            "Optional MIME type override if the source MIME type is missing or generic.\nFor example: `\"image/png\"`, `\"image/jpeg\"`, or `\"image/svg+xml\"`.",
          "type" => "string"
        },
        "sizes" => %{
          "description" =>
            "Optional array of strings that specify sizes at which the icon can be used.\nEach string should be in WxH format (e.g., `\"48x48\"`, `\"96x96\"`) or `\"any\"` for scalable formats like SVG.\n\nIf not provided, the client should assume that the icon can be used at any size.",
          "items" => %{"type" => "string"},
          "type" => "array"
        },
        "src" => %{
          "description" =>
            "A standard URI pointing to an icon resource. May be an HTTP/HTTPS URL or a\n`data:` URI with Base64-encoded image data.\n\nConsumers SHOULD take steps to ensure URLs serving icons are from the\nsame domain as the client/server or a trusted domain.\n\nConsumers SHOULD take appropriate precautions when consuming SVGs as they can contain\nexecutable JavaScript.",
          "format" => "uri",
          "type" => "string"
        },
        "theme" => %{
          "description" =>
            "Optional specifier for the theme this icon is designed for. `\"light\"` indicates\nthe icon is designed to be used with a light background, and `\"dark\"` indicates\nthe icon is designed to be used with a dark background.\n\nIf not provided, the client should assume the icon can be used with any theme.",
          "enum" => ["dark", "light"],
          "type" => "string"
        }
      },
      "required" => ["src"],
      "type" => "object"
    },
    "ImageContent" => %{
      "description" => "An image provided to or from an LLM.",
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "annotations" => %{
          "$ref" => "#/$defs/Annotations",
          "description" => "Optional annotations for the client."
        },
        "data" => %{
          "description" => "The base64-encoded image data.",
          "format" => "byte",
          "type" => "string"
        },
        "mimeType" => %{
          "description" =>
            "The MIME type of the image. Different providers may support different image types.",
          "type" => "string"
        },
        "type" => %{"const" => "image", "type" => "string"}
      },
      "required" => ["data", "mimeType", "type"],
      "type" => "object"
    },
    "ListRootsResult" => %{
      "description" =>
        "The result returned by the client for a {@link ListRootsRequestroots/list} request.\nThis result contains an array of {@link Root} objects, each representing a root directory\nor file that the server can operate on.",
      "properties" => %{"roots" => %{"items" => %{"$ref" => "#/$defs/Root"}, "type" => "array"}},
      "required" => ["roots"],
      "type" => "object"
    },
    "MetaObject" => %{
      "description" =>
        "Represents the contents of a `_meta` field, which clients and servers use to attach additional metadata to their interactions.\n\nCertain key names are reserved by MCP for protocol-level metadata; implementations MUST NOT make assumptions about values at these keys. Additionally, specific schema definitions may reserve particular names for purpose-specific metadata, as declared in those definitions.\n\nValid keys have two segments:\n\n**Prefix:**\n- Optional — if specified, MUST be a series of _labels_ separated by dots (`.`), followed by a slash (`/`).\n- Labels MUST start with a letter and end with a letter or digit. Interior characters may be letters, digits, or hyphens (`-`).\n- Implementations SHOULD use reverse DNS notation (e.g., `com.example/` rather than `example.com/`).\n- Any prefix where the second label is `modelcontextprotocol` or `mcp` is **reserved** for MCP use. For example: `io.modelcontextprotocol/`, `dev.mcp/`, `org.modelcontextprotocol.api/`, and `com.mcp.tools/` are all reserved. However, `com.example.mcp/` is NOT reserved, as the second label is `example`.\n\n**Name:**\n- Unless empty, MUST start and end with an alphanumeric character (`[a-z0-9A-Z]`).\n- Interior characters may be alphanumeric, hyphens (`-`), underscores (`_`), or dots (`.`).",
      "type" => "object"
    },
    "ResourceLink" => %{
      "description" =>
        "A resource that the server is capable of reading, included in a prompt or tool call result.\n\nNote: resource links returned by tools are not guaranteed to appear in the results of {@link ListResourcesRequestresources/list} requests.",
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "annotations" => %{
          "$ref" => "#/$defs/Annotations",
          "description" => "Optional annotations for the client."
        },
        "description" => %{
          "description" =>
            "A description of what this resource represents.\n\nThis can be used by clients to improve the LLM's understanding of available resources. It can be thought of like a \"hint\" to the model.",
          "type" => "string"
        },
        "icons" => %{
          "description" =>
            "Optional set of sized icons that the client can display in a user interface.\n\nClients that support rendering icons MUST support at least the following MIME types:\n- `image/png` - PNG images (safe, universal compatibility)\n- `image/jpeg` (and `image/jpg`) - JPEG images (safe, universal compatibility)\n\nClients that support rendering icons SHOULD also support:\n- `image/svg+xml` - SVG images (scalable but requires security precautions)\n- `image/webp` - WebP images (modern, efficient format)",
          "items" => %{"$ref" => "#/$defs/Icon"},
          "type" => "array"
        },
        "mimeType" => %{
          "description" => "The MIME type of this resource, if known.",
          "type" => "string"
        },
        "name" => %{
          "description" =>
            "Intended for programmatic or logical use, but used as a display name in past specs or fallback (if title isn't present).",
          "type" => "string"
        },
        "size" => %{
          "description" =>
            "The size of the raw resource content, in bytes (i.e., before base64 encoding or any tokenization), if known.\n\nThis can be used by Hosts to display file sizes and estimate context window usage.",
          "type" => "integer"
        },
        "title" => %{
          "description" =>
            "Intended for UI and end-user contexts — optimized to be human-readable and easily understood,\neven by those unfamiliar with domain-specific terminology.\n\nIf not provided, the name should be used for display (except for {@link Tool},\nwhere `annotations.title` should be given precedence over using `name`,\nif present).",
          "type" => "string"
        },
        "type" => %{"const" => "resource_link", "type" => "string"},
        "uri" => %{
          "description" => "The URI of this resource.",
          "format" => "uri",
          "type" => "string"
        }
      },
      "required" => ["name", "type", "uri"],
      "type" => "object"
    },
    "Role" => %{
      "description" => "The sender or recipient of messages and data in a conversation.",
      "enum" => ["assistant", "user"],
      "type" => "string"
    },
    "Root" => %{
      "description" => "Represents a root directory or file that the server can operate on.",
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "name" => %{
          "description" =>
            "An optional name for the root. This can be used to provide a human-readable\nidentifier for the root, which may be useful for display purposes or for\nreferencing the root in other parts of the application.",
          "type" => "string"
        },
        "uri" => %{
          "description" =>
            "The URI identifying the root. This *must* start with `file://` for now.\nThis restriction may be relaxed in future versions of the protocol to allow\nother URI schemes.",
          "format" => "uri",
          "type" => "string"
        }
      },
      "required" => ["uri"],
      "type" => "object"
    },
    "SamplingMessageContentBlock" => %{
      "anyOf" => [
        %{"$ref" => "#/$defs/TextContent"},
        %{"$ref" => "#/$defs/ImageContent"},
        %{"$ref" => "#/$defs/AudioContent"},
        %{"$ref" => "#/$defs/ToolUseContent"},
        %{"$ref" => "#/$defs/ToolResultContent"}
      ]
    },
    "TextContent" => %{
      "description" => "Text provided to or from an LLM.",
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "annotations" => %{
          "$ref" => "#/$defs/Annotations",
          "description" => "Optional annotations for the client."
        },
        "text" => %{"description" => "The text content of the message.", "type" => "string"},
        "type" => %{"const" => "text", "type" => "string"}
      },
      "required" => ["text", "type"],
      "type" => "object"
    },
    "TextResourceContents" => %{
      "properties" => %{
        "_meta" => %{"$ref" => "#/$defs/MetaObject"},
        "mimeType" => %{
          "description" => "The MIME type of this resource, if known.",
          "type" => "string"
        },
        "text" => %{
          "description" =>
            "The text of the item. This must only be set if the item can actually be represented as text (not binary data).",
          "type" => "string"
        },
        "uri" => %{
          "description" => "The URI of this resource.",
          "format" => "uri",
          "type" => "string"
        }
      },
      "required" => ["text", "uri"],
      "type" => "object"
    },
    "ToolResultContent" => %{
      "description" => "The result of a tool use, provided by the user back to the assistant.",
      "properties" => %{
        "_meta" => %{
          "$ref" => "#/$defs/MetaObject",
          "description" =>
            "Optional metadata about the tool result. Clients SHOULD preserve this field when\nincluding tool results in subsequent sampling requests to enable caching optimizations."
        },
        "content" => %{
          "description" =>
            "The unstructured result content of the tool use.\n\nThis has the same format as {@link CallToolResult.content} and can include text, images,\naudio, resource links, and embedded resources.",
          "items" => %{"$ref" => "#/$defs/ContentBlock"},
          "type" => "array"
        },
        "isError" => %{
          "description" =>
            "Whether the tool use resulted in an error.\n\nIf true, the content typically describes the error that occurred.\nDefault: false",
          "type" => "boolean"
        },
        "structuredContent" => %{
          "description" =>
            "An optional structured result value.\n\nThis can be any JSON value (object, array, string, number, boolean, or null).\nIf the tool defined an {@link Tool.outputSchema}, this SHOULD conform to that schema."
        },
        "toolUseId" => %{
          "description" =>
            "The ID of the tool use this result corresponds to.\n\nThis MUST match the ID from a previous {@link ToolUseContent}.",
          "type" => "string"
        },
        "type" => %{"const" => "tool_result", "type" => "string"}
      },
      "required" => ["content", "toolUseId", "type"],
      "type" => "object"
    },
    "ToolUseContent" => %{
      "description" => "A request from the assistant to call a tool.",
      "properties" => %{
        "_meta" => %{
          "$ref" => "#/$defs/MetaObject",
          "description" =>
            "Optional metadata about the tool use. Clients SHOULD preserve this field when\nincluding tool uses in subsequent sampling requests to enable caching optimizations."
        },
        "id" => %{
          "description" =>
            "A unique identifier for this tool use.\n\nThis ID is used to match tool results to their corresponding tool uses.",
          "type" => "string"
        },
        "input" => %{
          "additionalProperties" => %{},
          "description" =>
            "The arguments to pass to the tool, conforming to the tool's input schema.",
          "type" => "object"
        },
        "name" => %{"description" => "The name of the tool to call.", "type" => "string"},
        "type" => %{"const" => "tool_use", "type" => "string"}
      },
      "required" => ["id", "input", "name", "type"],
      "type" => "object"
    }
  }

  # Built once, at compile time. Formats stay annotations, as in the
  # library's other draft 2020-12 schemas (Arbor.MCP.Content.SchemaPolicy).
  @root JSV.build!(
          %{
            "$schema" => "https://json-schema.org/draft/2020-12/schema",
            "anyOf" => Enum.map(@results, &%{"$ref" => "#/$defs/" <> &1}),
            "$defs" => @definitions
          },
          default_meta: "https://json-schema.org/draft/2020-12/schema",
          resolver: {ModernResolver, %{}},
          atoms: false,
          warnings: :silence,
          formats: nil
        )

  @doc false
  @spec results() :: [String.t()]
  def results, do: @results

  @doc false
  @spec definitions() :: map()
  def definitions, do: @definitions

  # Whether a decoded JSON value is one of the results.
  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(response),
    do: match?({:ok, _data}, JSV.validate(response, @root, cast: false, cast_formats: false))
end
