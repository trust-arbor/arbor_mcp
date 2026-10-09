defmodule Arbor.MCP.APIManifest do
  @moduledoc false

  # Repository-only census. Match the conservative lib/ scope of
  # test/fixtures/api/api_baseline_1_5_plus.json rather than treating HexDocs visibility as an
  # exhaustive compatibility promise. Reflection does not start applications.

  @excluded_exports [__info__: 1, module_info: 0, module_info: 1]
  @notice_pattern ~r/\bdeprecat(?:ed|ion)\b|\bremov(?:al|ed)\b/i

  @spec build([module()], keyword()) :: map()
  def build(modules, opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()

    entries =
      modules
      |> Enum.uniq()
      |> Enum.flat_map(fn module ->
        Code.ensure_loaded!(module)
        source = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
        relative = Path.relative_to(Path.expand(source), root)

        if String.starts_with?(relative, "lib/") do
          [snapshot(module, relative)]
        else
          []
        end
      end)
      |> Enum.sort_by(& &1.name)

    if entries == [], do: raise(ArgumentError, "no compiled modules with sources under lib/")

    sources =
      entries
      |> Enum.map(& &1.source)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn path ->
        %{path: path, sha256: root |> Path.join(path) |> File.read!() |> digest()}
      end)

    %{
      schema_version: 1,
      baseline: %{
        application: opts |> Keyword.fetch!(:application) |> to_string(),
        package_version: Keyword.fetch!(opts, :version),
        source_ref: Keyword.fetch!(opts, :source_ref),
        source_digest: digest(Enum.map(sources, &[&1.path, "\0", &1.sha256, "\n"])),
        toolchain: %{
          elixir: System.version(),
          otp: to_string(:erlang.system_info(:otp_release)),
          mix_environment: opts |> Keyword.fetch!(:environment) |> to_string()
        }
      },
      scope: %{
        source_directory: "lib",
        includes_hidden_modules: true,
        includes_hidden_exports: true,
        excludes_exports: Enum.map(@excluded_exports, &identifier/1),
        excludes_private_types: true,
        documentation_notices_are_removal_decisions: false
      },
      summary: summary(entries),
      sources: sources,
      modules: entries
    }
  end

  @spec encode(map()) :: binary()
  def encode(manifest) do
    manifest |> ordered() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")
  end

  defp snapshot(module, source) do
    {module_doc, module_metadata, docs} = docs(module)
    deprecated = Map.new(module.__info__(:deprecated))
    optional = optional_callbacks(module)

    %{
      name: inspect(module),
      source: source,
      documentation: visibility(module_doc),
      deprecation: Map.get(module_metadata, :deprecated),
      documentation_notices: notices(module_doc),
      exports:
        module.module_info(:exports)
        |> Kernel.--(@excluded_exports)
        |> Enum.sort()
        |> Enum.map(&identifier/1),
      callables: callables(module, docs, deprecated),
      callbacks: callbacks(module, docs, optional),
      types: types(module, docs),
      struct_fields: struct_fields(module)
    }
  end

  defp docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, module_doc, metadata, entries} ->
        indexed =
          Map.new(entries, fn {identifier, _, _, doc, metadata} ->
            {identifier, %{doc: doc, metadata: metadata}}
          end)

        {module_doc, metadata, indexed}

      {:error, reason} ->
        raise ArgumentError,
              "missing compiled documentation for #{inspect(module)}: #{inspect(reason)}"
    end
  end

  defp callables(module, docs, deprecated) do
    for {kind, exports} <- [
          function: module.__info__(:functions),
          macro: module.__info__(:macros)
        ],
        {name, arity} <- exports do
      entry = doc_entry(docs, kind, name, arity)

      %{
        kind: to_string(kind),
        name: to_string(name),
        arity: arity,
        documentation: visibility(entry.doc),
        deprecation: Map.get(deprecated, {name, arity}) || Map.get(entry.metadata, :deprecated),
        documentation_notices: notices(entry.doc)
      }
    end
    |> Enum.sort_by(&{&1.kind, &1.name, &1.arity})
  end

  defp callbacks(module, docs, optional) do
    callbacks = fetch_typespecs(module, :callbacks)

    callbacks
    |> Enum.map(fn {{name, arity}, definitions} ->
      {kind, public_name, public_arity} = callback_identifier(name, arity)
      entry = doc_entry(docs, kind, public_name, public_arity)

      %{
        kind: to_string(kind),
        name: to_string(public_name),
        arity: public_arity,
        optional: {name, arity} in optional,
        definitions: definitions |> Enum.map(&spec_string(name, &1)) |> Enum.sort(),
        documentation: visibility(entry.doc),
        deprecation: Map.get(entry.metadata, :deprecated),
        documentation_notices: notices(entry.doc)
      }
    end)
    |> Enum.sort_by(&{&1.kind, &1.name, &1.arity})
  end

  defp callback_identifier(name, arity) do
    case Atom.to_string(name) do
      "MACRO-" <> name -> {:macrocallback, String.to_existing_atom(name), arity - 1}
      _ -> {:callback, name, arity}
    end
  end

  defp types(module, docs) do
    types = fetch_typespecs(module, :types)

    for {kind, {name, _, args} = definition} <- types, kind in [:type, :opaque] do
      entry = doc_entry(docs, :type, name, length(args))

      %{
        kind: to_string(kind),
        name: to_string(name),
        arity: length(args),
        definition: definition |> Code.Typespec.type_to_quoted() |> Macro.to_string(),
        documentation: visibility(entry.doc),
        deprecation: Map.get(entry.metadata, :deprecated),
        documentation_notices: notices(entry.doc)
      }
    end
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  defp spec_string(name, spec) do
    spec |> then(&Code.Typespec.spec_to_quoted(name, &1)) |> Macro.to_string()
  end

  defp fetch_typespecs(module, kind) do
    result =
      case kind do
        :callbacks -> Code.Typespec.fetch_callbacks(module)
        :types -> Code.Typespec.fetch_types(module)
      end

    case result do
      {:ok, entries} ->
        entries

      :error ->
        raise ArgumentError,
              "missing compiled #{kind} for #{inspect(module)}; compile with debug_info: true"
    end
  end

  defp optional_callbacks(module) do
    if function_exported?(module, :behaviour_info, 1) do
      module.behaviour_info(:optional_callbacks)
    else
      []
    end
  end

  defp struct_fields(module) do
    if function_exported?(module, :__struct__, 0) do
      module.__struct__()
      |> Map.keys()
      |> List.delete(:__struct__)
      |> Enum.map(&to_string/1)
      |> Enum.sort()
    else
      nil
    end
  end

  # Default-argument wrappers have no separate EEP-48 documentation entry.
  # Borrow the documented maximum arity, as the ACP shim generator does.
  defp doc_entry(docs, kind, name, arity) do
    case Map.fetch(docs, {kind, name, arity}) do
      {:ok, entry} ->
        entry

      :error ->
        docs
        |> Enum.filter(fn
          {{^kind, ^name, documented_arity}, entry} ->
            documented_arity > arity and
              documented_arity - Map.get(entry.metadata, :defaults, 0) <= arity

          _ ->
            false
        end)
        |> Enum.min_by(fn {{_, _, documented_arity}, _} -> documented_arity end, fn -> nil end)
        |> case do
          {_, entry} -> entry
          nil -> %{doc: :none, metadata: %{}}
        end
    end
  end

  defp visibility(:hidden), do: "hidden"
  defp visibility(:none), do: "none"
  defp visibility(doc) when is_map(doc), do: "documented"

  # Retain the original paragraphs rather than interpreting prose as an
  # accepted API removal. Protocol deprecations also appear in these notices.
  defp notices(doc) when is_map(doc) do
    for {language, text} <- Enum.sort(doc),
        paragraph <- String.split(text, ~r/\n\s*\n/),
        Regex.match?(@notice_pattern, paragraph) do
      %{language: language, text: String.trim(paragraph)}
    end
  end

  defp notices(_), do: []

  defp identifier({name, arity}), do: %{name: to_string(name), arity: arity}

  defp summary(entries) do
    %{
      modules: length(entries),
      documented_modules: Enum.count(entries, &(&1.documentation == "documented")),
      exports: count(entries, :exports),
      functions:
        Enum.sum(Enum.map(entries, &Enum.count(&1.callables, fn c -> c.kind == "function" end))),
      macros:
        Enum.sum(Enum.map(entries, &Enum.count(&1.callables, fn c -> c.kind == "macro" end))),
      callbacks: count(entries, :callbacks),
      types: count(entries, :types),
      structs: Enum.count(entries, &is_list(&1.struct_fields)),
      struct_fields: Enum.sum(Enum.map(entries, &length(&1.struct_fields || []))),
      deprecated_modules: Enum.count(entries, &is_binary(&1.deprecation)),
      deprecated_callables:
        Enum.sum(
          Enum.map(entries, &Enum.count(&1.callables, fn c -> is_binary(c.deprecation) end))
        )
    }
  end

  defp count(entries, field), do: Enum.sum(Enum.map(entries, &length(Map.fetch!(&1, field))))

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp ordered(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
