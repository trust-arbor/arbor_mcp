defmodule Arbor.MCP.Content.SchemaPolicy do
  @moduledoc """
  Fail-closed resource policy for JSON Schema compilation and validation.

  Cross-document references are disabled by default before either validator
  sees a schema, even if the host application configured ExJsonSchema's global
  remote resolver. Local fragment references remain supported. Network
  references can be enabled only through ArborMCP's allowlisted, IP-pinned resolver.

  Omitted or explicit draft 2020-12 declarations use JSV. Explicit drafts 4,
  6 and 7 use ExJsonSchema. Unknown dialects reject. Modern compiled artifacts
  are opaque; unchanged ExJsonSchema Roots retain their trusted-cache behavior.

  Schema size, structural depth, composition depth, total subschema count,
  instance bytes/depth, resolution time, and validation time are bounded. Defaults can be adjusted
  with `config :arbor_mcp, :json_schema, ...` or per call.

  The opt-in resolver revalidates every redirect and DNS result, rejects
  non-public addresses, pins the connection to an approved address, rejects
  compressed responses and proxies, and bounds response bytes, aggregate bytes,
  document count, reference depth, redirects, DNS, connection, and request time.
  Fetched schemas are scoped to one compilation and are never globally cached.
  """

  alias Arbor.MCP.Content.{SchemaDNS, SchemaHTTPClient, SchemaRemoteResolver}
  alias Arbor.MCP.Content.SchemaPolicy.{Compiled, Instance, Modern}

  @composition_keywords MapSet.new(~w(allOf anyOf oneOf not if then else))
  @literal_keywords MapSet.new(~w(const default enum examples))
  @reference_keywords MapSet.new(~w($ref $recursiveRef $dynamicRef))

  @defaults [
    max_schema_bytes: 262_144,
    max_instance_bytes: 1_048_576,
    max_instance_depth: 64,
    max_schema_depth: 64,
    max_subschemas: 1_000,
    max_composition_depth: 16,
    resolve_timeout_ms: 1_000,
    validation_timeout_ms: 100
  ]

  @network_defaults [
    enabled: false,
    allowed_hosts: [],
    allow_http: false,
    max_redirects: 3,
    max_documents: 16,
    max_reference_depth: 8,
    max_response_bytes: 262_144,
    max_decompressed_bytes: 262_144,
    max_aggregate_bytes: 1_048_576,
    dns_timeout_ms: 1_000,
    connect_timeout_ms: 2_000,
    request_timeout_ms: 3_000,
    proxy: :disabled,
    trust_partition: "application",
    dns_resolver: SchemaDNS,
    http_client: SchemaHTTPClient
  ]

  @network_integer_options ~w(
    max_redirects
    max_documents
    max_reference_depth
    max_response_bytes
    max_decompressed_bytes
    max_aggregate_bytes
    dns_timeout_ms
    connect_timeout_ms
    request_timeout_ms
  )a

  @type policy_error ::
          :network_ref_forbidden
          | {:schema_limit_exceeded, atom(), non_neg_integer()}
          | {:schema_resolution_timeout, non_neg_integer()}
          | {:schema_validation_timeout, non_neg_integer()}
          | {:invalid_schema_policy_option, atom()}
          | {:invalid_schema, String.t()}
          | {:schema_validation_failed, String.t()}
          | {:network_schema_error, atom()}

  @type compiled :: Compiled.t() | ExJsonSchema.Schema.Root.t()
  @type compile_result :: {:ok, compiled()} | {:error, policy_error()}
  @type optional_compile_result :: {:ok, compiled() | nil} | {:error, policy_error()}
  @type validation_result :: :ok | {:error, term()}

  @doc "Returns the effective schema-policy options."
  @spec options(keyword()) :: keyword()
  def options(overrides \\ []) when is_list(overrides) do
    configured = Application.get_env(:arbor_mcp, :json_schema, [])
    configured = if is_list(configured), do: configured, else: []

    network_options = merge_network_options(configured, overrides)

    @defaults
    |> Keyword.merge(Keyword.take(configured, Keyword.keys(@defaults)))
    |> Keyword.merge(Keyword.take(overrides, Keyword.keys(@defaults)))
    |> Keyword.put(:network_refs, network_options)
  end

  @doc "Normalizes atom-keyed schema terms to their JSON wire representation."
  @spec json_compatible(term()) :: term()
  def json_compatible(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_compatible(value)} end)
  end

  def json_compatible(list) when is_list(list), do: Enum.map(list, &json_compatible/1)

  def json_compatible(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  def json_compatible(value), do: value

  @doc "Checks a raw object/boolean schema without resolving references."
  @spec preflight(map() | boolean(), keyword()) :: :ok | {:error, policy_error()}
  def preflight(schema, opts \\ []) do
    with {:ok, opts} <- policy_options(opts),
         {:ok, schema} <- normalize_schema(schema, opts),
         do: preflight_normalized(schema, opts)
  end

  @doc """
  Compiles an object/boolean JSON Schema to `{:ok, resolved}` or `{:error, reason}`.

  `nil` is invalid; use `compile_optional/2` when absence deliberately disables
  validation. Atom keys/values normalize to JSON strings. Conflicting normalized
  keys and non-JSON schema terms reject before any application encoder runs.
  An omitted `$schema` or explicit draft 2020-12 uses JSV. Explicit drafts 4,
  6 and 7 retain ExJsonSchema semantics. Unknown dialects fail compilation.

  Retain the returned compiled artifact unchanged for repeated validation.
  Caller-created or mutated artifacts are trusted caches, not raw declarations.
  """
  @spec compile(map() | boolean(), keyword()) :: compile_result()
  def compile(schema, opts \\ []) do
    with {:ok, opts} <- policy_options(opts),
         {:ok, schema} <- normalize_schema(schema, opts),
         :ok <- preflight_normalized(schema, opts),
         :ok <- ensure_backend(schema) do
      run_bounded(
        fn ->
          try do
            with :ok <- validate_schema_shape(schema), do: resolve_schema(schema, opts)
          rescue
            _exception -> {:error, {:invalid_schema, "schema resolution failed"}}
          catch
            _kind, _reason -> {:error, {:invalid_schema, "schema resolution failed"}}
          end
        end,
        opts[:resolve_timeout_ms],
        {:schema_resolution_timeout, opts[:resolve_timeout_ms]}
      )
    end
  end

  @doc """
  Explicit optional compilation. Only `nil` returns `{:ok, nil}`; `false`
  compiles an always-rejecting schema. Invalid schemas remain tagged errors.
  """
  @spec compile_optional(map() | boolean() | nil, keyword()) :: optional_compile_result()
  def compile_optional(schema, opts \\ [])

  def compile_optional(nil, opts) do
    with {:ok, _opts} <- policy_options(opts), do: {:ok, nil}
  end

  def compile_optional(schema, opts), do: compile(schema, opts)

  @doc """
  Validates data against a raw or unchanged compiled schema within a deadline.

  Returns `:ok` or `{:error, reason}`; it does not insert defaults, coerce types,
  normalize instance keys or return transformed data. `nil` is invalid. Modern
  instance failures use a fixed safe error list; explicit legacy schemas retain
  ExJsonSchema's error list. Policy failures are tagged.
  """
  @spec validate(term(), map() | boolean() | compiled(), keyword()) :: validation_result()
  def validate(data, schema, opts \\ []), do: validate_instance(data, schema, opts, false)

  @doc false
  @spec validate_compatible(term(), map() | boolean() | compiled(), keyword()) ::
          validation_result()
  def validate_compatible(data, schema, opts), do: validate_instance(data, schema, opts, true)

  defp validate_instance(data, schema, opts, compatible?) do
    with {:ok, opts} <- policy_options(opts),
         {:ok, resolved} <- ensure_compiled(schema, opts) do
      run_bounded(
        fn ->
          try do
            with :ok <- Instance.check(data, opts, compatible?) do
              data = if compatible?, do: json_compatible(data), else: data
              validate_compiled(resolved, data)
            end
          rescue
            _exception -> {:error, {:schema_validation_failed, "schema validation failed"}}
          catch
            _kind, _reason -> {:error, {:schema_validation_failed, "schema validation failed"}}
          end
        end,
        opts[:validation_timeout_ms],
        {:schema_validation_timeout, opts[:validation_timeout_ms]}
      )
    end
  end

  @doc "Explicit optional validation: only `nil` bypasses; `false` rejects all data."
  @spec validate_optional(term(), map() | boolean() | compiled() | nil, keyword()) ::
          validation_result()
  def validate_optional(data, schema, opts \\ [])

  def validate_optional(_data, nil, opts) do
    with {:ok, _opts} <- policy_options(opts), do: :ok
  end

  def validate_optional(data, schema, opts), do: validate(data, schema, opts)

  defp policy_options(overrides) do
    configured = Application.get_env(:arbor_mcp, :json_schema, [])

    if Keyword.keyword?(overrides) and Keyword.keyword?(configured) do
      opts = options(overrides)
      with :ok <- validate_options(opts), do: {:ok, opts}
    else
      {:error, {:invalid_schema_policy_option, :options}}
    end
  end

  defp preflight_normalized(schema, opts) do
    with :ok <- check_encoded_size(schema, opts),
         {:ok, _count} <- walk(schema, 0, 0, 0, opts),
         do: :ok
  end

  defp normalize_schema(schema, opts)
       when (is_map(schema) and not is_struct(schema)) or is_boolean(schema) do
    case normalize_value(schema, 0, opts[:max_schema_bytes], Map.new(opts)) do
      {:ok, schema, _remaining} -> {:ok, schema}
      error -> error
    end
  end

  defp normalize_schema(_schema, _opts),
    do: {:error, {:invalid_schema, "schema must be an object or boolean"}}

  defp normalize_value(_value, depth, _remaining, opts) when depth > opts.max_schema_depth,
    do: {:error, {:schema_limit_exceeded, :max_schema_depth, depth}}

  defp normalize_value(_value, _depth, remaining, opts) when remaining < 0,
    do: {:error, {:schema_limit_exceeded, :max_schema_bytes, opts.max_schema_bytes + 1}}

  defp normalize_value(value, depth, remaining, opts)
       when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}, remaining - 2}, fn {key, item}, {:ok, acc, remaining} ->
      with {:ok, key} <- schema_key(key, remaining - 3, opts),
           false <- Map.has_key?(acc, key),
           {:ok, item, remaining} <-
             normalize_value(
               item,
               depth + 1,
               remaining - byte_size(key) - 3 - if(map_size(acc) == 0, do: 0, else: 1),
               opts
             ) do
        {:cont, {:ok, Map.put(acc, key, item), remaining}}
      else
        true -> {:halt, {:error, {:invalid_schema, "conflicting normalized schema keys"}}}
        error -> {:halt, error}
      end
    end)
    |> normalized_budget(opts)
  end

  defp normalize_value(value, depth, remaining, opts) when is_list(value),
    do: normalize_list(value, depth, remaining - 2, opts, [])

  defp normalize_value(value, _depth, remaining, opts) when is_binary(value) do
    with {:ok, _value, _remaining} = result <-
           normalized_budget({:ok, value, remaining - byte_size(value) - 2}, opts) do
      if String.valid?(value), do: result, else: invalid_json_schema()
    end
  end

  defp normalize_value(value, depth, remaining, opts)
       when is_atom(value) and value not in [true, false, nil],
       do: normalize_value(Atom.to_string(value), depth, remaining, opts)

  defp normalize_value(value, _depth, remaining, opts) when is_number(value),
    do: normalized_budget({:ok, value, remaining - number_cost(value)}, opts)

  defp normalize_value(value, _depth, remaining, opts) when value in [true, false, nil],
    do: normalized_budget({:ok, value, remaining - if(value == false, do: 5, else: 4)}, opts)

  defp normalize_value(_value, _depth, _remaining, _opts), do: invalid_json_schema()

  defp number_cost(value) when is_integer(value), do: max(1, :erlang.external_size(value) - 5)
  defp number_cost(_float), do: 1

  defp normalize_list([], _depth, remaining, opts, acc),
    do: normalized_budget({:ok, Enum.reverse(acc), remaining}, opts)

  defp normalize_list([item | rest], depth, remaining, opts, acc) do
    with {:ok, item, remaining} <-
           normalize_value(item, depth + 1, remaining - if(acc == [], do: 0, else: 1), opts),
         do: normalize_list(rest, depth, remaining, opts, [item | acc])
  end

  defp normalize_list(_invalid, _depth, _remaining, _opts, _acc), do: invalid_json_schema()

  defp normalized_budget({:ok, _value, remaining}, opts) when remaining < 0,
    do: {:error, {:schema_limit_exceeded, :max_schema_bytes, opts.max_schema_bytes + 1}}

  defp normalized_budget(result, _opts), do: result

  defp schema_key(key, remaining, opts) when is_atom(key),
    do: schema_key(Atom.to_string(key), remaining, opts)

  defp schema_key(key, remaining, opts) when is_binary(key) do
    with {:ok, _key, _remaining} <-
           normalized_budget({:ok, key, remaining - byte_size(key)}, opts) do
      if String.valid?(key), do: {:ok, key}, else: invalid_json_schema()
    end
  end

  defp schema_key(_key, _remaining, _opts), do: invalid_json_schema()

  # ExJsonSchema skips its meta-schema check when $id resembles a meta-schema
  # identifier. Validate every raw object explicitly so declarations cannot use
  # that implementation shortcut to accept an invalid schema silently.
  defp ensure_backend(schema) do
    case schema_draft(schema) do
      {:ok, :modern} -> ensure_modern_modules()
      {:ok, _legacy} -> :ok
      _error -> invalid_schema_declaration()
    end
  end

  defp ensure_modern_modules do
    modules = [Modern, Compiled, Arbor.MCP.Content.SchemaPolicy.ModernResolver]

    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case Code.ensure_compiled(module) do
        {:module, ^module} -> {:cont, :ok}
        _other -> {:halt, invalid_schema_declaration()}
      end
    end)
  end

  defp validate_schema_shape(schema) do
    case schema_draft(schema) do
      {:ok, :modern} -> Modern.validate_shape(schema)
      {:ok, legacy} -> validate_legacy_shape(schema, legacy)
      _error -> invalid_schema_declaration()
    end
  end

  defp validate_legacy_shape(schema, draft) do
    case ExJsonSchema.Validator.validate(ExJsonSchema.Schema.resolve(draft.schema()), schema) do
      :ok -> :ok
      _error -> invalid_schema_declaration()
    end
  end

  defp schema_draft(schema) when is_boolean(schema), do: {:ok, :modern}

  defp schema_draft(schema) do
    case Map.fetch(schema, "$schema") do
      :error -> {:ok, :modern}
      {:ok, uri} when is_binary(uri) -> supported_draft(uri)
      _other -> {:error, :unsupported_schema_draft}
    end
  end

  defp supported_draft(uri)
       when uri in [
              "https://json-schema.org/draft/2020-12/schema",
              "https://json-schema.org/draft/2020-12/schema#"
            ],
       do: {:ok, :modern}

  defp supported_draft(uri) do
    uri = if String.ends_with?(uri, "#"), do: String.slice(uri, 0, byte_size(uri) - 1), else: uri

    case String.replace_prefix(uri, "https://", "http://") do
      "http://json-schema.org/schema" -> {:ok, ExJsonSchema.Schema.Draft7}
      "http://json-schema.org/draft-04/schema" -> {:ok, ExJsonSchema.Schema.Draft4}
      "http://json-schema.org/draft-06/schema" -> {:ok, ExJsonSchema.Schema.Draft6}
      "http://json-schema.org/draft-07/schema" -> {:ok, ExJsonSchema.Schema.Draft7}
      _other -> {:error, :unsupported_schema_draft}
    end
  end

  defp invalid_schema_declaration,
    do: {:error, {:invalid_schema, "schema declaration is invalid or unsupported"}}

  defp validate_compiled(%ExJsonSchema.Schema.Root{} = root, data),
    do: ExJsonSchema.Validator.validate(root, data)

  defp validate_compiled(compiled, data), do: Compiled.validate(compiled, data)

  @doc "Formats a policy failure without including remote-reference values."
  @spec format_error(policy_error()) :: String.t()
  def format_error(:network_ref_forbidden),
    do: "network and cross-document JSON Schema references are disabled"

  def format_error({:schema_limit_exceeded, limit, value}),
    do: "JSON Schema exceeds #{limit} (observed #{value})"

  def format_error({:schema_resolution_timeout, timeout}),
    do: "JSON Schema resolution exceeded #{timeout}ms"

  def format_error({:schema_validation_timeout, timeout}),
    do: "JSON Schema validation exceeded #{timeout}ms"

  def format_error({:invalid_schema_policy_option, option}),
    do: "JSON Schema policy option #{option} is invalid"

  def format_error({:invalid_schema, message}), do: "invalid JSON Schema: #{message}"

  def format_error({:schema_validation_failed, message}),
    do: "JSON Schema validation failed: #{message}"

  def format_error({:network_schema_error, reason}),
    do: "remote JSON Schema resolution failed: #{network_error_message(reason)}"

  defp ensure_compiled(%ExJsonSchema.Schema.Root{} = root, _opts), do: {:ok, root}

  defp ensure_compiled(schema, opts) do
    case Compiled.fetch(schema) do
      {:ok, compiled} -> {:ok, compiled}
      :error -> compile(schema, opts)
    end
  end

  defp validate_options(opts) do
    with :ok <- validate_integer_options(opts, Keyword.keys(@defaults)) do
      validate_network_options(opts[:network_refs])
    end
  end

  defp check_encoded_size(schema, opts) do
    case Jason.encode(schema) do
      {:ok, encoded} ->
        size = byte_size(encoded)
        limit = opts[:max_schema_bytes]

        if size <= limit,
          do: :ok,
          else: {:error, {:schema_limit_exceeded, :max_schema_bytes, size}}

      {:error, _reason} ->
        invalid_json_schema()
    end
  rescue
    _exception -> invalid_json_schema()
  end

  defp invalid_json_schema, do: {:error, {:invalid_schema, "schema is not JSON-compatible"}}

  defp walk(value, depth, composition_depth, count, opts) when is_map(value) do
    count = count + 1

    cond do
      depth > opts[:max_schema_depth] ->
        {:error, {:schema_limit_exceeded, :max_schema_depth, depth}}

      composition_depth > opts[:max_composition_depth] ->
        {:error, {:schema_limit_exceeded, :max_composition_depth, composition_depth}}

      count > opts[:max_subschemas] ->
        {:error, {:schema_limit_exceeded, :max_subschemas, count}}

      true ->
        walk_map_children(value, depth, composition_depth, count, opts)
    end
  end

  defp walk(values, depth, composition_depth, count, opts) when is_list(values) do
    if depth > opts[:max_schema_depth] do
      {:error, {:schema_limit_exceeded, :max_schema_depth, depth}}
    else
      Enum.reduce_while(values, {:ok, count}, fn child, {:ok, current_count} ->
        case walk(child, depth + 1, composition_depth, current_count, opts) do
          {:ok, next_count} -> {:cont, {:ok, next_count}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp walk(_value, _depth, _composition_depth, count, _opts), do: {:ok, count}

  defp walk_map_children(value, depth, composition_depth, count, opts) do
    Enum.reduce_while(value, {:ok, count}, fn {key, child}, {:ok, current_count} ->
      cond do
        MapSet.member?(@literal_keywords, key) ->
          {:cont, {:ok, current_count}}

        MapSet.member?(@reference_keywords, key) and external_ref?(child) ->
          if key in ["$ref", "$dynamicRef"] and network_refs_enabled?(opts),
            do: {:cont, {:ok, current_count}},
            else: {:halt, {:error, :network_ref_forbidden}}

        true ->
          next_composition_depth =
            if MapSet.member?(@composition_keywords, key),
              do: composition_depth + 1,
              else: composition_depth

          case walk(child, depth + 1, next_composition_depth, current_count, opts) do
            {:ok, next_count} -> {:cont, {:ok, next_count}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  defp external_ref?(ref) when is_binary(ref), do: ref != "" and not String.starts_with?(ref, "#")
  defp external_ref?(_ref), do: true

  defp resolve_schema(schema, opts) do
    with {:ok, draft} <- schema_draft(schema) do
      case draft do
        :modern -> resolve_modern_schema(schema, opts)
        _legacy -> resolve_legacy_schema(schema, opts)
      end
    end
  end

  defp resolve_modern_schema(schema, opts) do
    if network_refs_enabled?(opts) do
      with {:ok, {schema, documents}} <-
             SchemaRemoteResolver.fetch_documents(schema, opts, &preflight_document/2) do
        Modern.compile(schema, documents)
      end
    else
      Modern.compile(schema, %{})
    end
  end

  defp resolve_legacy_schema(schema, opts) do
    if network_refs_enabled?(opts),
      do: SchemaRemoteResolver.resolve(schema, opts, &preflight_document/2),
      else: {:ok, ExJsonSchema.Schema.resolve(schema)}
  end

  defp preflight_document(schema, opts) do
    with :ok <- preflight(schema, opts), do: validate_schema_shape(schema)
  end

  defp network_refs_enabled?(opts), do: opts[:network_refs][:enabled] == true

  defp validate_integer_options(opts, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      value = Keyword.get(opts, key)

      if is_integer(value) and value >= 0,
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_schema_policy_option, key}}}
    end)
  end

  defp validate_network_options(network_opts) when is_list(network_opts) do
    with :ok <- validate_integer_options(network_opts, @network_integer_options),
         :ok <- validate_boolean_option(network_opts, :enabled),
         :ok <- validate_boolean_option(network_opts, :allow_http),
         :ok <- validate_allowed_hosts(network_opts[:allowed_hosts]),
         :ok <- require_allowed_host_when_enabled(network_opts),
         :ok <- validate_fixed_option(network_opts, :proxy, :disabled),
         :ok <- validate_trust_partition(network_opts[:trust_partition]),
         :ok <- validate_callback(network_opts, :dns_resolver, 2) do
      validate_callback(network_opts, :http_client, 3)
    end
  end

  defp validate_network_options(_network_opts),
    do: {:error, {:invalid_schema_policy_option, :network_refs}}

  defp validate_boolean_option(opts, key) do
    if is_boolean(opts[key]), do: :ok, else: {:error, {:invalid_schema_policy_option, key}}
  end

  defp validate_allowed_hosts(hosts) when is_list(hosts) do
    valid? =
      Enum.all?(hosts, fn host ->
        is_binary(host) and host != "" and byte_size(host) <= 255 and
          String.match?(host, ~r/^(\*\.)?[A-Za-z0-9.:-]+$/)
      end)

    if valid?, do: :ok, else: {:error, {:invalid_schema_policy_option, :allowed_hosts}}
  end

  defp validate_allowed_hosts(_hosts),
    do: {:error, {:invalid_schema_policy_option, :allowed_hosts}}

  defp require_allowed_host_when_enabled(network_opts) do
    if network_opts[:enabled] and network_opts[:allowed_hosts] == [],
      do: {:error, {:invalid_schema_policy_option, :allowed_hosts}},
      else: :ok
  end

  defp validate_fixed_option(opts, key, expected) do
    if opts[key] == expected, do: :ok, else: {:error, {:invalid_schema_policy_option, key}}
  end

  defp validate_trust_partition(partition) when is_binary(partition) and partition != "", do: :ok

  defp validate_trust_partition(partition) when is_atom(partition) and not is_nil(partition),
    do: :ok

  defp validate_trust_partition(_partition),
    do: {:error, {:invalid_schema_policy_option, :trust_partition}}

  defp validate_callback(opts, key, arity) do
    callback = opts[key]

    valid? =
      is_function(callback, arity) or
        (is_atom(callback) and Code.ensure_compiled(callback) == {:module, callback} and
           function_exported?(callback, callback_function(key), arity))

    if valid?,
      do: :ok,
      else: {:error, {:invalid_schema_policy_option, key}}
  end

  defp callback_function(:dns_resolver), do: :resolve
  defp callback_function(:http_client), do: :get

  defp merge_network_options(configured, overrides) do
    with {:ok, network_config} <- nested_options(configured, :network_refs),
         {:ok, network_overrides} <- nested_options(overrides, :network_refs) do
      @network_defaults
      |> Keyword.merge(Keyword.take(network_config, Keyword.keys(@network_defaults)))
      |> Keyword.merge(Keyword.take(network_overrides, Keyword.keys(@network_defaults)))
    else
      {:error, :invalid} -> :invalid
    end
  end

  defp nested_options(options, key) do
    case Keyword.fetch(options, key) do
      :error ->
        {:ok, []}

      {:ok, nested} when is_list(nested) ->
        if Keyword.keyword?(nested), do: {:ok, nested}, else: {:error, :invalid}

      {:ok, _invalid} ->
        {:error, :invalid}
    end
  end

  defp network_error_message(:host_not_allowed), do: "host is not allowlisted"
  defp network_error_message(:non_public_address), do: "target resolved to a non-public address"
  defp network_error_message(:scheme_not_allowed), do: "URI scheme is not allowed"
  defp network_error_message(:userinfo_forbidden), do: "URI userinfo is forbidden"
  defp network_error_message(:proxy_forbidden), do: "proxy use is disabled"
  defp network_error_message(:dns_timeout), do: "DNS resolution timed out"
  defp network_error_message(:dns_failed), do: "DNS resolution failed"
  defp network_error_message(:response_too_large), do: "response exceeded the byte limit"

  defp network_error_message(:decompressed_response_too_large),
    do: "response exceeded the decompressed-byte limit"

  defp network_error_message(:aggregate_response_too_large),
    do: "responses exceeded the aggregate-byte limit"

  defp network_error_message(:compressed_response), do: "compressed responses are rejected"
  defp network_error_message(:document_limit), do: "document count exceeded the limit"
  defp network_error_message(:reference_depth), do: "reference depth exceeded the limit"
  defp network_error_message(:reference_cycle), do: "cross-document reference cycle detected"
  defp network_error_message(:redirect_limit), do: "redirect count exceeded the limit"
  defp network_error_message(:redirect_cycle), do: "redirect cycle detected"
  defp network_error_message(:redirect_downgrade), do: "HTTPS-to-HTTP redirect was rejected"
  defp network_error_message(:unexpected_status), do: "server returned an unexpected status"
  defp network_error_message(:invalid_json_schema), do: "response was not a JSON Schema"
  defp network_error_message(:invalid_remote_schema), do: "remote schema was invalid"

  defp network_error_message(:relative_reference_without_base),
    do: "relative reference has no absolute base URI"

  defp network_error_message(_reason), do: "request was rejected"

  defp run_bounded(fun, timeout, timeout_error) do
    task = Task.async(fun)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, {:schema_validation_failed, "schema worker exited"}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, timeout_error}
    end
  end

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: key
end
