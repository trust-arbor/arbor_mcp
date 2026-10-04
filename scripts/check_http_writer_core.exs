root = Path.expand("..", __DIR__)

paths = [
  "lib/arbor_mcp/runtime/deadline.ex",
  "lib/arbor_mcp/runtime/ref.ex",
  "lib/arbor_mcp/runtime/http_writer_binding.ex",
  "lib/arbor_mcp/runtime/http_write_ticket.ex",
  "lib/arbor_mcp/runtime/http_writer_registry.ex"
]

beam = Path.join(System.tmp_dir!(), "arbor-http-writer-#{System.unique_integer([:positive])}")
File.mkdir_p!(beam)

try do
  {:ok, _, diagnostics} =
    Kernel.ParallelCompiler.compile_to_path(
      Enum.map(paths, &Path.join(root, &1)),
      beam,
      return_diagnostics: true
    )

  warnings? =
    if is_map(diagnostics),
      do: Enum.any?(diagnostics, fn {_, warnings} -> warnings != [] end),
      else: diagnostics != []

  if warnings?, do: raise("HTTP writer core compilation produced warnings")
  ExUnit.start(autorun: false)
  Code.require_file(Path.join(root, "test/arbor_mcp/runtime/http_writer_registry_test.exs"))
  result = ExUnit.run()
  if result.failures != 0, do: System.halt(1)
after
  File.rm_rf!(beam)
end
