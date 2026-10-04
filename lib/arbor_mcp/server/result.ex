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

  alias Arbor.MCP.Server.ResultNormalizer

  @type structured_value :: map() | list() | String.t() | number() | boolean() | nil

  @doc """
  Builds a text tool result.
  """
  @spec text(String.t()) :: map()
  def text(text) when is_binary(text), do: %{content: [%{type: "text", text: text}]}

  @doc """
  Builds an error tool result.
  """
  @spec error(any()) :: map()
  def error(reason) when is_binary(reason),
    do: %{content: [%{type: "text", text: reason}], isError: true}

  def error(reason), do: reason |> safe_error_message() |> error()

  @doc """
  Builds an error result with optional structured content.

  `:structured_content` accepts a plain JSON value, including `false` and `nil`.
  Explicit `nil` emits JSON null; an omitted option emits no field. Binary messages are preserved;
  nonbinary reasons expose only an authored atom or binary `message` field.
  Other reasons produce the fixed text `"Tool execution failed"`.
  """
  @spec error(term(), keyword()) :: map()
  def error(reason, opts) do
    validate_options!(opts, [:structured_content])

    result = error(reason)

    case Keyword.fetch(opts, :structured_content) do
      {:ok, value} -> Map.put(result, :structuredContent, value)
      :error -> result
    end
  end

  @doc """
  Wraps a list of plain MCP content maps in a complete tool result.

  Content entries and nested values remain unchanged. Protocol output admission
  validates their JSON representation and applies the runtime's byte limits.
  """
  @spec content([map()]) :: map()
  def content(entries) do
    if content_entries?(entries), do: %{content: entries}, else: invalid_result!()
  end

  @doc """
  Builds an image result from already-base64 data and an explicit MIME type.
  """
  @spec image(String.t(), String.t()) :: map()
  def image(data, mime_type), do: media("image", data, mime_type)

  @doc """
  Builds an audio result from already-base64 data and an explicit MIME type.
  """
  @spec audio(String.t(), String.t()) :: map()
  def audio(data, mime_type), do: media("audio", data, mime_type)

  @doc """
  Builds an embedded resource result from resource contents.

  Contents require a nonempty `uri` and exactly one binary `text` or base64
  `blob`. Optional `mimeType` must be a nonempty binary and `_meta` a plain map.
  Atom or string keys are accepted; duplicate spellings of these fields are
  rejected. A URI by itself is not embedded resource content.
  """
  @spec resource(map()) :: map()
  def resource(contents) do
    validate_resource!(contents)
    content([%{type: "resource", resource: contents}])
  end

  @doc """
  Builds a tool result with text and a structured JSON value.

  Modern MCP accepts objects, arrays, strings, numbers, booleans and null.
  Legacy tool results require an object; dispatch rejects unsupported values
  for that era before committing callback state. Nested values are preserved
  until protocol output admission validates their JSON shape and byte limits.
  """
  @spec structured(String.t(), structured_value()) :: map()
  def structured(text, data) when is_binary(text) do
    unless structured_value?(data), do: invalid_result!()
    %{content: [%{type: "text", text: text}], structuredContent: data}
  end

  def structured(_text, _data), do: invalid_result!()

  @doc """
  Builds a text and structured-content result with optional `:is_error`.

  The option must be a boolean. Explicit null and false remain present;
  omission of `:is_error` leaves the field absent.
  """
  @spec structured(String.t(), structured_value(), keyword()) :: map()
  def structured(text, data, opts) when is_binary(text) do
    validate_options!(opts, [:is_error])
    structured(text, data) |> put_optional(:isError, Keyword.get(opts, :is_error))
  end

  def structured(_text, _data, _opts), do: invalid_result!()

  @doc """
  Suspends a modern tool, resource, or prompt result for MRTR input.

  The optional application state must be JSON encodable. Arbor.MCP seals it into
  an opaque `requestState`; handlers can read it on the retry through
  `Arbor.MCP.Server.Context.request_state/0`.
  """
  @spec input_required(map(), term()) :: Arbor.MCP.Server.MRTR.InputRequired.t()
  def input_required(input_requests, request_state \\ nil) when is_map(input_requests) do
    %Arbor.MCP.Server.MRTR.InputRequired{
      input_requests: input_requests,
      request_state: request_state
    }
  end

  @doc false
  def normalize_tool({:ok, result}, state), do: {:ok, normalize_tool_result(result), state}

  def normalize_tool({:ok, result, new_state}, _state),
    do: {:ok, normalize_tool_result(result), new_state}

  def normalize_tool({:error, reason}, state), do: {:ok, error(reason), state}
  def normalize_tool({:error, reason, new_state}, _state), do: {:ok, error(reason), new_state}

  @doc false
  def normalize_tool_result(result) when is_binary(result), do: text(result)
  def normalize_tool_result(%Arbor.MCP.Server.MRTR.InputRequired{} = result), do: result
  def normalize_tool_result(text: value) when is_binary(value), do: text(value)
  def normalize_tool_result(entries) when is_list(entries), do: content(entries)

  def normalize_tool_result(result) when is_map(result) and not is_struct(result) do
    cond do
      result_field?(result, :content) ->
        unless content_entries?(field!(result, :content)), do: invalid_result!()
        normalize_structured_key(result)

      result_field?(result, :structuredContent) or result_field?(result, :structuredOutput) ->
        normalize_structured_key(result) |> put_empty_content()

      is_binary(Map.get(result, :text)) ->
        text(result.text)

      is_binary(Map.get(result, "text")) ->
        text(result["text"])

      true ->
        invalid_result!()
    end
  end

  def normalize_tool_result(_result), do: invalid_result!()

  @doc false
  def normalize_resource({:ok, result}, uri, mime_type, state) do
    {:ok, normalize_resource_result(result, uri, mime_type), state}
  end

  def normalize_resource({:ok, result, new_state}, uri, mime_type, _state) do
    {:ok, normalize_resource_result(result, uri, mime_type), new_state}
  end

  def normalize_resource({:error, reason}, _uri, _mime_type, state), do: {:error, reason, state}

  def normalize_resource({:error, reason, new_state}, _uri, _mime_type, _state),
    do: {:error, reason, new_state}

  @doc false
  def normalize_prompt({:ok, result}, state), do: {:ok, normalize_prompt_result(result), state}

  def normalize_prompt({:ok, result, new_state}, _state),
    do: {:ok, normalize_prompt_result(result), new_state}

  def normalize_prompt({:error, reason}, state), do: {:error, reason, state}
  def normalize_prompt({:error, reason, new_state}, _state), do: {:error, reason, new_state}

  defp normalize_structured_key(result) do
    if result_field?(result, :structuredOutput) do
      legacy = field!(result, :structuredOutput)

      key =
        if Map.has_key?(result, "structuredOutput"),
          do: "structuredContent",
          else: :structuredContent

      result = Map.drop(result, [:structuredOutput, "structuredOutput"])

      result =
        if result_field?(result, :structuredContent),
          do: result,
          else: Map.put(result, key, legacy)

      put_empty_content(result)
    else
      result
    end
  end

  defp put_empty_content(result) do
    if result_field?(result, :content) do
      result
    else
      key = if Map.has_key?(result, "structuredContent"), do: "content", else: :content
      Map.put(result, key, [])
    end
  end

  defp media(type, data, mime_type) do
    unless base64?(data) and nonempty_binary?(mime_type), do: invalid_result!()
    content([%{type: type, data: data, mimeType: mime_type}])
  end

  defp validate_resource!(contents) when is_map(contents) and not is_struct(contents) do
    uri = field!(contents, :uri)
    text? = result_field?(contents, :text)
    blob? = result_field?(contents, :blob)

    unless nonempty_binary?(uri) and text? != blob?, do: invalid_result!()
    if text? and not is_binary(field!(contents, :text)), do: invalid_result!()
    if blob? and not base64?(field!(contents, :blob)), do: invalid_result!()
    validate_optional_field!(contents, :mimeType, &nonempty_binary?/1)
    validate_optional_field!(contents, :_meta, &plain_map?/1)
  end

  defp validate_resource!(_contents), do: invalid_result!()

  defp validate_optional_field!(map, key, predicate) do
    if result_field?(map, key) and not predicate.(field!(map, key)), do: invalid_result!()
  end

  defp validate_options!(opts, allowed) do
    unless Keyword.keyword?(opts), do: invalid_result!()
    keys = Keyword.keys(opts)
    unless length(keys) == length(Enum.uniq(keys)), do: invalid_result!()
    unless Enum.all?(keys, &(&1 in allowed)), do: invalid_result!()
    validate_option!(opts, :is_error, &is_boolean/1)
    validate_option!(opts, :structured_content, &structured_value?/1)
  end

  defp validate_option!(opts, key, predicate) do
    if Keyword.has_key?(opts, key) and not predicate.(Keyword.get(opts, key)),
      do: invalid_result!()
  end

  defp result_field?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp field!(map, key) do
    string_key = Atom.to_string(key)
    if Map.has_key?(map, key) and Map.has_key?(map, string_key), do: invalid_result!()
    Map.get(map, key, Map.get(map, string_key))
  end

  defp content_entries?([]), do: true
  defp content_entries?([entry | rest]), do: plain_map?(entry) and content_entries?(rest)
  defp content_entries?(_entries), do: false
  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp structured_value?(value) when is_map(value), do: not is_struct(value)
  defp structured_value?(value) when is_list(value), do: proper_list?(value)

  defp structured_value?(value),
    do: is_binary(value) or is_number(value) or value in [true, false, nil]

  defp proper_list?([]), do: true
  defp proper_list?([_item | rest]), do: proper_list?(rest)
  defp proper_list?(_improper), do: false
  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0
  defp base64?(value) when is_binary(value), do: match?({:ok, _}, Base.decode64(value))
  defp base64?(_value), do: false

  defp safe_error_message(reason) when is_atom(reason) and reason not in [nil, true, false],
    do: ResultNormalizer.error_message("Tool execution failed", reason)

  defp safe_error_message(%{message: message}) when is_binary(message),
    do: ResultNormalizer.error_message("Tool execution failed", message)

  defp safe_error_message(%{"message" => message}) when is_binary(message),
    do: ResultNormalizer.error_message("Tool execution failed", message)

  defp safe_error_message(_reason), do: "Tool execution failed"

  defp invalid_result!, do: raise(ArgumentError, "Invalid tool result or result options")

  defp normalize_resource_result(result, uri, mime_type) when is_binary(result) do
    %{uri: uri, text: result}
    |> put_optional(:mimeType, mime_type)
  end

  defp normalize_resource_result(
         %Arbor.MCP.Server.MRTR.InputRequired{} = result,
         _uri,
         _mime_type
       ),
       do: result

  defp normalize_resource_result(%{text: _} = result, uri, mime_type) do
    result
    |> Map.put_new(:uri, uri)
    |> put_optional(:mimeType, mime_type)
  end

  defp normalize_resource_result(%{blob: _} = result, uri, mime_type) do
    result
    |> Map.put_new(:uri, uri)
    |> put_optional(:mimeType, mime_type)
  end

  defp normalize_resource_result(result, _uri, _mime_type), do: result

  defp normalize_prompt_result(%{messages: _} = result), do: result
  defp normalize_prompt_result(%Arbor.MCP.Server.MRTR.InputRequired{} = result), do: result
  defp normalize_prompt_result(text: text) when is_binary(text), do: normalize_prompt_result(text)
  defp normalize_prompt_result(messages) when is_list(messages), do: %{messages: messages}

  defp normalize_prompt_result(text) when is_binary(text) do
    %{messages: [%{role: "user", content: %{type: "text", text: text}}]}
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
