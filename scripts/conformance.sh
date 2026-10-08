#!/usr/bin/env bash
# Run MCP conformance tests against Arbor.MCP.
# Uses the official modelcontextprotocol/conformance framework.
#
# Usage:
#   ./scripts/conformance.sh                    # Run both client and server with the published legacy/core harness
#   ./scripts/conformance.sh server             # Server tests only
#   ./scripts/conformance.sh client             # Client tests only
#   ./scripts/conformance.sh server <scenario>  # Single server scenario
#   ./scripts/conformance.sh client <scenario>  # Single client scenario
#   ./scripts/conformance.sh all-versions       # Test ALL protocol versions
#   ./scripts/conformance.sh modern             # Gating MCP 2026-07-28 run
#   ./scripts/conformance.sh draft-alpha        # Non-gating future-draft exploration
#
# Environment variables:
#   CONFORMANCE_SPEC_VERSION  — Test a specific version (e.g., 2025-06-18)
#   CONFORMANCE_PACKAGE_VERSION — Stable conformance package version (default: 0.1.16)
#   CONFORMANCE_ALPHA_VERSION   — Alpha conformance package version (default: 0.2.0-alpha.11)
#   CONFORMANCE_PORT          — Server port (default: 3099)
#   CONFORMANCE_TIMEOUT       — Client timeout in ms (default: 120000)
#   CONFORMANCE_START_TIMEOUT_SECONDS — Cold server startup timeout (default: 120)
#   CONFORMANCE_MIX_ENV       — Mix environment for compiled clients (default: dev)
#
# Modern/draft alpha harnesses require Node.js 22 or newer (`fs.globSync`).
#
# Results saved to: tmp/conformance_output.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFORMANCE_PACKAGE_VERSION="${CONFORMANCE_PACKAGE_VERSION:-0.1.16}"
CONFORMANCE="npx @modelcontextprotocol/conformance@$CONFORMANCE_PACKAGE_VERSION"
SERVER_PORT="${CONFORMANCE_PORT:-3099}"
SERVER_SCRIPT="$PROJECT_DIR/test/conformance/server.exs"
CLIENT_SCRIPT="$PROJECT_DIR/test/conformance/client.exs"
OUTPUT_FILE="$PROJECT_DIR/tmp/conformance_output.txt"
BASELINE_FILE="$PROJECT_DIR/test/conformance/expected-failures.yml"
TIMEOUT="${CONFORMANCE_TIMEOUT:-120000}"
START_TIMEOUT_SECONDS="${CONFORMANCE_START_TIMEOUT_SECONDS:-120}"
SPEC_VERSION="${CONFORMANCE_SPEC_VERSION:-}"

mkdir -p "$PROJECT_DIR/tmp"

cd "$PROJECT_DIR"

assert_server_port_available() {
  if command -v lsof >/dev/null 2>&1 &&
     lsof -ti tcp:"$SERVER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Conformance port $SERVER_PORT is occupied; choose CONFORMANCE_PORT."
    return 1
  fi
}

start_server() {
  assert_server_port_available || return 1

  echo "Starting Arbor.MCP server on port $SERVER_PORT..."
  : >"$PROJECT_DIR/tmp/conformance_server.log"
  elixir "$SERVER_SCRIPT" "$SERVER_PORT" >"$PROJECT_DIR/tmp/conformance_server.log" 2>&1 &
  SERVER_PID=$!

  echo "Waiting for server (pid $SERVER_PID)..."
  local i
  local attempts=$((START_TIMEOUT_SECONDS * 10))
  for i in $(seq 1 "$attempts"); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "Server process exited early!"
      tail -50 "$PROJECT_DIR/tmp/conformance_server.log" || true
      return 1
    fi
    if grep -Fq "Server ready on http://localhost:$SERVER_PORT/mcp" "$PROJECT_DIR/tmp/conformance_server.log" &&
       curl -s -o /dev/null -w '' --max-time 1 "http://127.0.0.1:$SERVER_PORT/mcp" 2>/dev/null; then
      echo "Server ready."
      return 0
    fi
    sleep 0.1
  done
  echo "Server failed to start within ${START_TIMEOUT_SECONDS}s!"
  tail -50 "$PROJECT_DIR/tmp/conformance_server.log" || true
  stop_server
  return 1
}

stop_server() {
  if [ -n "${SERVER_PID:-}" ]; then
    # This PID is the exact child launched above, retained until wait reaps it.
    kill "$SERVER_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 100); do
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

# Failed harness runs and interrupts still retire this invocation's own server.
trap stop_server EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_server_tests() {
  local scenario="${1:-}"
  local version="${2:-$SPEC_VERSION}"
  local suite="${3:-active}"
  echo "=== Server Conformance Tests${version:+ (spec $version)} ==="
  echo ""

  start_server || return 1

  local args="server --url http://localhost:$SERVER_PORT/mcp --verbose"
  if [ -n "$scenario" ]; then
    args="$args --scenario $scenario"
  else
    args="$args --suite $suite"
  fi
  if [ -n "$version" ]; then
    args="$args --spec-version $version"
  fi
  if [ -f "$BASELINE_FILE" ]; then
    args="$args --expected-failures $BASELINE_FILE"
  fi

  echo "Running: $CONFORMANCE $args"
  echo ""
  $CONFORMANCE $args 2>&1 | tee -a "$OUTPUT_FILE"
  local exit_code=${PIPESTATUS[0]}

  stop_server
  return $exit_code
}

run_client_tests() {
  local scenario="${1:-}"
  local version="${2:-$SPEC_VERSION}"
  local suite="${3:-core}"
  local target="suite $suite"
  if [ -n "$scenario" ]; then
    target="scenario $scenario"
  fi
  echo "=== Client Conformance Tests${version:+ (spec $version)} ($target) ==="
  echo ""

  # Compile once before the harness launches its scenarios in parallel, then
  # run the clients directly from the application code path. Entering Mix in
  # every client would serialize them on the shared build lock and can make
  # timing-sensitive mock authorization servers expire before discovery.
  local conformance_mix_env="${CONFORMANCE_MIX_ENV:-dev}"
  MIX_ENV="$conformance_mix_env" mix compile --quiet

  local default_client_command="ERL_LIBS='$PROJECT_DIR/_build/$conformance_mix_env/lib' elixir '$CLIENT_SCRIPT'"
  local client_command="${CONFORMANCE_CLIENT_COMMAND:-$default_client_command}"
  local args=(client --command "$client_command" --timeout "$TIMEOUT" --verbose)
  if [ -n "$scenario" ]; then
    args+=(--scenario "$scenario")
  else
    args+=(--suite "$suite")
  fi
  if [ -n "$version" ]; then
    args+=(--spec-version "$version")
  fi
  if [ -f "$BASELINE_FILE" ]; then
    args+=(--expected-failures "$BASELINE_FILE")
  fi

  echo "Running: $CONFORMANCE ${args[*]}"
  echo ""
  # CONFORMANCE intentionally contains the `npx` executable and its pinned
  # package argument, so leave that prefix split while preserving every
  # harness argument (especially the full client command) as one array item.
  # shellcheck disable=SC2086
  $CONFORMANCE "${args[@]}" 2>&1 | tee -a "$OUTPUT_FILE"
  return ${PIPESTATUS[0]}
}

run_all_versions() {
  # All spec versions the conformance framework supports (newest first).
  # 2024-11-05 is not a valid spec-version in the framework.
  # We also test draft and extension scenarios.
  local versions=("2025-11-25" "2025-06-18" "2025-03-26" "draft" "extension")
  local total_passed=0
  local total_failed=0

  echo "========================================" | tee -a "$OUTPUT_FILE"
  echo "Running conformance for ALL protocol versions" | tee -a "$OUTPUT_FILE"
  echo "========================================" | tee -a "$OUTPUT_FILE"
  echo ""

  for version in "${versions[@]}"; do
    echo "" | tee -a "$OUTPUT_FILE"
    echo "╔══════════════════════════════════════╗" | tee -a "$OUTPUT_FILE"
    echo "║  Protocol Version: $version        ║" | tee -a "$OUTPUT_FILE"
    echo "╚══════════════════════════════════════╝" | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"

    # Server tests for this version
    run_server_tests "" "$version" || true

    # Client tests for this version.
    run_client_tests "" "$version" || true

    # The official suite has no core scenarios for 2025-03-26, but it does
    # include auth backcompat scenarios for that version. The auth suite
    # selector currently returns zero, so run the scenarios by name.
    if [ "$version" = "2025-03-26" ]; then
      run_client_tests "auth/2025-03-26-oauth-metadata-backcompat" "$version" || true
      run_client_tests "auth/2025-03-26-oauth-endpoint-fallback" "$version" || true
    fi
  done

  echo ""
  echo "========================================" | tee -a "$OUTPUT_FILE"
  echo "All-versions conformance run complete." | tee -a "$OUTPUT_FILE"
  echo "========================================" | tee -a "$OUTPUT_FILE"
}

run_draft_alpha() {
  CONFORMANCE_PACKAGE_VERSION="${CONFORMANCE_ALPHA_VERSION:-0.2.0-alpha.11}"
  CONFORMANCE="npx @modelcontextprotocol/conformance@$CONFORMANCE_PACKAGE_VERSION"
  SPEC_VERSION="${CONFORMANCE_SPEC_VERSION:-draft}"

  echo "========================================" | tee -a "$OUTPUT_FILE"
  echo "Running non-gating draft conformance with $CONFORMANCE" | tee -a "$OUTPUT_FILE"
  echo "========================================" | tee -a "$OUTPUT_FILE"

  run_server_tests "" "$SPEC_VERSION" || true
  run_client_tests "" "$SPEC_VERSION" || true

  echo "Draft alpha conformance run complete (non-gating)." | tee -a "$OUTPUT_FILE"
}

require_modern_node() {
  if ! command -v node >/dev/null 2>&1; then
    echo "Modern conformance requires Node.js 22 or newer; node was not found." | tee -a "$OUTPUT_FILE"
    return 1
  fi

  local node_major
  node_major=$(node -p 'Number(process.versions.node.split(".")[0])')

  if [ "$node_major" -lt 22 ]; then
    echo "Modern conformance requires Node.js 22 or newer (found $(node --version))." | tee -a "$OUTPUT_FILE"
    return 1
  fi
}

run_modern() {
  # The modern harness launches client scenarios in parallel. The test
  # environment starts PropCheck in every VM, and those VMs would contend for
  # its shared CounterStrike DETS file. Conformance exercises the packaged
  # runtime, so exclude test-only dependencies unless explicitly overridden.
  export MIX_ENV="${CONFORMANCE_MIX_ENV:-dev}"
  CONFORMANCE_PACKAGE_VERSION="${CONFORMANCE_ALPHA_VERSION:-0.2.0-alpha.11}"
  CONFORMANCE="npx @modelcontextprotocol/conformance@$CONFORMANCE_PACKAGE_VERSION"
  SPEC_VERSION="2026-07-28"
  local exit_code=0

  echo "========================================" | tee -a "$OUTPUT_FILE"
  echo "Gating MCP $SPEC_VERSION conformance with $CONFORMANCE" | tee -a "$OUTPUT_FILE"
  echo "========================================" | tee -a "$OUTPUT_FILE"

  require_modern_node || return 1

  run_server_tests "" "$SPEC_VERSION" "all" || exit_code=1
  run_client_tests "" "$SPEC_VERSION" "all" || exit_code=1

  return "$exit_code"
}

# Clear output file
> "$OUTPUT_FILE"
echo "MCP Conformance Test Run — $(date)" >> "$OUTPUT_FILE"
echo "========================================" >> "$OUTPUT_FILE"

MODE="${1:-all}"
SCENARIO="${2:-}"
EXIT_CODE=0

case "$MODE" in
  server)
    run_server_tests "$SCENARIO" || EXIT_CODE=$?
    ;;
  client)
    run_client_tests "$SCENARIO" || EXIT_CODE=$?
    ;;
  all)
    echo "Running server tests..." >> "$OUTPUT_FILE"
    run_server_tests "$SCENARIO" || EXIT_CODE=1
    echo "" >> "$OUTPUT_FILE"
    echo "Running client tests..." >> "$OUTPUT_FILE"
    run_client_tests "$SCENARIO" || EXIT_CODE=1
    ;;
  all-versions)
    run_all_versions
    ;;
  draft-alpha)
    run_draft_alpha
    ;;
  modern)
    run_modern || EXIT_CODE=$?
    ;;
  *)
    echo "Usage: $0 [server|client|all|all-versions|draft-alpha|modern] [scenario]"
    echo ""
    echo "Modes:"
    echo "  server        Run server conformance tests"
    echo "  client        Run client conformance tests"
    echo "  all           Run both (default)"
    echo "  all-versions  Test conformance-supported versions through 2025-11-25"
    echo "  draft-alpha   Non-gating draft run using the alpha conformance package"
    echo "  modern        Gating server+client run for MCP 2026-07-28"
    echo ""
    echo "Environment:"
    echo "  CONFORMANCE_SPEC_VERSION=2025-06-18  Test a specific version"
    echo "  CONFORMANCE_PACKAGE_VERSION=0.1.16   Pin stable conformance package"
    echo "  CONFORMANCE_ALPHA_VERSION=0.2.0-alpha.11 Override alpha package"
    echo "  CONFORMANCE_START_TIMEOUT_SECONDS=120 Override cold server startup timeout"
    echo "  CONFORMANCE_MIX_ENV=dev               Override compiled-client Mix environment"
    exit 1
    ;;
esac

echo ""
echo "--- Results saved to $OUTPUT_FILE ---"
exit "$EXIT_CODE"
