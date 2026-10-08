defmodule Arbor.MCP.Content.SchemaPolicy.Modern do
  @moduledoc false

  alias Arbor.MCP.Content.SchemaPolicy.{Compiled, ModernResolver}

  @meta "https://json-schema.org/draft/2020-12/schema"
  @vocabularies MapSet.new(~w(
    https://json-schema.org/draft/2020-12/vocab/core
    https://json-schema.org/draft/2020-12/vocab/applicator
    https://json-schema.org/draft/2020-12/vocab/validation
    https://json-schema.org/draft/2020-12/vocab/unevaluated
    https://json-schema.org/draft/2020-12/vocab/meta-data
    https://json-schema.org/draft/2020-12/vocab/format-annotation
    https://json-schema.org/draft/2020-12/vocab/format-assertion
    https://json-schema.org/draft/2020-12/vocab/content
  ))

  @spec validate_shape(map() | boolean()) :: :ok | {:error, term()}
  def validate_shape(schema) do
    with :ok <- guard_document(schema),
         {:normal, meta} <- ModernResolver.resolve(@meta, %{}),
         {:ok, meta_root} <- JSV.build(meta, build_options(%{})),
         {:ok, _data} <- JSV.validate(schema, meta_root, cast: false, cast_formats: false) do
      :ok
    else
      _error -> invalid_schema()
    end
  end

  @spec compile(map() | boolean(), map()) :: {:ok, Compiled.t()} | {:error, term()}
  def compile(schema, documents) do
    with :ok <- guard_document(schema),
         :ok <- guard_documents(documents),
         {:ok, root} <- JSV.build(schema, build_options(documents)) do
      {:ok, Compiled.new(root)}
    else
      _error -> invalid_schema()
    end
  end

  defp guard_documents(documents) do
    Enum.reduce_while(documents, :ok, fn {_uri, document}, :ok ->
      case guard_document(document) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp build_options(documents) do
    [
      default_meta: @meta,
      resolver: {ModernResolver, documents},
      atoms: false,
      warnings: :silence,
      formats: nil
    ]
  end

  # A reference can target data under const/default or an unknown annotation.
  # Scan the complete document before JSV's build-time extension callbacks.
  defp guard_document(map) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case guard_pair(key, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp guard_document(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn value, :ok ->
      case guard_document(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp guard_document(_scalar), do: :ok

  defp guard_pair(key, _value) when key in ["jsv-cast", "x-jsv-cast"], do: invalid_schema()

  defp guard_pair("$id", value) when is_binary(value) do
    if URI.parse(value).scheme in ["jsv", "file", "local"],
      do: invalid_schema(),
      else: :ok
  end

  defp guard_pair(key, value)
       when key in ["$ref", "$dynamicRef", "$recursiveRef", "$schema"] and is_binary(value) do
    if URI.parse(value).scheme in [nil, "http", "https"],
      do: :ok,
      else: invalid_schema()
  end

  defp guard_pair("$vocabulary", value) when is_map(value) do
    if Enum.all?(value, fn {uri, required?} ->
         required? == false or MapSet.member?(@vocabularies, uri)
       end),
       do: :ok,
       else: invalid_schema()
  end

  defp guard_pair(_key, value), do: guard_document(value)

  defp invalid_schema,
    do: {:error, {:invalid_schema, "schema declaration is invalid or unsupported"}}
end
