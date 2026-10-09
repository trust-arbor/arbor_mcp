defmodule Arbor.MCP.Release.APIRetirementAudit do
  @baseline_sha256 "a6a952ef2483f2490c13594e1a44bc4a47f96abc9efa19ab4829984b2234f0a8"

  def run(argv) do
    {opts, [], []} = OptionParser.parse(argv, strict: [complete: :boolean, output: :string])
    root = Path.expand("..", __DIR__)
    baseline = File.read!(Path.join(root, "test/fixtures/api/api_baseline_1_5_plus.json"))
    digest = :crypto.hash(:sha256, baseline) |> Base.encode16(case: :lower)
    if digest != @baseline_sha256, do: raise("Frozen 1.x API baseline changed")

    plan = root |> Path.join("test/fixtures/api/api_migration_plan.json") |> File.read!() |> Jason.decode!()
    modules = plan["removal_modules"]
    callables = plan["removal_callables"] ++ Enum.flat_map(modules, & &1["callables"])
    module_names = Enum.map(modules, &candidate(&1["module"]))
    exports = Map.new(Enum.uniq(Enum.map(callables, &candidate(&1["module"]))), &exports/1)
    {remaining, removed} = Enum.split_with(callables, &present?(&1, exports))
    {remaining_modules, removed_modules} = Enum.split_with(module_names, &compiled?/1)

    types =
      for module <- modules, type <- module["types"] do
        Map.put(type, "module", candidate(module["module"]))
      end

    {remaining_types, removed_types} = Enum.split_with(types, &type_present?/1)
    facade = Map.fetch!(plan, "facade_boundary_cleanup") |> Map.fetch!("removed_signatures")

    remaining_facade =
      Enum.filter(facade, fn entry ->
        {_module, members} = exports(entry["module"])
        MapSet.member?(members, {String.to_atom(entry["name"]), entry["arity"]})
      end)

    if remaining_facade != [], do: raise("Internal exports remain on public facades")

    report = %{
      "scope" => "MCP accepted API retirements only; not the full four-package API comparison",
      "baseline_sha256" => digest,
      "elixir" => System.version(),
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "compiled_removed_callable_count" => length(removed),
      "compiled_removed_module_count" => length(removed_modules),
      "compiled_removed_type_count" => length(removed_types),
      "remaining_callables" => remaining,
      "remaining_modules" => remaining_modules,
      "remaining_types" => remaining_types,
      "facade_boundary_removed_count" => length(facade),
      "remaining_facade_exports" => remaining_facade,
      "complete" => remaining == [] and remaining_modules == [] and remaining_types == []
    }

    validate_checkpoint!(
      opts,
      plan,
      callables,
      modules,
      types,
      removed,
      removed_modules,
      removed_types
    )

    if path = opts[:output], do: File.write!(path, Jason.encode!(report, pretty: true) <> "\n")

    IO.puts(
      "Compiled retirements: #{length(removed)}/#{length(callables)} callables, " <>
        "#{length(removed_modules)}/#{length(modules)} modules, " <>
        "#{length(removed_types)}/#{length(types)} types"
    )
  end

  defp validate_checkpoint!(
         opts,
         plan,
         callables,
         modules,
         types,
         removed,
         removed_modules,
         removed_types
       ) do
    expected =
      if opts[:complete],
        do: length(callables),
        else:
          get_in(plan, ["tools_retirement_checkpoint", "implemented_callable_total"]) ||
            get_in(plan, ["first_retirement_checkpoint", "removed_callable_count"])

    expected_modules = if opts[:complete], do: length(modules), else: 8
    expected_types = length(types)

    if length(removed) != expected or length(removed_modules) != expected_modules or
         length(removed_types) != expected_types do
      raise("Compiled API retirement counts do not match the accepted checkpoint")
    end
  end

  defp candidate(module), do: "Arbor.MCP." <> String.replace_prefix(module, "ExMCP.", "")
  defp module_atom(module), do: String.to_atom("Elixir." <> module)
  defp compiled?(module), do: :code.which(module_atom(module)) != :non_existing

  defp exports(module) do
    case :code.which(module_atom(module)) do
      :non_existing ->
        {module, MapSet.new()}

      path when is_list(path) ->
        {:ok, {_module, [{:exports, exports}]}} = :beam_lib.chunks(path, [:exports])
        {module, MapSet.new(exports)}

      _other ->
        raise("Cannot inspect compiled API module")
    end
  end

  defp present?(entry, exports) do
    signature =
      if entry["kind"] == "macro",
        do: {String.to_atom("MACRO-" <> entry["name"]), entry["arity"] + 1},
        else: {String.to_atom(entry["name"]), entry["arity"]}

    MapSet.member?(Map.fetch!(exports, candidate(entry["module"])), signature)
  end

  defp type_present?(entry) do
    if compiled?(entry["module"]) do
      {:ok, types} = Code.Typespec.fetch_types(module_atom(entry["module"]))

      Enum.any?(types, fn {_kind, {name, _definition, parameters}} ->
        to_string(name) == entry["name"] and length(parameters) == entry["arity"]
      end)
    else
      false
    end
  end
end

Arbor.MCP.Release.APIRetirementAudit.run(System.argv())
