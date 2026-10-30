defmodule Arbor.MCP.Content.SchemaInliner do
  @moduledoc false

  @literal_keywords MapSet.new(~w(const default enum examples))
  @named_schema_maps MapSet.new(
                       ~w(properties patternProperties $defs definitions dependentSchemas dependencies dependentRequired)
                     )
  @reference_keywords MapSet.new(~w($ref $dynamicRef $recursiveRef))

  @type documents :: %{optional(String.t()) => map() | boolean()}

  @spec inline(map() | boolean(), documents()) ::
          {:ok, map() | boolean()} | {:error, :network_ref_forbidden}
  def inline(schema, documents) when is_boolean(schema) do
    if documents == %{}, do: {:ok, schema}, else: inline(%{}, documents)
  end

  def inline(schema, documents) when is_map(schema) do
    targets = pointer_nodes(schema)
    {keys, anchors} = index(schema, documents, targets)

    with {:ok, rewritten_docs} <- rewrite_documents(documents, keys, anchors),
         {:ok, rewritten_root} <- rewrite_node(schema, nil, keys, anchors, false, targets) do
      sealed = attach_definitions(rewritten_root, rewritten_docs)
      assert_local_only(sealed, targets)
    end
  end

  # The targeted node and every ancestor. A pointer such as `#/const/nested`
  # has to walk `const` itself; matching only the leaf leaves the remote ref
  # inside the skipped literal.
  @doc false
  @spec pointer_nodes(term()) :: MapSet.t()
  def pointer_nodes(root) when is_list(root) or (is_map(root) and not is_struct(root)) do
    root
    |> collect_ref_strings([])
    |> Enum.reduce(MapSet.new(), fn ref, acc ->
      case pointer_chain(root, ref) do
        {:ok, chain} -> Enum.reduce(chain, acc, &MapSet.put(&2, &1))
        :error -> acc
      end
    end)
  end

  def pointer_nodes(_other), do: MapSet.new()

  defp index(schema, documents, targets) do
    {keys, _used, _next_index} =
      documents
      |> Enum.sort_by(fn {uri, _schema} -> uri end)
      |> Enum.reduce({%{}, reserved_definition_keys(schema), 0}, fn {uri, _schema},
                                                                    {keys, used, index} ->
        {key, next_index} = next_remote_key(index, used)
        {Map.put(keys, location(uri), key), MapSet.put(used, key), next_index}
      end)

    anchors =
      Map.new(documents, fn {uri, document} ->
        {location(uri), collect_anchors(document, pointer_nodes(document))}
      end)

    index_local(schema, nil, [], false, keys, anchors, targets)
  end

  defp remote_key(index), do: "__remote_#{index}"

  defp reserved_definition_keys(schema) do
    case Map.get(schema, "definitions") do
      definitions when is_map(definitions) -> MapSet.new(Map.keys(definitions))
      _other -> MapSet.new()
    end
  end

  defp next_remote_key(index, used) do
    key = remote_key(index)

    if MapSet.member?(used, key),
      do: next_remote_key(index + 1, used),
      else: {key, index + 1}
  end

  defp index_local(map, scope, path, named_keys?, keys, anchors, targets)
       when is_map(map) and not is_struct(map) do
    scope = next_scope(map, scope, named_keys?)
    location = document_location(scope)
    keys = put_new_path(keys, location, path)
    anchors = put_local_anchors(anchors, location, map, path, named_keys?, targets)

    Enum.reduce(map, {keys, anchors}, fn {key, value}, {keys, anchors} ->
      index_child(key, value, scope, path, named_keys?, keys, anchors, targets)
    end)
  end

  defp index_local(list, scope, path, _named_keys?, keys, anchors, targets) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce({keys, anchors}, fn {value, index}, {keys, anchors} ->
      index_local(value, scope, path ++ [Integer.to_string(index)], false, keys, anchors, targets)
    end)
  end

  defp index_local(_value, _scope, _path, _named_keys?, keys, anchors, _targets),
    do: {keys, anchors}

  defp index_child(key, value, scope, path, named_keys?, keys, anchors, targets) do
    if skip_untargeted_literal?(named_keys?, key, value, targets) do
      {keys, anchors}
    else
      index_local(
        value,
        scope,
        path ++ [key],
        named_child?(named_keys?, key),
        keys,
        anchors,
        targets
      )
    end
  end

  defp put_new_path(keys, nil, _path), do: keys
  defp put_new_path(keys, location, path), do: Map.put_new(keys, location, {:path, path})

  defp put_local_anchors(anchors, _location, _map, _path, true, _targets), do: anchors
  defp put_local_anchors(anchors, nil, _map, _path, _named_keys?, _targets), do: anchors

  defp put_local_anchors(anchors, location, map, path, _named_keys?, targets) do
    relative = collect_anchors(map, targets)
    prefixed = Map.new(relative, fn {anchor, rel} -> {anchor, path ++ rel} end)
    Map.update(anchors, location, prefixed, &Map.merge(&1, prefixed))
  end

  defp collect_anchors(schema, _targets) when is_boolean(schema), do: %{}

  defp collect_anchors(schema, targets) when is_map(schema) do
    collect_anchor_nodes(schema, [], false, %{}, targets)
  end

  defp collect_anchors(_schema, _targets), do: %{}

  defp collect_anchor_nodes(map, path, named_keys?, acc, targets)
       when is_map(map) and not is_struct(map) do
    acc = if named_keys?, do: acc, else: put_node_anchors(acc, map, path)

    Enum.reduce(map, acc, fn {key, value}, acc ->
      if skip_untargeted_literal?(named_keys?, key, value, targets) do
        acc
      else
        collect_anchor_nodes(
          value,
          path ++ [key],
          named_child?(named_keys?, key),
          acc,
          targets
        )
      end
    end)
  end

  defp collect_anchor_nodes(list, path, _named_keys?, acc, targets) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, acc ->
      collect_anchor_nodes(value, path ++ [Integer.to_string(index)], false, acc, targets)
    end)
  end

  defp collect_anchor_nodes(_value, _path, _named_keys?, acc, _targets), do: acc

  defp put_node_anchors(acc, map, path) do
    acc
    |> put_anchor(map["$anchor"], path)
    |> put_id_fragment(map["$id"], path)
    |> put_id_fragment(map["id"], path)
  end

  defp put_anchor(acc, anchor, path) when is_binary(anchor) and anchor != "",
    do: Map.put(acc, anchor, path)

  defp put_anchor(acc, _anchor, _path), do: acc

  defp put_id_fragment(acc, id, path) when is_binary(id) do
    case URI.parse(id) do
      %URI{fragment: fragment} when is_binary(fragment) and fragment != "" ->
        if String.starts_with?(fragment, "/"), do: acc, else: Map.put(acc, fragment, path)

      _other ->
        acc
    end
  end

  defp put_id_fragment(acc, _id, _path), do: acc

  defp rewrite_documents(documents, keys, anchors) do
    Enum.reduce_while(documents, {:ok, %{}}, fn {uri, schema}, {:ok, acc} ->
      key = Map.fetch!(keys, location(uri))
      targets = pointer_nodes(schema)

      with {:ok, rewritten} <- rewrite_node(schema, uri, keys, anchors, false, targets),
           {:ok, _} <- assert_local_only(rewritten, targets) do
        {:cont, {:ok, Map.put(acc, key, rewritten)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp rewrite_node(map, scope, keys, anchors, named_keys?, targets)
       when is_map(map) and not is_struct(map) do
    scope = next_scope(map, scope, named_keys?)

    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      rewrite_entry(key, value, scope, keys, anchors, named_keys?, acc, targets)
    end)
  end

  defp rewrite_node(list, scope, keys, anchors, _named_keys?, targets) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case rewrite_node(value, scope, keys, anchors, false, targets) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp rewrite_node(value, _scope, _keys, _anchors, _named_keys?, _targets), do: {:ok, value}

  defp rewrite_entry(key, value, scope, keys, anchors, named_keys?, acc, targets) do
    cond do
      skip_untargeted_literal?(named_keys?, key, value, targets) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      identifier?(key, value) ->
        {:cont, {:ok, put_local_identifier(acc, key, value)}}

      MapSet.member?(@reference_keywords, key) and is_binary(value) ->
        case localize_ref(value, scope, keys, anchors) do
          {:ok, localized} -> {:cont, {:ok, Map.put(acc, key, localized)}}
          {:error, _reason} = error -> {:halt, error}
        end

      true ->
        case rewrite_node(value, scope, keys, anchors, named_child?(named_keys?, key), targets) do
          {:ok, rewritten} -> {:cont, {:ok, Map.put(acc, key, rewritten)}}
          {:error, _reason} = error -> {:halt, error}
        end
    end
  end

  defp put_local_identifier(acc, key, value) do
    if absolute_http?(value), do: acc, else: Map.put(acc, key, value)
  end

  defp localize_ref(ref, scope, keys, anchors) do
    resolved = merge_ref(scope, ref)

    if local_fragment?(resolved) do
      {:ok, resolved}
    else
      localize_absolute(resolved, keys, anchors)
    end
  end

  defp localize_absolute(ref, keys, anchors) do
    uri = URI.parse(ref)
    location = location(uri)

    case Map.fetch(keys, location) do
      {:ok, target} ->
        pointer_for(target, uri.fragment, Map.get(anchors, location, %{}))

      :error ->
        {:error, :network_ref_forbidden}
    end
  end

  defp pointer_for(target, fragment, anchors) do
    case pointer_segments(target, fragment, anchors) do
      {:ok, segments} -> {:ok, encode_pointer(segments)}
      {:error, _reason} = error -> error
    end
  end

  defp pointer_segments({:path, path}, fragment, anchors),
    do: append_fragment(path, fragment, anchors)

  defp pointer_segments(key, fragment, anchors) when is_binary(key),
    do: append_fragment(["definitions", key], fragment, anchors)

  defp append_fragment(base, fragment, _anchors) when fragment in [nil, ""], do: {:ok, base}

  defp append_fragment(base, "/" <> rest, _anchors) do
    {:ok, base ++ Enum.map(String.split(rest, "/"), &decode_pointer_segment/1)}
  end

  defp append_fragment(base, anchor, anchors) do
    case Map.fetch(anchors, anchor) do
      {:ok, relative} -> {:ok, base ++ relative}
      :error -> {:error, :network_ref_forbidden}
    end
  end

  defp encode_pointer([]), do: "#"

  defp encode_pointer(segments) do
    "#/" <> Enum.map_join(segments, "/", &encode_pointer_segment/1)
  end

  # ExJsonSchema replaces `~0` before `~1` and percent-decodes last, so a
  # `~0` escape for a literal tilde is read as a slash. `%7E` survives those
  # two passes and becomes `~` in the final decode.
  defp encode_pointer_segment(segment) do
    segment
    |> String.replace("%", "%25")
    |> String.replace("~", "%7E")
    |> String.replace("/", "~1")
  end

  defp decode_pointer_segment(segment) do
    segment
    |> URI.decode()
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp attach_definitions(root, documents) when documents == %{}, do: root

  defp attach_definitions(root, documents) do
    existing = Map.get(root, "definitions", %{})
    Map.put(root, "definitions", Map.merge(existing, documents))
  end

  defp assert_local_only(schema, targets), do: assert_local_node(schema, false, targets)

  defp assert_local_node(map, named_keys?, targets) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, map}, fn {key, value}, {:ok, _acc} ->
      cond do
        skip_untargeted_literal?(named_keys?, key, value, targets) ->
          {:cont, {:ok, map}}

        identifier?(key, value) and absolute_http?(value) ->
          {:halt, {:error, :network_ref_forbidden}}

        MapSet.member?(@reference_keywords, key) and is_binary(value) and
            not local_fragment?(value) ->
          {:halt, {:error, :network_ref_forbidden}}

        true ->
          case assert_local_node(value, named_child?(named_keys?, key), targets) do
            {:ok, _} -> {:cont, {:ok, map}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  defp assert_local_node(list, _named_keys?, targets) when is_list(list) do
    Enum.reduce_while(list, {:ok, list}, fn value, {:ok, _acc} ->
      case assert_local_node(value, false, targets) do
        {:ok, _} -> {:cont, {:ok, list}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp assert_local_node(value, _named_keys?, _targets), do: {:ok, value}

  defp next_scope(_map, scope, true), do: scope

  defp next_scope(map, scope, false) do
    case Map.get(map, "$id") || Map.get(map, "id") do
      id when is_binary(id) -> merge_ref(scope, id)
      _other -> scope
    end
  end

  defp merge_ref(nil, ref), do: ref

  defp merge_ref(scope, ref) do
    case URI.parse(to_string(scope)) do
      %URI{host: nil} ->
        ref

      scope_uri ->
        scope_uri |> URI.merge(ref) |> to_string()
    end
  rescue
    _exception -> ref
  end

  defp document_location(nil), do: nil

  defp document_location(scope) do
    uri = URI.parse(to_string(scope))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      location(uri)
    else
      nil
    end
  end

  defp location(%URI{} = uri), do: uri |> Map.put(:fragment, nil) |> to_string()
  defp location(uri) when is_binary(uri), do: uri |> URI.parse() |> location()

  defp local_fragment?("#" <> _fragment), do: true
  defp local_fragment?(""), do: true
  defp local_fragment?(_ref), do: false

  defp absolute_http?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _other ->
        false
    end
  end

  defp absolute_http?(_value), do: false

  defp identifier?(key, value) when key in ["$id", "id"], do: is_binary(value)
  defp identifier?(_key, _value), do: false

  defp named_child?(false, key), do: MapSet.member?(@named_schema_maps, key)
  defp named_child?(true, _key), do: false

  defp skip_untargeted_literal?(false, key, value, targets) do
    MapSet.member?(@literal_keywords, key) and not MapSet.member?(targets, value)
  end

  defp skip_untargeted_literal?(true, _key, _value, _targets), do: false

  defp collect_ref_strings(map, acc) when is_map(map) and not is_struct(map) do
    acc =
      Enum.reduce(@reference_keywords, acc, fn key, acc ->
        case Map.get(map, key) do
          ref when is_binary(ref) -> [ref | acc]
          _other -> acc
        end
      end)

    Enum.reduce(map, acc, fn {_key, value}, acc -> collect_ref_strings(value, acc) end)
  end

  defp collect_ref_strings(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn value, acc -> collect_ref_strings(value, acc) end)
  end

  defp collect_ref_strings(_value, acc), do: acc

  defp pointer_chain(root, "#"), do: {:ok, [root]}

  defp pointer_chain(root, "#" <> fragment) do
    if String.starts_with?(fragment, "/") do
      follow_chain(root, fragment)
    else
      :error
    end
  end

  defp pointer_chain(root, ref) when is_binary(ref) do
    case URI.parse(ref) do
      %URI{scheme: nil, host: nil, path: path, fragment: fragment}
      when path in [nil, ""] and is_binary(fragment) ->
        pointer_chain(root, "#" <> fragment)

      _other ->
        :error
    end
  end

  defp pointer_chain(_root, _ref), do: :error

  defp follow_chain(node, pointer) do
    pointer
    |> String.split("/")
    |> tl()
    |> Enum.map(&decode_pointer_segment/1)
    |> Enum.reduce_while({:ok, [node]}, fn segment, {:ok, [current | _] = chain} ->
      case pointer_child(current, segment) do
        {:ok, child} -> {:cont, {:ok, [child | chain]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp pointer_child(map, key) when is_map(map) and not is_struct(map), do: Map.fetch(map, key)

  defp pointer_child(list, key) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 -> Enum.fetch(list, index)
      _other -> :error
    end
  end

  defp pointer_child(_node, _key), do: :error

  defp reverse_ok({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_ok(error), do: error
end
