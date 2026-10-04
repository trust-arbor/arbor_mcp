defmodule Arbor.MCP.Content.SchemaRemoteResolver do
  @moduledoc false

  alias Arbor.MCP.Internal.NetworkPolicy
  alias ExJsonSchema.Schema.Root

  require Logger

  @literal_keywords MapSet.new(~w(const default enum examples))
  @redirect_statuses [301, 302, 303, 307, 308]

  @type network_error :: {:network_schema_error, atom()}

  # Policy preflight is injected by `Arbor.MCP.Content.SchemaPolicy` (the only
  # caller) so this resolver never depends back on the policy module that
  # selects it. It is applied to the root schema and to every fetched document.
  @type preflight :: (map() | boolean(), keyword() -> :ok | {:error, term()})

  @spec resolve(map() | boolean(), keyword(), preflight()) ::
          {:ok, Root.t()} | {:error, term()}
  def resolve(schema, policy_opts, preflight) when is_function(preflight, 2) do
    with {:ok, {normalized_schema, documents}} <- fetch_documents(schema, policy_opts, preflight),
         {:ok, resolved_documents} <- resolve_documents(documents) do
      resolve_root(normalized_schema, resolved_documents)
    end
  end

  @doc false
  @spec fetch_documents(map() | boolean(), keyword(), preflight()) ::
          {:ok, {map() | boolean(), map()}} | {:error, term()}
  def fetch_documents(schema, policy_opts, preflight) do
    network_opts = policy_opts[:network_refs]
    state = %{documents: %{}, fetched: %{}, aggregate_bytes: 0, document_count: 0}

    with {:ok, normalized_schema} <- normalize_references(schema, nil),
         :ok <- preflight.(normalized_schema, policy_opts),
         {:ok, references} <- referenced_documents(normalized_schema, nil),
         {:ok, state} <- fetch_references(references, state, [], 0, policy_opts, preflight) do
      Logger.info(
        "Resolved remote JSON Schema documents count=#{state.document_count} " <>
          "bytes=#{state.aggregate_bytes} " <>
          "trust_partition_sha256=#{hash_term(network_opts[:trust_partition])}"
      )

      {:ok, {normalized_schema, state.documents}}
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

  defp fetch_references([], state, _stack, _depth, _policy_opts, _preflight), do: {:ok, state}

  defp fetch_references([reference | rest], state, stack, depth, policy_opts, preflight) do
    with {:ok, next_state} <-
           fetch_document(reference, state, stack, depth, policy_opts, preflight) do
      fetch_references(rest, next_state, stack, depth, policy_opts, preflight)
    end
  end

  defp fetch_document(reference, state, stack, depth, policy_opts, preflight) do
    network_opts = policy_opts[:network_refs]

    with :ok <- check_reference_depth(depth, network_opts),
         {:ok, uri} <- parse_fetch_uri(reference),
         canonical = canonical_uri(uri),
         :ok <- check_reference_cycle(canonical, stack) do
      case state.fetched do
        %{^canonical => schema} ->
          {:ok, put_document(state, reference, schema)}

        _missing ->
          fetch_new_document(
            reference,
            uri,
            canonical,
            state,
            stack,
            depth,
            policy_opts,
            preflight
          )
      end
    end
  end

  defp fetch_new_document(
         reference,
         uri,
         canonical,
         state,
         stack,
         depth,
         policy_opts,
         preflight
       ) do
    network_opts = policy_opts[:network_refs]

    with :ok <- check_document_count(state, network_opts),
         {:ok, response} <- fetch_with_redirects(uri, network_opts, 0, [], 0),
         {:ok, next_bytes} <-
           add_aggregate_bytes(state.aggregate_bytes, response.bytes, network_opts),
         {:ok, decoded} <- decode_schema(response.body),
         identified_schema = ensure_retrieval_id(decoded, response.final_uri),
         {:ok, schema} <- normalize_references(identified_schema, response.final_uri),
         :ok <- preflight.(schema, policy_opts),
         {:ok, nested_references} <- referenced_documents(schema, response.final_uri) do
      next_state =
        state
        |> Map.put(:aggregate_bytes, next_bytes)
        |> Map.update!(:document_count, &(&1 + 1))
        |> put_fetched(canonical, response.final_uri, schema)
        |> put_document(reference, schema)
        |> put_document(document_uri(response.final_uri), schema)

      fetch_references(
        nested_references,
        next_state,
        [canonical_uri(response.final_uri), canonical | stack],
        depth + 1,
        policy_opts,
        preflight
      )
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
    with {:ok, references} <- walk_references(schema, base_uri, []) do
      {:ok, references |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp normalize_references(map, base_uri) when is_map(map) do
    with {:ok, scope} <- schema_scope(map, base_uri) do
      Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        cond do
          MapSet.member?(@literal_keywords, key) or key in ["$id", "id"] ->
            {:cont, {:ok, Map.put(acc, key, value)}}

          key in ["$ref", "$dynamicRef"] ->
            case normalize_reference(value, scope) do
              {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
              {:error, _reason} = error -> {:halt, error}
            end

          true ->
            case normalize_references(value, scope) do
              {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
              {:error, _reason} = error -> {:halt, error}
            end
        end
      end)
    end
  end

  defp normalize_references(list, base_uri) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_references(value, base_uri) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_references(value, _base_uri), do: {:ok, value}

  defp normalize_reference(reference, _scope) when not is_binary(reference),
    do: {:ok, reference}

  defp normalize_reference("#" <> _fragment = reference, _scope), do: {:ok, reference}
  defp normalize_reference("", _scope), do: {:ok, ""}

  defp normalize_reference(reference, scope) do
    with {:ok, uri} <- merge_uri(scope, reference) do
      {:ok, to_string(uri)}
    end
  end

  defp walk_references(map, base_uri, references) when is_map(map) do
    with {:ok, scope} <- schema_scope(map, base_uri) do
      Enum.reduce_while(map, {:ok, references}, fn {key, value}, {:ok, acc} ->
        cond do
          MapSet.member?(@literal_keywords, key) or key in ["$id", "id"] ->
            {:cont, {:ok, acc}}

          key in ["$ref", "$dynamicRef"] ->
            case reference_document(value, scope) do
              {:ok, nil} -> {:cont, {:ok, acc}}
              {:ok, document} -> {:cont, {:ok, [document | acc]}}
              {:error, _reason} = error -> {:halt, error}
            end

          true ->
            case walk_references(value, scope, acc) do
              {:ok, next_acc} -> {:cont, {:ok, next_acc}}
              {:error, _reason} = error -> {:halt, error}
            end
        end
      end)
    end
  end

  defp walk_references(list, base_uri, references) when is_list(list) do
    Enum.reduce_while(list, {:ok, references}, fn value, {:ok, acc} ->
      case walk_references(value, base_uri, acc) do
        {:ok, next_acc} -> {:cont, {:ok, next_acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp walk_references(_value, _base_uri, references), do: {:ok, references}

  defp schema_scope(schema, base_uri) do
    case Map.get(schema, "$id") || Map.get(schema, "id") do
      nil -> {:ok, base_uri}
      identifier when is_binary(identifier) -> merge_uri(base_uri, identifier)
      _invalid -> network_error(:invalid_schema_id)
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

  defp merge_uri(%URI{} = base, value) do
    {:ok, URI.merge(base, value)}
  rescue
    _exception -> network_error(:invalid_uri)
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

  defp resolve_documents(documents) do
    resolved =
      Map.new(documents, fn {location, schema} ->
        if is_boolean(schema) do
          {location, schema}
        else
          root =
            ExJsonSchema.Schema.resolve(%Root{
              schema: schema,
              refs: documents,
              location: location
            })

          {location, root.schema}
        end
      end)

    {:ok, resolved}
  rescue
    _exception -> network_error(:invalid_remote_schema)
  end

  defp resolve_root(schema, _documents) when is_boolean(schema) do
    {:ok, ExJsonSchema.Schema.resolve(schema)}
  end

  defp resolve_root(schema, documents) do
    {:ok, ExJsonSchema.Schema.resolve(%Root{schema: schema, refs: documents})}
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

  defp check_reference_cycle(canonical, stack) do
    if canonical in stack,
      do: network_error(:reference_cycle),
      else: :ok
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

  defp put_fetched(state, requested_canonical, final_uri, schema) do
    final_canonical = canonical_uri(final_uri)

    state
    |> put_in([:fetched, requested_canonical], schema)
    |> put_in([:fetched, final_canonical], schema)
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
