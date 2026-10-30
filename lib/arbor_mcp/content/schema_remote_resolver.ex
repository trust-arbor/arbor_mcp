defmodule Arbor.MCP.Content.SchemaRemoteResolver do
  @moduledoc false

  alias Arbor.MCP.Content.{SchemaGraph, SchemaInliner}
  alias Arbor.MCP.Internal.NetworkPolicy
  alias ExJsonSchema.Schema.Root

  require Logger

  @redirect_statuses [301, 302, 303, 307, 308]

  @type network_error :: {:network_schema_error, atom()}

  # Policy preflight is injected by `Arbor.MCP.Content.SchemaPolicy` (the only
  # caller) so this resolver never depends back on the policy module that
  # selects it. It is applied to the root schema and to every fetched document.
  @type preflight :: (map() | boolean(), keyword() -> :ok | {:error, term()})

  @spec resolve(map() | boolean(), keyword(), preflight()) ::
          {:ok, ExJsonSchema.Schema.Root.t()} | {:error, term()}
  def resolve(schema, policy_opts, preflight) when is_function(preflight, 2) do
    fetched =
      if policy_opts[:network_refs][:enabled] == true,
        do: fetch_documents(schema, policy_opts, preflight),
        else: local_documents(schema, policy_opts, preflight)

    with {:ok, {schema, documents}} <- fetched,
         {:ok, {root_location, sealed}} <- SchemaInliner.bundle(schema, documents) do
      resolve_sealed(root_location, sealed)
    end
  end

  @doc false
  @spec fetch_documents(map() | boolean(), keyword(), preflight()) ::
          {:ok, {map() | boolean(), map()}} | {:error, term()}
  def fetch_documents(schema, policy_opts, preflight) do
    state = %{root: schema, documents: %{}, owners: %{}, aggregate_bytes: 0, document_count: 0}
    network_opts = policy_opts[:network_refs]

    with :ok <- preflight.(schema, policy_opts),
         {:ok, state} <- fetch_pending(state, policy_opts, preflight) do
      Logger.info(
        "Resolved remote JSON Schema documents count=#{state.document_count} " <>
          "bytes=#{state.aggregate_bytes} " <>
          "trust_partition_sha256=#{hash_term(network_opts[:trust_partition])}"
      )

      {:ok, {schema, state.documents}}
    else
      {:error, {:network_schema_error, reason}} = error ->
        Logger.warning(
          "Rejected remote JSON Schema request reason=#{reason} " <>
            "trust_partition_sha256=#{hash_term(network_opts[:trust_partition])}"
        )

        error

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec public_address?(:inet.ip_address()) :: boolean()
  defdelegate public_address?(address), to: NetworkPolicy

  # Discovery must retain the root's selection of nodes inside fetched literal
  # data. Rebuild the combined graph after each fetch so aliases, targets and
  # their dependencies are known before deciding whether another fetch is needed.
  defp fetch_pending(state, policy_opts, preflight) do
    graph = SchemaGraph.build(state.root, documents: state.documents)
    network_opts = policy_opts[:network_refs]

    with :ok <- SchemaGraph.check_limits(graph, policy_opts),
         :ok <- reject_fetched_dynamic_keywords(graph),
         :ok <- check_reference_graph(graph, state, network_opts) do
      case SchemaGraph.external_references(graph) |> Enum.uniq() do
        [] ->
          {:ok, state}

        references ->
          reference = Enum.min_by(references, &fetch_priority(&1, network_opts))

          with {:ok, document} <- reference_document(reference, nil),
               {:ok, state} <- fetch_document(document, state, policy_opts, preflight) do
            fetch_pending(state, policy_opts, preflight)
          end
      end
    end
  end

  defp fetch_priority(reference, opts) do
    uri = URI.parse(reference)

    permitted? =
      uri.scheme in allowed_schemes(opts) and is_binary(uri.host) and
        allowed_host?(uri.host, opts[:allowed_hosts])

    {not permitted?, reference}
  end

  defp fetch_document(reference, state, policy_opts, preflight) do
    network_opts = policy_opts[:network_refs]

    with {:ok, uri} <- parse_fetch_uri(reference),
         :ok <- check_document_count(state, network_opts),
         {:ok, response} <- fetch_with_redirects(uri, network_opts, 0, [], 0),
         {:ok, next_bytes} <-
           add_aggregate_bytes(state.aggregate_bytes, response.bytes, network_opts),
         {:ok, decoded} <- decode_schema(response.body),
         schema = ensure_retrieval_id(decoded, response.final_uri),
         :ok <- preflight.(schema, policy_opts) do
      owner = canonical_uri(response.final_uri)
      requested = document_uri(uri)
      final = document_uri(response.final_uri)

      {:ok,
       state
       |> Map.put(:aggregate_bytes, next_bytes)
       |> Map.update!(:document_count, &(&1 + 1))
       |> put_document(requested, schema)
       |> put_document(final, schema)
       |> Map.update!(
         :owners,
         &(&1
           |> Map.put(SchemaGraph.location(requested), owner)
           |> Map.put(SchemaGraph.location(final), owner))
       )}
    end
  end

  defp check_reference_graph(graph, state, opts) do
    edges =
      Enum.reduce(SchemaGraph.references(graph), %{}, fn {source, ref}, edges ->
        owner = document_owner(elem(source, 0), state)

        target =
          case SchemaGraph.resolve(graph, source, ref) do
            {:ok, target} -> document_owner(elem(target, 0), state)
            {:external, uri} -> {:pending, SchemaGraph.location(uri)}
            :missing -> owner
          end

        if owner == target,
          do: edges,
          else: Map.update(edges, owner, MapSet.new([target]), &MapSet.put(&1, target))
      end)

    with {:ok, length, _memo} <- reference_length(:root, edges, %{}, %{}),
         do: check_reference_depth(max(length - 1, 0), opts)
  end

  defp document_owner(:root, _state), do: :root

  defp document_owner(document, state),
    do: Map.fetch!(state.owners, SchemaGraph.location(document))

  defp reference_length(vertex, edges, stack, memo) do
    cond do
      Map.has_key?(stack, vertex) ->
        network_error(:reference_cycle)

      Map.has_key?(memo, vertex) ->
        {:ok, memo[vertex], memo}

      true ->
        stack = Map.put(stack, vertex, true)

        Enum.reduce_while(Map.get(edges, vertex, MapSet.new()), {:ok, 0, memo}, fn child,
                                                                                   {:ok, length,
                                                                                    memo} ->
          case reference_length(child, edges, stack, memo) do
            {:ok, child_length, memo} -> {:cont, {:ok, max(length, child_length + 1), memo}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, length, memo} -> {:ok, length, Map.put(memo, vertex, length)}
          error -> error
        end
    end
  end

  defp fetch_with_redirects(uri, opts, redirect_count, visited, bytes) do
    canonical = canonical_uri(uri)

    with :ok <- check_redirect_count(redirect_count, opts),
         :ok <- check_redirect_cycle(canonical, visited),
         {:ok, address} <- validate_target(uri, opts),
         :ok <- log_fetch(uri),
         {:ok, response} <- fetch(uri, address, opts),
         :ok <- validate_response(response, opts) do
      next_bytes = bytes + byte_size(response.body)

      cond do
        response.status == 200 ->
          {:ok, %{body: response.body, final_uri: uri, bytes: next_bytes}}

        response.status in @redirect_statuses ->
          with {:ok, redirected_uri} <- redirect_uri(uri, response.headers) do
            fetch_with_redirects(
              redirected_uri,
              opts,
              redirect_count + 1,
              [canonical | visited],
              next_bytes
            )
          end

        true ->
          network_error(:unexpected_status)
      end
    end
  end

  defp validate_target(%URI{} = uri, opts) do
    with :ok <- validate_uri(uri, opts),
         {:ok, addresses} <- resolve_addresses(uri.host, opts),
         :ok <- validate_addresses(addresses) do
      {:ok, addresses |> Enum.sort() |> hd()}
    end
  end

  defp validate_uri(%URI{scheme: scheme, host: host, userinfo: userinfo, port: port}, opts) do
    cond do
      scheme not in allowed_schemes(opts) -> network_error(:scheme_not_allowed)
      not is_nil(userinfo) -> network_error(:userinfo_forbidden)
      not is_binary(host) or not valid_host?(host) -> network_error(:invalid_uri)
      port && port not in 1..65_535 -> network_error(:invalid_uri)
      not allowed_host?(host, opts[:allowed_hosts]) -> network_error(:host_not_allowed)
      opts[:proxy] != :disabled -> network_error(:proxy_forbidden)
      true -> :ok
    end
  end

  defp resolve_addresses(host, opts) do
    resolver = opts[:dns_resolver]

    result =
      cond do
        is_function(resolver, 2) -> resolver.(host, opts[:dns_timeout_ms])
        is_atom(resolver) -> resolver.resolve(host, opts[:dns_timeout_ms])
        true -> {:error, :dns_failed}
      end

    case result do
      {:ok, addresses} when is_list(addresses) and addresses != [] -> {:ok, Enum.uniq(addresses)}
      {:error, :dns_timeout} -> network_error(:dns_timeout)
      _other -> network_error(:dns_failed)
    end
  rescue
    _exception -> network_error(:dns_failed)
  end

  defp validate_addresses(addresses) do
    if Enum.all?(addresses, &public_address?/1),
      do: :ok,
      else: network_error(:non_public_address)
  end

  defp fetch(uri, address, opts) do
    client = opts[:http_client]

    result =
      cond do
        is_function(client, 3) -> client.(uri, address, opts)
        is_atom(client) -> client.get(uri, address, opts)
        true -> {:error, :fetch_failed}
      end

    case result do
      {:ok, %{status: status, headers: headers, body: body}}
      when is_integer(status) and is_list(headers) and is_binary(body) ->
        {:ok, %{status: status, headers: normalize_headers(headers), body: body}}

      {:error, :response_too_large} ->
        network_error(:response_too_large)

      _other ->
        network_error(:fetch_failed)
    end
  rescue
    _exception -> network_error(:fetch_failed)
  end

  defp validate_response(response, opts) do
    body_size = byte_size(response.body)

    cond do
      compressed?(response.headers) -> network_error(:compressed_response)
      body_size > opts[:max_response_bytes] -> network_error(:response_too_large)
      body_size > opts[:max_decompressed_bytes] -> network_error(:decompressed_response_too_large)
      true -> :ok
    end
  end

  defp redirect_uri(base, headers) do
    case header_values(headers, "location") do
      [location] ->
        merge_redirect(base, location)

      [] ->
        network_error(:missing_redirect_location)

      _multiple ->
        network_error(:invalid_redirect)
    end
  end

  defp merge_redirect(base, location) do
    redirected = URI.merge(base, location)

    if base.scheme == "https" and redirected.scheme == "http",
      do: network_error(:redirect_downgrade),
      else: {:ok, redirected}
  rescue
    _exception -> network_error(:invalid_redirect)
  end

  defp referenced_documents(schema, base_uri) do
    schema
    |> SchemaGraph.build(base_uri: base_uri)
    |> SchemaGraph.external_references()
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, acc} ->
      case reference_document(reference, nil) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, document} -> {:cont, {:ok, [document | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, references} -> {:ok, references |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp reference_document(reference, _base_uri)
       when reference in ["", nil] or not is_binary(reference),
       do: {:ok, nil}

  defp reference_document("#" <> _fragment, _base_uri), do: {:ok, nil}

  defp reference_document(reference, base_uri) do
    with {:ok, uri} <- merge_uri(base_uri, reference),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) do
      {:ok, document_uri(uri)}
    else
      false -> network_error(:relative_reference_without_base)
      {:error, _reason} = error -> error
    end
  end

  defp merge_uri(nil, value) do
    uri = URI.parse(value)

    if uri.scheme,
      do: {:ok, uri},
      else: network_error(:relative_reference_without_base)
  end

  defp ensure_retrieval_id(schema, %URI{} = retrieval_uri) when is_map(schema) do
    retrieval = document_uri(retrieval_uri)

    cond do
      is_binary(schema["$id"]) ->
        Map.put(schema, "$id", absolute_id(retrieval_uri, schema["$id"]))

      is_binary(schema["id"]) ->
        Map.put(schema, "id", absolute_id(retrieval_uri, schema["id"]))

      true ->
        Map.put(schema, "$id", retrieval)
    end
  end

  defp ensure_retrieval_id(schema, _retrieval_uri), do: schema

  defp absolute_id(base, identifier) do
    base
    |> URI.merge(identifier)
    |> to_string()
  rescue
    _exception -> identifier
  end

  defp decode_schema(body) do
    case Jason.decode(body) do
      {:ok, schema} when is_map(schema) or is_boolean(schema) -> {:ok, schema}
      _other -> network_error(:invalid_json_schema)
    end
  end

  defp reject_fetched_dynamic_keywords(graph) do
    unsupported? =
      Enum.any?(graph.nodes, fn
        {{document, _path, _named?}, %{value: map, named?: false, role: :schema}}
        when document != :root and is_map(map) ->
          Map.has_key?(map, "$dynamicAnchor") or Map.has_key?(map, "$dynamicRef")

        _other ->
          false
      end)

    if unsupported?, do: {:error, :network_ref_forbidden}, else: :ok
  end

  defp local_documents(schema, policy_opts, preflight) do
    with :ok <- preflight.(schema, policy_opts),
         {:ok, remotes} <- referenced_documents(schema, nil),
         :ok <- reject_remote_documents(remotes) do
      {:ok, {schema, %{}}}
    end
  end

  defp reject_remote_documents([]), do: :ok
  defp reject_remote_documents(_remotes), do: {:error, :network_ref_forbidden}

  defp resolve_sealed(root_location, documents) do
    roots =
      Map.new(documents, fn {location, schema} ->
        root =
          if is_boolean(schema),
            do: ExJsonSchema.Schema.resolve(schema),
            else:
              ExJsonSchema.Schema.resolve(%Root{
                schema: schema,
                refs: documents,
                location: location
              })

        {location, root}
      end)

    root = Map.fetch!(roots, root_location)
    refs = Map.new(roots, fn {location, root} -> {location, root.schema} end)
    {:ok, %{root | refs: refs}}
  rescue
    exception -> {:error, {:invalid_schema, Exception.message(exception)}}
  end

  defp parse_fetch_uri(reference) do
    uri = URI.parse(reference)

    if uri.scheme && uri.host,
      do: {:ok, %URI{uri | fragment: nil}},
      else: network_error(:invalid_uri)
  end

  defp check_document_count(state, opts) do
    if state.document_count < opts[:max_documents],
      do: :ok,
      else: network_error(:document_limit)
  end

  defp check_reference_depth(depth, opts) do
    if depth <= opts[:max_reference_depth],
      do: :ok,
      else: network_error(:reference_depth)
  end

  defp check_redirect_count(count, opts) do
    if count <= opts[:max_redirects],
      do: :ok,
      else: network_error(:redirect_limit)
  end

  defp check_redirect_cycle(canonical, visited) do
    if canonical in visited,
      do: network_error(:redirect_cycle),
      else: :ok
  end

  defp add_aggregate_bytes(current, additional, opts) do
    total = current + additional

    if total <= opts[:max_aggregate_bytes],
      do: {:ok, total},
      else: network_error(:aggregate_response_too_large)
  end

  defp put_document(state, reference, schema),
    do: put_in(state, [:documents, reference], schema)

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.downcase(to_string(name)), to_string(value)}
    end)
  end

  defp header_values(headers, name) do
    for {^name, value} <- headers, do: String.trim(value)
  end

  defp compressed?(headers) do
    Enum.any?(header_values(headers, "content-encoding"), fn value ->
      String.downcase(value) not in ["", "identity"]
    end)
  end

  defp allowed_schemes(opts), do: if(opts[:allow_http], do: ["http", "https"], else: ["https"])

  defp valid_host?(host) when is_binary(host) do
    byte_size(host) <= 253 and String.match?(host, ~r/^[A-Za-z0-9.:-]+$/)
  end

  defp allowed_host?(host, allowed_hosts) do
    normalized = normalize_host(host)

    Enum.any?(allowed_hosts, fn pattern ->
      pattern = normalize_host(pattern)

      case pattern do
        "*." <> suffix ->
          String.ends_with?(normalized, "." <> suffix) and normalized != suffix

        exact ->
          normalized == exact
      end
    end)
  end

  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")

  defp canonical_uri(%URI{} = uri) do
    scheme = String.downcase(uri.scheme)
    host = normalize_host(uri.host)
    port = if uri.port == default_port(scheme), do: nil, else: uri.port
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    %URI{uri | scheme: scheme, host: host, port: port, path: path, fragment: nil}
    |> to_string()
  end

  defp document_uri(%URI{} = uri), do: uri |> Map.put(:fragment, nil) |> to_string()

  defp log_fetch(uri) do
    digest = hash_term(to_string(uri))
    Logger.info("Fetching remote JSON Schema host=#{uri.host} uri_sha256=#{digest}")
    :ok
  end

  defp hash_term(term) do
    :crypto.hash(:sha256, to_string(term)) |> Base.encode16(case: :lower)
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp network_error(reason), do: {:error, {:network_schema_error, reason}}
end
