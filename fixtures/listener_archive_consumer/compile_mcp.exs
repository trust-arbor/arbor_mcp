# Compile the packaged dependency itself with warnings as errors. Ordinary
# `mix deps.compile` explicitly disables that policy for dependencies.
true = Mix.env() == :prod
"cowboy" = System.fetch_env!("LISTENER_ARCHIVE_ADAPTER")
"host" = System.fetch_env!("LISTENER_ARCHIVE_OWNERSHIP")

dependencies = Mix.Dep.load_and_cache()
mcp = Enum.find(dependencies, &(&1.app == :arbor_mcp)) || raise "MCP dependency is missing"
ranch = Enum.find(dependencies, &(&1.app == :ranch)) || raise "Ranch dependency is missing"
expected_source = Path.expand("packages/arbor_mcp")
^expected_source = Path.expand(Keyword.fetch!(mcp.opts, :dest))

case Application.load(:ranch) do
  :ok -> :ok
  {:error, {:already_loaded, :ranch}} -> :ok
end

~c"2.2.0" = Application.spec(:ranch, :vsn)

# Ensure compiler export checks see this consumer's normally resolved Ranch,
# including the changed connection-supervisor initialization arity in 2.x.
for module <- [:ranch_server, :ranch_conns_sup] do
  {:module, ^module} = Code.ensure_loaded(module)

  expected_beam =
    ranch.opts
    |> Keyword.fetch!(:build)
    |> Path.join("ebin/#{module}.beam")
    |> Path.expand()

  ^expected_beam = module |> :code.which() |> to_string() |> Path.expand()
end

true = function_exported?(:ranch_server, :set_new_listener_opts, 5)
false = function_exported?(:ranch_conns_sup, :init, 4)

# Stay in the selected dependency graph and its normal build paths. A fresh
# task state plus --force prevents an earlier successful dependency compile
# from satisfying this project-owned warnings-as-errors check without work.
:ok = Mix.Task.clear()

{:ok, _diagnostics} =
  Mix.Dep.in_dependency(mcp, fn _project ->
    Mix.Task.run("compile", [
      "--force",
      "--warnings-as-errors",
      "--no-deps-check",
      "--no-prune-code-paths"
    ])
  end)

IO.puts("Packaged arbor_mcp compiled with warnings as errors against host Ranch 2.2.0")
