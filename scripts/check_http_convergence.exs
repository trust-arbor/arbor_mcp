build = System.fetch_env!("ARBOR_V2_BUILD")
Path.wildcard(Path.join(build, "test/lib/*/ebin")) |> Enum.each(&Code.append_path/1)
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:crypto)
Application.load(:plug)
Application.ensure_all_started(:mime)
ExUnit.start(autorun: false)
Code.require_file("test/arbor_mcp/runtime/http_convergence_test.exs")
Code.require_file("test/arbor_mcp/runtime/http_cancellation_test.exs")
Code.require_file("test/arbor_mcp/runtime/admission_step_lifetime_test.exs")

if System.get_env("ARBOR_HTTP_WIRE") == "1",
  do: Code.require_file("test/arbor_mcp/runtime/http_convergence_wire_test.exs")

result = ExUnit.run()
if result.failures != 0, do: System.halt(1)
