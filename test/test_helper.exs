# Support files are compiled via elixirc_paths(:test) in mix.exs
# No need to explicitly require them here as they're already available

# Configure logger — default :info so capture_log shows useful output on failures.
# Override: LOG_LEVEL=debug mix test
log_level =
  case System.get_env("LOG_LEVEL") do
    nil -> :info
    level -> String.to_existing_atom(level)
  end

Logger.configure(level: log_level)

# Import test helpers after compilation (in ExUnit.start callback)
ExUnit.after_suite(fn _results ->
  # Safety net: cleanup any truly orphaned test processes.
  # Suppress logs since this runs outside test capture scope.
  Logger.configure(level: :error)
  Arbor.MCP.TestSupport.cleanup_orphans()
  :ok
end)

# Start required applications for HTTP tests
{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Application.ensure_all_started(:ssl)
{:ok, _} = Application.ensure_all_started(:ranch)
{:ok, _} = Application.ensure_all_started(:cowboy)

# Load the OS trust store once, with a deadline. Every HTTPS code path calls
# :public_key.cacerts_get/0, which caches the store per VM only after a
# successful load. On macOS that load shells out to `/usr/bin/security` and
# waits with no timeout, and the tool can stall while the session is locked or
# asleep. Without this, each HTTPS test then times out separately after 60s.
case Task.yield(Task.async(&:public_key.cacerts_get/0), 15_000) do
  {:ok, _cacerts} ->
    :ok

  _stalled ->
    raise """
    loading the OS CA certificate store did not finish within 15s.
    On macOS this usually means `/usr/bin/security` is stalled on the
    keychain (for example while the screen is locked). Unlock the session
    and rerun the tests.
    """
end

# Start test consent handler agent
{:ok, _} = Arbor.MCP.ConsentHandler.Test.start_link()

# Start ValidatorRegistry for content validation tests
{:ok, _} =
  Arbor.MCP.Content.ValidatorRegistry.start_link(name: Arbor.MCP.Content.ValidatorRegistry)

# Ensure compliance version modules are generated
Code.ensure_loaded(Arbor.MCP.Compliance.VersionGenerator)

# Enable test mode for SSE handlers to prevent blocking in tests
Application.put_env(:arbor_mcp, :test_mode, true)

# Keep the production validation deadline tight while allowing for scheduler
# contention from highly concurrent test runs. Deadline behavior is tested with
# explicit per-call overrides in SchemaPolicyTest.
Application.put_env(:arbor_mcp, :json_schema, validation_timeout_ms: 1_000)

# Don't stop the application - let tests that need it have access to it
# Individual tests can stop/restart if needed for isolation
# Application.stop(:arbor_mcp)

# Ensure the application is started for tests that need it
{:ok, _} = Application.ensure_all_started(:arbor_mcp)

# Safe cleanup: Only handle network resources that might block new tests
# Application processes are handled by OTP supervision - don't force kill them
Arbor.MCP.TestSupport.safe_cleanup_network_resources()

# Configure default exclusions for fast local development
# These can be overridden with --include flags
default_exclusions = [
  # Tests requiring external services
  integration: true,
  external: true,
  live_server: true,

  # Performance and slow tests
  slow: true,
  performance: true,
  stress: true,

  # Work in progress
  wip: true,
  skip: true,

  # Tests requiring specific setup
  requires_http: true,
  requires_beam: true,
  requires_bypass: true,

  # Cross-language interop tests (require Node.js + npm)
  interop: true
]

# Print exclusion summary
excluded_tags =
  default_exclusions
  |> Enum.filter(fn {_tag, excluded} -> excluded end)
  |> Enum.map(fn {tag, _} -> tag end)

if length(excluded_tags) > 0 do
  IO.puts("\n⚠️  Test tags excluded by default: #{inspect(excluded_tags)}")
  IO.puts("   Use --include <tag> to run specific test categories\n")
end

ExUnit.configure(exclude: default_exclusions)

ExUnit.start(capture_log: true)

# No mocking library is used. Tests rely on lightweight in-process test
# transports (`transport: :test`), hand-written stub modules injected via
# options, and the helpers in `test/support/` plus `Arbor.MCP.Testing.*`.
