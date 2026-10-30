defmodule Arbor.MCP.Content.SchemaGraph do
  @moduledoc false

  @literal_keywords ~w(const default enum examples)
  @named_maps ~w(properties patternProperties $defs definitions dependentSchemas dependencies dependentRequired)
  @schema_keywords ~w(additionalProperties additionalItems items prefixItems contains unevaluatedItems unevaluatedProperties propertyNames if then else not allOf anyOf oneOf contentSchema)
  @references ~w($ref $dynamicRef $recursiveRef)
  @composition ~w(allOf anyOf oneOf not if then else)

  # Paths identify occurrences, not values. Two equal maps may be a schema
  # and instance data, respectively, and must never acquire each other's role.
  def build(schema, opts \\ []) do
    documents = Map.put(Keyword.get(opts, :documents, %{}), :root, schema)

    graph = %{
      documents: documents,
      nodes: %{},
      resources: %{},
      anchors: %{},
      additional: MapSet.new()
    }

    documents
    |> Enum.sort_by(fn {document, _} -> document end)
    |> Enum.reduce(graph, fn {document, value}, graph ->
      base = if document == :root, do: Keyword.get(opts, :base_uri), else: document
      resource = {document, []}

      graph
      |> put_resource(base, resource)
      |> visit({document, [], false}, value, base, resource)
    end)
    |> expand_targets()
  end

  def references(graph) do
    for {key, %{value: value} = node} <- graph.nodes,
        is_map(value),
        name <- @references,
        reference?(node, name, value[name]),
        do: {key, value[name]}
  end

  def reference?(%{role: role, named?: named?}, name, value) do
    is_binary(value) and
      (name == "$ref" or (name in @references and role == :schema and not named?))
  end

  def external_references(graph) do
    for {key, ref} <- references(graph),
        {:external, uri} <- [resolve(graph, key, ref)],
        do: uri
  end

  def additional_schemas(graph) do
    for key = {_document, path, _named?} <- graph.additional,
        do: {graph.nodes[key].value, length(path)}
  end

  def check_limits(graph, opts) do
    graph.nodes
    |> Enum.group_by(fn {{document, _path, _named?}, _node} -> document end)
    |> Enum.reduce_while(:ok, fn {_document, nodes}, :ok ->
      nodes = Enum.uniq_by(nodes, fn {{_document, path, _named?}, _node} -> path end)
      maps = Enum.count(nodes, fn {_key, node} -> is_map(node.value) end)

      depth =
        Enum.reduce(nodes, 0, fn {{_document, path, _named?}, node}, max_depth ->
          if is_map(node.value) or is_list(node.value),
            do: max(max_depth, length(path)),
            else: max_depth
        end)

      composition =
        Enum.reduce(nodes, 0, fn {{document, path, _named?}, _node}, max_depth ->
          value =
            path
            |> Enum.with_index()
            |> Enum.count(fn {name, index} ->
              name in @composition and
                Map.has_key?(graph.nodes, {document, Enum.take(path, index), false})
            end)

          max(value, max_depth)
        end)

      limits = [max_subschemas: maps, max_schema_depth: depth, max_composition_depth: composition]

      case Enum.find(limits, fn {key, value} -> value > opts[key] end) do
        {key, _value} -> {:halt, {:error, {:schema_limit_exceeded, key, opts[key] + 1}}}
        nil -> {:cont, :ok}
      end
    end)
  end

  def literal_keyword?(key), do: key in @literal_keywords
  def named_child?(false, key), do: key in @named_maps
  def named_child?(true, _key), do: false

  def resolve(graph, key, reference) do
    node = Map.fetch!(graph.nodes, key)

    if unsupported_scope?(node.scope) do
      :missing
    else
      resolve_reference(graph, node, reference)
    end
  end

  defp resolve_reference(graph, node, "#" <> fragment),
    do: target(graph, node.resource, fragment)

  defp resolve_reference(graph, node, ""), do: target(graph, node.resource, nil)

  defp resolve_reference(graph, node, reference) do
    uri = resolve_uri(node.scope, reference)

    case Map.fetch(graph.resources, location(uri)) do
      {:ok, resource} -> target(graph, resource, URI.parse(uri).fragment)
      :error -> {:external, uri}
    end
  end

  defp target(graph, {document, path}, fragment) when fragment in [nil, ""],
    do: existing_target(graph, document, path)

  defp target(graph, {document, path}, "/" <> rest) do
    segments = Enum.map(String.split(rest, "/"), &decode_segment/1)
    existing_target(graph, document, path ++ segments)
  end

  defp target(graph, resource, anchor),
    do: Map.get(graph.anchors, {resource, URI.decode(anchor)}, :missing)

  defp existing_target(graph, document, path) do
    case fetch(graph, document, path) do
      {:ok, _value} -> {:ok, {document, path, false}}
      :error -> :missing
    end
  end

  def fetch(graph, document, path) do
    Enum.reduce_while(path, {:ok, Map.fetch!(graph.documents, document)}, fn
      key, {:ok, map} when is_map(map) ->
        continue_fetch(Map.fetch(map, key))

      key, {:ok, list} when is_list(list) ->
        case Integer.parse(key) do
          {index, ""} when index >= 0 -> continue_fetch(Enum.fetch(list, index))
          _invalid -> {:halt, :error}
        end

      _key, _value ->
        {:halt, :error}
    end)
  end

  defp continue_fetch({:ok, _} = result), do: {:cont, result}
  defp continue_fetch(:error), do: {:halt, :error}

  defp expand_targets(graph) do
    expanded =
      Enum.reduce(references(graph), graph, fn {source, ref}, graph ->
        case resolve(graph, source, ref) do
          {:ok, key} ->
            if graph.nodes[source].role == :schema and not graph.nodes[source].named?,
              do: add_target(graph, key),
              else: graph

          _unresolved ->
            graph
        end
      end)

    if expanded == graph,
      do: expanded,
      else: expand_targets(expanded)
  end

  defp add_target(graph, {document, path, _named?} = key) do
    if Map.has_key?(graph.nodes, key) do
      node = graph.nodes[key]
      parent = ancestor(graph, document, path)
      visit(graph, key, node.value, parent.scope, parent.resource)
    else
      parent = ancestor(graph, document, path)
      {:ok, value} = fetch(graph, document, path)

      graph
      |> Map.update!(:additional, &MapSet.put(&1, key))
      |> visit(key, value, parent.scope, parent.resource)
    end
  end

  defp ancestor(graph, document, path) do
    length(path)..0//-1
    |> Enum.find_value(fn depth ->
      prefix = Enum.take(path, depth)

      Enum.find_value([false, true], fn named? ->
        case graph.nodes[{document, prefix, named?}] do
          %{role: role} = node when role in [:schema, :named] -> node
          _annotation -> nil
        end
      end)
    end)
  end

  defp visit(
         graph,
         {document, path, named?} = key,
         value,
         inherited_scope,
         inherited_resource,
         role \\ :schema
       ) do
    case Map.get(graph.nodes, key) do
      %{role: :annotation} when role in [:schema, :named] ->
        {scope, resource} = scope(value, named?, key, inherited_scope, inherited_resource)
        node = %{value: value, scope: scope, resource: resource, named?: named?, role: role}

        graph
        |> put_in([:nodes, key], node)
        |> index_identity(value, named?, key, scope, resource, role)
        |> visit_children(value, document, path, named?, scope, resource, role)

      %{} ->
        graph

      nil ->
        {scope, resource} = scope(value, named?, key, inherited_scope, inherited_resource)
        node = %{value: value, scope: scope, resource: resource, named?: named?, role: role}
        graph = put_in(graph.nodes[key], node)

        graph
        |> index_identity(value, named?, key, scope, resource, role)
        |> visit_children(value, document, path, named?, scope, resource, role)
    end
  end

  defp visit_children(graph, map, document, path, named?, scope, resource, role)
       when is_map(map) do
    Enum.reduce(map, graph, fn {name, child}, graph ->
      if not named? and literal_keyword?(name) do
        graph
      else
        key = {document, path ++ [name], named_child?(named?, name)}
        visit(graph, key, child, scope, resource, child_role(role, name))
      end
    end)
  end

  defp visit_children(graph, list, document, path, _named?, scope, resource, role)
       when is_list(list) do
    child_role = if role == :annotation, do: :annotation, else: :schema

    list
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {child, index}, graph ->
      visit(
        graph,
        {document, path ++ [Integer.to_string(index)], false},
        child,
        scope,
        resource,
        child_role
      )
    end)
  end

  defp visit_children(graph, _value, _document, _path, _named?, _scope, _resource, _role),
    do: graph

  defp child_role(:named, _name), do: :schema
  defp child_role(:schema, name) when name in @named_maps, do: :named
  defp child_role(:schema, name) when name in @schema_keywords, do: :schema
  defp child_role(_role, _name), do: :annotation

  defp scope(map, false, {document, path, _}, inherited, resource) when is_map(map) do
    case map["$id"] || map["id"] do
      id when is_binary(id) ->
        scope = resolve_uri(inherited, id)

        resource =
          if not fragment_identifier?(id) and location(scope) != location(inherited),
            do: {document, path},
            else: resource

        {scope, resource}

      _other ->
        {inherited, resource}
    end
  end

  defp scope(_value, _named?, _key, inherited, resource), do: {inherited, resource}

  defp fragment_identifier?(id) do
    uri = URI.parse(id)
    is_nil(uri.scheme) and is_nil(uri.host) and uri.path in [nil, ""]
  end

  defp index_identity(graph, map, false, key, scope, resource, :schema) when is_map(map) do
    graph =
      if is_binary(map["$id"] || map["id"]), do: put_resource(graph, scope, resource), else: graph

    graph
    |> put_anchor(resource, map["$anchor"], key)
    |> put_id_anchor(resource, map["$id"] || map["id"], key)
  end

  defp index_identity(graph, _value, _named?, _key, _scope, _resource, _role), do: graph

  defp put_resource(graph, nil, _resource), do: graph

  defp put_resource(graph, uri, resource) do
    case location(uri) do
      "" -> graph
      location -> %{graph | resources: Map.put_new(graph.resources, location, resource)}
    end
  end

  defp put_anchor(graph, resource, anchor, key) when is_binary(anchor) and anchor != "",
    do: %{graph | anchors: Map.put(graph.anchors, {resource, URI.decode(anchor)}, {:ok, key})}

  defp put_anchor(graph, _resource, _anchor, _key), do: graph

  defp put_id_anchor(graph, resource, id, key) when is_binary(id) do
    case URI.parse(id).fragment do
      "/" <> _pointer -> graph
      fragment -> put_anchor(graph, resource, fragment, key)
    end
  end

  defp put_id_anchor(graph, _resource, _id, _key), do: graph

  def resolve_uri(nil, reference), do: reference

  def resolve_uri(base, reference) do
    uri = URI.parse(to_string(base))

    if is_nil(uri.scheme) and is_nil(uri.host) do
      # URI.merge requires an absolute base. A temporary scheme lets local
      # relative identifiers compose without inventing a network origin.
      rooted? = String.starts_with?(uri.path || "", "/")

      absolute = %{
        uri
        | scheme: "arbor-schema",
          path: "/" <> String.trim_leading(uri.path || "", "/")
      }

      merged = URI.merge(absolute, reference)

      if merged.scheme == "arbor-schema" do
        rooted? = rooted? or String.starts_with?(URI.parse(reference).path || "", "/")
        path = if rooted?, do: merged.path, else: String.trim_leading(merged.path || "", "/")
        to_string(%{merged | scheme: nil, path: path})
      else
        to_string(merged)
      end
    else
      uri |> URI.merge(reference) |> to_string()
    end
  rescue
    _invalid -> reference
  end

  def location(nil), do: nil

  def location(uri) do
    uri = URI.parse(to_string(uri))

    host =
      if is_binary(uri.host),
        do: uri.host |> String.downcase() |> String.trim_trailing("."),
        else: nil

    scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme), else: nil
    path = if scheme in ["http", "https"] and uri.path in [nil, ""], do: "/", else: uri.path
    uri |> Map.merge(%{fragment: nil, scheme: scheme, host: host, path: path}) |> to_string()
  end

  def unsupported_scope?(nil), do: false

  def unsupported_scope?(scope) do
    uri = URI.parse(scope)
    is_binary(uri.host) and uri.scheme not in [nil, "http", "https"]
  end

  defp decode_segment(segment) do
    segment |> URI.decode() |> String.replace("~1", "/") |> String.replace("~0", "~")
  end
end
