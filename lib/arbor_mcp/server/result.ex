defmodule Arbor.MCP.Server.Result do
  @moduledoc """
  Complete server results shared by Handler and DSL callbacks.

  When a module uses `Arbor.MCP.Server.DSL`, this module is aliased as `ToolResult`.
  Raw Handler callbacks use the same constructors through `Arbor.MCP.Server.Result`.
  `Arbor.MCP.Server.DSL.Result` forwards its existing functions here.

  ## Building results

      ToolResult.text("hello")
      ToolResult.error("something went wrong")
      ToolResult.structured("done", %{count: 1})
      ToolResult.image(Base.encode64(image_bytes), "image/png")
      ToolResult.resource(%{uri: "file:///notes.txt", text: "notes"})

  ## Normalization

  Handlers may also return plain values; the DSL normalizes them:

  * binaries and `%{text: ...}` → text content
  * plain content-map lists → wrapped as complete tool results
  * atom- or string-keyed content / structured-content maps → preserved
  * unsupported top-level values → rejected before returning callback state
  * `{:ok, result}` / `{:ok, result, state}` / `{:error, reason}` tuples

  Constructors return complete, plain result maps. They do not fetch URIs,
  transform media, infer MIME types, or invoke custom JSON/Inspect protocols.
  Nested application data is preserved; the runtime's protocol output admission
  must still reject unsupported JSON values and enforce output limits.
  """

  alias Arbor.MCP.Server.Internal.Result, as: Implementation

  @type structured_value :: map() | list() | String.t() | number() | boolean() | nil

  @doc """
  Builds a text tool result.
  """
  @spec text(String.t()) :: map()
  defdelegate text(text), to: Implementation

  @doc """
  Builds an error tool result.
  """
  @spec error(any()) :: map()
  defdelegate error(reason), to: Implementation

  @doc """
  Builds an error result with optional structured content.

  `:structured_content` accepts a plain JSON value, including `false` and `nil`.
  Explicit `nil` emits JSON null; an omitted option emits no field. Binary messages are preserved;
  nonbinary reasons expose only an authored atom or binary `message` field.
  Other reasons produce the fixed text `"Tool execution failed"`.
  """
  @spec error(term(), keyword()) :: map()
  defdelegate error(reason, opts), to: Implementation

  @doc """
  Wraps a list of plain MCP content maps in a complete tool result.

  Content entries and nested values remain unchanged. Protocol output admission
  validates their JSON representation and applies the runtime's byte limits.
  """
  @spec content([map()]) :: map()
  defdelegate content(entries), to: Implementation

  @doc """
  Builds an image result from already-base64 data and an explicit MIME type.
  """
  @spec image(String.t(), String.t()) :: map()
  defdelegate image(data, mime_type), to: Implementation

  @doc """
  Builds an audio result from already-base64 data and an explicit MIME type.
  """
  @spec audio(String.t(), String.t()) :: map()
  defdelegate audio(data, mime_type), to: Implementation

  @doc """
  Builds an embedded resource result from resource contents.

  Contents require a nonempty `uri` and exactly one binary `text` or base64
  `blob`. Optional `mimeType` must be a nonempty binary and `_meta` a plain map.
  Atom or string keys are accepted; duplicate spellings of these fields are
  rejected. A URI by itself is not embedded resource content.
  """
  @spec resource(map()) :: map()
  defdelegate resource(contents), to: Implementation

  @doc """
  Builds a tool result with text and a structured JSON value.

  Modern MCP accepts objects, arrays, strings, numbers, booleans and null.
  Legacy tool results require an object; dispatch rejects unsupported values
  for that era before committing callback state. Nested values are preserved
  until protocol output admission validates their JSON shape and byte limits.
  """
  @spec structured(String.t(), structured_value()) :: map()
  defdelegate structured(text, data), to: Implementation

  @doc """
  Builds a text and structured-content result with optional `:is_error`.

  The option must be a boolean. Explicit null and false remain present;
  omission of `:is_error` leaves the field absent.
  """
  @spec structured(String.t(), structured_value(), keyword()) :: map()
  defdelegate structured(text, data, opts), to: Implementation

  @doc """
  Suspends a modern tool, resource, or prompt result for MRTR input.

  The optional application state must be JSON encodable. ArborMCP seals it into
  an opaque `requestState`; handlers can read it on the retry through
  `Arbor.MCP.Server.Context.request_state/0`.
  """
  @spec input_required(map(), term()) :: Arbor.MCP.Server.MRTR.InputRequired.t()
  defdelegate input_required(input_requests, request_state \\ nil), to: Implementation
end
