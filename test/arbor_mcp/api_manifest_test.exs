defmodule Arbor.MCP.APIManifestTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.APIManifest

  @fixture_source ~S'''
  defmodule Arbor.MCP.APIManifestTest.DocumentedFixture do
    @moduledoc """
    Documented fixture.

    This module is deprecated and planned for removal in 2.0.
    """
    @moduledoc deprecated: "Use the replacement fixture"

    defstruct [:value, enabled: true]
    @typep internal :: :internal
    @type value :: internal() | String.t()
    @type t :: %__MODULE__{value: value(), enabled: boolean()}
    @opaque token :: binary()
    @callback request(value()) :: {:ok, value()}
    @optional_callbacks request: 1
    @macrocallback inject(term()) :: Macro.t()
    @optional_callbacks inject: 1

    @doc "Deprecated; use replacement/1."
    @deprecated "Use replacement/1"
    def old(value \\ nil), do: value

    @doc false
    def hidden, do: :ok

    @doc "A public macro."
    defmacro sample(value), do: value
  end
  '''

  setup_all do
    root = Path.join(System.tmp_dir!(), "api-manifest-#{System.unique_integer([:positive])}")
    beam_dir = Path.join(root, "beams")
    File.mkdir_p!(beam_dir)
    true = :code.add_patha(String.to_charlist(beam_dir))

    sources = [
      {"lib/documented.ex", @fixture_source},
      {"lib/hidden.ex",
       "defmodule Arbor.MCP.APIManifestTest.HiddenFixture do\n@moduledoc false\ndef hidden, do: :ok\nend"},
      {"dev/tool.ex",
       "defmodule Arbor.MCP.APIManifestTest.ToolFixture do\n@moduledoc false\ndef tool, do: :ok\nend"}
    ]

    compiler_options = Code.compiler_options()
    Code.compiler_options(docs: true, debug_info: true)

    modules =
      try do
        Enum.flat_map(sources, fn {relative, source} ->
          path = Path.join(root, relative)
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, source)

          for {module, beam} <- Code.compile_file(path) do
            File.write!(Path.join(beam_dir, "#{module}.beam"), beam)
            module
          end
        end)
      after
        Code.compiler_options(
          docs: compiler_options.docs,
          debug_info: compiler_options.debug_info
        )
      end

    on_exit(fn ->
      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)

      :code.del_path(String.to_charlist(beam_dir))
      File.rm_rf!(root)
    end)

    %{root: root, modules: modules, beam_dir: beam_dir}
  end

  test "keeps hidden lib APIs and excludes repository tooling", context do
    manifest = build(context)

    assert manifest.summary.modules == 2
    assert manifest.summary.documented_modules == 1
    assert Enum.map(manifest.sources, & &1.path) == ["lib/documented.ex", "lib/hidden.ex"]

    hidden = Enum.find(manifest.modules, &(&1.name == "Arbor.MCP.APIManifestTest.HiddenFixture"))
    assert hidden.documentation == "hidden"
    assert %{name: "hidden", arity: 0} in hidden.exports
  end

  test "captures defaults, macros, optional callbacks, public types and struct fields", context do
    module =
      build(context).modules |> Enum.find(&String.ends_with?(&1.name, ".DocumentedFixture"))

    assert module.struct_fields == ["enabled", "value"]
    assert module.deprecation == "Use the replacement fixture"
    assert Enum.any?(module.documentation_notices, &String.contains?(&1.text, "removal in 2.0"))

    for arity <- [0, 1] do
      callable = Enum.find(module.callables, &(&1.name == "old" and &1.arity == arity))
      assert callable.deprecation == "Use replacement/1"
      assert callable.documentation == "documented"
    end

    assert Enum.any?(
             module.callables,
             &(&1.kind == "macro" and &1.name == "sample" and &1.arity == 1)
           )

    assert %{name: "MACRO-sample", arity: 2} in module.exports

    request = Enum.find(module.callbacks, &(&1.name == "request"))
    assert request.optional
    assert request.definitions == ["request(value()) :: {:ok, value()}"]

    inject = Enum.find(module.callbacks, &(&1.kind == "macrocallback" and &1.name == "inject"))
    assert inject.arity == 1
    assert inject.optional

    assert Enum.map(module.types, &{&1.name, &1.kind}) == [
             {"t", "type"},
             {"token", "opaque"},
             {"value", "type"}
           ]
  end

  test "encoding is independent of input module order and contains no absolute source paths",
       context do
    manifest = build(context)
    encoded = APIManifest.encode(manifest)

    assert encoded ==
             APIManifest.encode(build(%{context | modules: Enum.reverse(context.modules)}))

    assert Jason.decode!(encoded)["schema_version"] == 1
    assert String.ends_with?(encoded, "\n")
    refute encoded =~ context.root
    assert byte_size(manifest.baseline.source_digest) == 64
  end

  test "fails explicitly when a compiled module has no typespec debug information", context do
    path = Path.join(context.root, "lib/stripped.ex")

    File.write!(path, """
    defmodule Arbor.MCP.APIManifestTest.StrippedFixture do
      @moduledoc "Fixture with stripped debug information."
      @type value :: integer()
      def value, do: 1
    end
    """)

    compiler_options = Code.compiler_options()
    Code.compiler_options(docs: true, debug_info: false)

    module =
      try do
        [{module, beam}] = Code.compile_file(path)
        File.write!(Path.join(context.beam_dir, "#{module}.beam"), beam)
        module
      after
        Code.compiler_options(
          docs: compiler_options.docs,
          debug_info: compiler_options.debug_info
        )
      end

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    assert_raise ArgumentError,
                 ~r/missing compiled callbacks for .*StrippedFixture; compile with debug_info: true/,
                 fn -> build(%{context | modules: [module]}) end
  end

  defp build(context) do
    APIManifest.build(context.modules,
      root: context.root,
      application: :fixture,
      version: "1.5.0",
      environment: :test,
      source_ref: "fixture-baseline"
    )
  end
end
