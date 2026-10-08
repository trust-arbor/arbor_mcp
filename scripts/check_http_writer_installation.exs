build = System.fetch_env!("ARBOR_V2_BUILD")
Path.wildcard(Path.join(build, "test/lib/*/ebin")) |> Enum.each(&Code.append_path/1)
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:crypto)
ExUnit.start(autorun: false)

paths =
  if "--retained" in System.argv() do
    [
      "test/arbor_mcp/runtime/runtime_test.exs",
      "test/arbor_mcp/runtime/initialization_claim_test.exs",
      "test/arbor_mcp/runtime/deadline_budget_test.exs",
      "test/arbor_mcp/runtime/initialization_test.exs"
    ]
  else
    [
      "test/arbor_mcp/runtime/http_writer_registry_test.exs",
      "test/arbor_mcp/runtime/http_writer_installation_test.exs"
    ]
  end

Enum.each(paths, &Code.require_file/1)
result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
