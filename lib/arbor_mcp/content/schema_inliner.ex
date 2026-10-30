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
    {locations, definitions} = output_locations(graph)
    {root_location, []} = locations[{:root, [], false}]

    graph.documents
    |> Enum.reduce_while({:ok, %{}}, fn {document, _schema}, {:ok, acc} ->
      key = {document, [], false}
      {location, []} = locations[key]

      with {:ok, root} <- rewrite(graph, key, locations),
           {:ok, copies} <- rewrite_definitions(graph, definitions[document], locations) do
        {:cont, {:ok, Map.put(acc, location, attach_definitions(root, copies))}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, {root_location, documents}}
      error -> error
    end
  end

  # A referenced node inside instance data gets a separate schema copy in
  # the same document. Its original occurrence retains its instance value.
  defp output_locations(graph) do
    graph.documents
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.reduce({%{}, %{}}, fn {{document, schema}, index}, {locations, copies} ->
      location = "arbor-schema:document-#{index}"
      locations = Map.put(locations, {document, [], false}, {location, []})
      names = if is_map(schema), do: Map.keys(Map.get(schema, "definitions", %{})), else: []
      initial = {locations, %{}, MapSet.new(names), 0}

      {locations, definitions, _used, _index} =
        graph.additional
        |> Enum.filter(fn {owner, _path, _named?} -> owner == document end)
        |> Enum.sort()
        |> Enum.reduce(initial, fn key, {locations, definitions, used, index} ->
          {name, index} = next_key(index, used)
          output = {location, ["definitions", name]}

          {Map.put(locations, key, output), Map.put(definitions, name, key),
           MapSet.put(used, name), index}
        end)

      {locations, Map.put(copies, document, definitions)}
    end)
  end

  defp next_key(index, used) do
    name = "__remote_#{index}"
    if MapSet.member?(used, name), do: next_key(index + 1, used), else: {name, index + 1}
  end

  defp rewrite_definitions(graph, definitions, locations) do
    Enum.reduce_while(definitions, {:ok, %{}}, fn {name, key}, {:ok, acc} ->
      case rewrite(graph, key, locations) do
        {:ok, schema} -> {:cont, {:ok, Map.put(acc, name, schema)}}
        error -> {:halt, error}
      end
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

  defp attach_definitions(root, definitions) when definitions == %{}, do: root

  defp attach_definitions(root, definitions) do
    Map.update(root, "definitions", definitions, &Map.merge(&1, definitions))
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
