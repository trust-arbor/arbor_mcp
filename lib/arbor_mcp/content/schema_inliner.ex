defmodule Arbor.MCP.Content.SchemaInliner do
  @moduledoc false

  alias Arbor.MCP.Content.SchemaGraph

  @references ~w($ref $dynamicRef $recursiveRef)
  @type documents :: %{optional(String.t()) => map() | boolean()}

  # Each source document keeps its own meta-schema. All references point into
  # a closed, per-build cache, so the vendor resolver cannot initiate a fetch.
  @spec bundle(map() | boolean(), documents()) ::
          {:ok, {String.t(), documents()}} | {:error, :network_ref_forbidden}
  def bundle(schema, documents) do
    graph = SchemaGraph.build(schema, documents: documents)
    locations = output_locations(graph)
    {root_location, []} = locations[{:root, [], false}]

    roots = for {document, _schema} <- graph.documents, do: {document, [], false}

    (roots ++ Enum.to_list(graph.additional))
    |> Enum.reduce_while({:ok, %{}}, fn key = {_document, path, _named?}, {:ok, acc} ->
      {location, _output} = locations[key]

      case rewrite(graph, key, locations) do
        {:ok, value} ->
          # The source document's meta-schema never examined literal data.
          # Keep that boundary when resolving a separate schema occurrence.
          value = if path == [], do: value, else: %{"x-arbor-target" => value}
          {:cont, {:ok, Map.put(acc, location, value)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, {root_location, documents}}
      error -> error
    end
  end

  # A referenced node inside instance data gets a separate cache entry. An
  # annotation wrapper preserves the original meta-schema boundary while
  # allowing ExJsonSchema to resolve the copy's references and attributes.
  defp output_locations(graph) do
    roots =
      graph.documents
      |> Enum.sort()
      |> Enum.with_index()
      |> Map.new(fn {{document, _schema}, index} ->
        {{document, [], false}, {"arbor-schema:document-#{index}", []}}
      end)

    graph.additional
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.reduce(roots, fn {key, index}, locations ->
      Map.put(locations, key, {"arbor-schema:target-#{index}", ["x-arbor-target"]})
    end)
  end

  defp rewrite(graph, {document, path, named?} = key, locations) do
    %{value: value} = Map.fetch!(graph.nodes, key)
    rewrite_value(value, graph, document, path, named?, locations)
  end

  defp rewrite_value(map, graph, document, path, named?, locations) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      rewrite_entry(name, value, graph, {document, path, named?}, locations, acc)
    end)
  end

  defp rewrite_value(list, graph, document, path, _named?, locations) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {_value, index}, {:ok, acc} ->
      case rewrite(graph, {document, path ++ [Integer.to_string(index)], false}, locations) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp rewrite_value(value, _graph, _document, _path, _named?, _locations), do: {:ok, value}

  defp rewrite_entry(name, value, graph, {document, path, named?} = key, locations, acc) do
    cond do
      not named? and SchemaGraph.literal_keyword?(name) ->
        {:cont, {:ok, Map.put(acc, name, value)}}

      not named? and name in ["id", "$id"] and is_binary(value) ->
        # Every active ref now points into the sealed cache. Identifiers
        # must not let ExJsonSchema rescope those references.
        {:cont, {:ok, acc}}

      name in @references and SchemaGraph.reference?(graph.nodes[key], name, value) ->
        rewrite_reference(name, value, graph, key, locations, acc)

      true ->
        child = {document, path ++ [name], SchemaGraph.named_child?(named?, name)}

        case rewrite(graph, child, locations) do
          {:ok, rewritten} -> {:cont, {:ok, Map.put(acc, name, rewritten)}}
          error -> {:halt, error}
        end
    end
  end

  defp rewrite_reference(name, value, graph, key, locations, acc) do
    node = Map.fetch!(graph.nodes, key)

    if name == "$ref" and node.role != :schema do
      # ExJsonSchema traverses annotation objects during resolution. Their
      # refs are not constraints; make them inert before that traversal.
      if SchemaGraph.unsupported_scope?(node.scope),
        do: {:halt, {:error, :network_ref_forbidden}},
        else: {:cont, {:ok, Map.put(acc, "$ref", "#")}}
    else
      rewrite_schema_reference(name, value, graph, key, locations, acc)
    end
  end

  defp rewrite_schema_reference(name, value, graph, key, locations, acc) do
    case SchemaGraph.resolve(graph, key, value) do
      {:ok, target} ->
        pointer = target |> output_path(locations) |> encode_pointer()
        {:cont, {:ok, Map.put(acc, name, pointer)}}

      _unresolved ->
        {:halt, {:error, :network_ref_forbidden}}
    end
  end

  defp output_path({document, path, _named?}, locations) do
    {{_document, prefix, _named?}, {location, output}} =
      locations
      |> Enum.filter(fn {{owner, prefix, _named?}, _output} ->
        owner == document and Enum.take(path, length(prefix)) == prefix
      end)
      |> Enum.max_by(fn {{_document, prefix, _named?}, _output} -> length(prefix) end)

    {location, output ++ Enum.drop(path, length(prefix))}
  end

  defp encode_pointer({location, []}), do: location

  defp encode_pointer({location, path}),
    do: location <> "#/" <> Enum.map_join(path, "/", &encode_segment/1)

  # ExJsonSchema percent-decodes after its ~0/~1 passes. Encode a literal
  # tilde as %7E so keys containing ~1 remain distinct from slash keys.
  defp encode_segment(segment) do
    segment
    |> String.replace("%", "%25")
    |> String.replace("~", "%7E")
    |> String.replace("/", "~1")
  end
end
