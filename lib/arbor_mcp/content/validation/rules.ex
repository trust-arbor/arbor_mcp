defmodule Arbor.MCP.Content.Validation.Rules do
  @moduledoc false
  # Validation rule implementations extracted from Content.Validation.

  alias Arbor.MCP.Content.Protocol
  alias Arbor.MCP.Content.Validation.Helpers

  def validate_required_fields(%{type: :text, text: text}) when is_binary(text) and text != "",
    do: :ok

  def validate_required_fields(%{type: :text}),
    do:
      {:error,
       %{
         rule: :required_fields,
         message: "Text content requires non-empty text field",
         severity: :error
       }}

  def validate_required_fields(%{type: :image, data: data, mime_type: mime})
      when is_binary(data) and is_binary(mime),
      do: :ok

  def validate_required_fields(%{type: :image}),
    do:
      {:error,
       %{
         rule: :required_fields,
         message: "Image content requires data and mime_type fields",
         severity: :error
       }}

  def validate_required_fields(_), do: :ok

  def validate_max_size(%{type: :text, text: text}, max_size) do
    if byte_size(text) <= max_size do
      :ok
    else
      {:error,
       %{
         rule: :max_size,
         message: "Content size #{byte_size(text)} exceeds maximum #{max_size}",
         severity: :error
       }}
    end
  end

  def validate_max_size(%{type: type, data: data}, max_size) when type in [:image, :audio] do
    decoded_size =
      case Base.decode64(data) do
        {:ok, decoded} -> byte_size(decoded)
        :error -> byte_size(data)
      end

    if decoded_size <= max_size do
      :ok
    else
      {:error,
       %{
         rule: :max_size,
         message: "Content size #{decoded_size} exceeds maximum #{max_size}",
         severity: :error
       }}
    end
  end

  def validate_max_size(_, _), do: :ok

  def validate_mime_types(%{mime_type: mime_type}, allowed_types) when is_binary(mime_type) do
    if mime_type in allowed_types do
      :ok
    else
      {:error,
       %{
         rule: :mime_types,
         message: "MIME type #{mime_type} not in allowed list",
         severity: :error
       }}
    end
  end

  def validate_mime_types(_, _), do: :ok

  def validate_content_length(%{type: :text, text: text}, max_length) when is_binary(text) do
    if String.length(text) <= max_length do
      :ok
    else
      {:error,
       %{
         rule: :content_length,
         message: "Text length #{String.length(text)} exceeds maximum #{max_length}",
         severity: :error
       }}
    end
  end

  def validate_content_length(_, _), do: :ok

  def scan_malware(content) do
    text = Helpers.extract_text(content)

    if String.contains?(text, ["<script>", "javascript:", "data:text/html"]) do
      {:error,
       %{rule: :scan_malware, message: "Potentially malicious content detected", severity: :error}}
    else
      :ok
    end
  end

  def validate_encoding(%{type: :text, text: text}) do
    if String.valid?(text) do
      :ok
    else
      {:error, %{rule: :validate_encoding, message: "Invalid UTF-8 encoding", severity: :error}}
    end
  end

  def validate_encoding(_), do: :ok

  # `custom_validator` resolves rule atoms that are not built in. It is
  # injected by `Arbor.MCP.Content.Validation` so this module never depends back
  # on the facade that registers custom validators.
  def apply_rule(content, rule, opts, custom_validator \\ fn _rule -> nil end)

  def apply_rule(content, rule, _opts, custom_validator) when is_atom(rule) do
    case rule do
      :required_fields ->
        validate_required_fields(content)

      :protocol_compliance ->
        Protocol.validate(content)

      :scan_malware ->
        scan_malware(content)

      :validate_encoding ->
        validate_encoding(content)

      _ ->
        # Check the injected registry for registered custom validators
        case custom_validator.(rule) do
          nil ->
            {:error, %{rule: rule, message: "Unknown validation rule", severity: :error}}

          validator_fn when is_function(validator_fn, 1) ->
            validator_fn.(content)
        end
    end
  end

  def apply_rule(content, rule, _opts, _custom_validator) do
    case rule do
      {:max_size, size} -> validate_max_size(content, size)
      {:mime_types, types} -> validate_mime_types(content, types)
      {:content_length, max_length} -> validate_content_length(content, max_length)
      {module, function, args} when is_atom(module) -> apply(module, function, [content | args])
      fun when is_function(fun, 1) -> fun.(content)
      _ -> {:error, %{rule: rule, message: "Unknown validation rule", severity: :error}}
    end
  end

  def filter_errors_by_severity(errors, strict, skip_warnings) do
    Enum.filter(errors, fn error ->
      case {strict, skip_warnings, error.severity} do
        {true, _, :warning} -> true
        {_, true, :warning} -> false
        {_, _, :info} when strict -> true
        {_, _, :info} -> false
        {_, _, _} -> true
      end
    end)
  end
end
