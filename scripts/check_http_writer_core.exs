root = Path.expand("..", __DIR__)
build = System.get_env("ARBOR_V2_BUILD") || Path.join(root, "_build")
environment = System.get_env("MIX_ENV") || "test"
Path.wildcard(Path.join([build, environment, "lib/*/ebin"])) |> Enum.each(&Code.append_path/1)

unless Code.ensure_loaded?(Arbor.MCP.Server.Runtime.HTTPWriterProxy) do
  raise "Compile the matching Runtime source with Mix before checking the installed writer core"
end

ExUnit.start(autorun: false)
Code.require_file(Path.join(root, "test/arbor_mcp/runtime/http_writer_registry_test.exs"))
result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
