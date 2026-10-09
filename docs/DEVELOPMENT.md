# ArborMCP Development Guide

This guide covers developing, testing, and contributing to the MCP package.
The v2 RC is published; use the
[v2 roadmap](ROADMAP.md)
for release scope and qualification status.

`ARBOR_RPC_PATH` selects the repository root of a local
[ArborRPC checkout](https://github.com/trust-arbor/arbor_rpc). `ARBOR_V2_DEPS` can reuse an
existing source cache during split QA, while `ARBOR_V2_BUILD` and `ARBOR_V2_LOCK`
select isolated build and lock paths. Package consumer checks must also run with
these overrides unset and use the built release artifacts.

## Table of Contents

1. [Development Setup](#development-setup)
2. [Code Quality Tools](#code-quality-tools)
3. [Testing Strategy](#testing-strategy)
4. [Test Process Cleanup](#test-process-cleanup)
5. [Contributing](#contributing)
6. [Release Process](#release-process)

## Development Setup

### Prerequisites

- Elixir 1.17+ (enforced by `mix.exs`)
- Erlang/OTP 27–29 (the current CI matrix)
- C17 compiler on macOS/Linux (the ArborRPC source dependency builds a native helper)
- Git with hooks support

The [CI policy](https://github.com/trust-arbor/arbor_mcp/blob/master/.github/BEAM_CI.md) records the tested Elixir 1.17–1.20 /
OTP 27–29 pairs and latest-version lanes; not every cross-product is supported.

### Initial Setup

```bash
# Clone the repository
git clone https://github.com/trust-arbor/arbor_mcp.git
cd arbor_mcp

# Until arbor_rpc is published, select its checkout explicitly.
git clone https://github.com/trust-arbor/arbor_rpc.git ../arbor_rpc
export ARBOR_RPC_PATH="$(cd ../arbor_rpc && pwd)"

# Install dependencies
mix deps.get

# Install git hooks
mix git_hooks.install

# Verify setup
mix compile --warnings-as-errors && mix credo
```

The default `master` branch contains ArborMCP v2. The maintained ExMCP 1.x
line is `codex/maintenance-1.x`. Keep a lockfile for repeatable local dependency resolution.

### Essential Development Commands

```bash
# Dependencies and compilation
mix deps.get          # Install dependencies
mix compile           # Compile the project
mix compile --warnings-as-errors  # Compile with strict warnings

# Code quality
mix format            # Format code (required before committing)
mix credo             # Static code analysis
mix dialyzer          # Type checking (run after significant changes)
mix sobelow --skip    # Security analysis

# Testing
mix test              # Default suite; integration/external/slow tags are excluded
mix test test/arbor_mcp/client_beam_transport_test.exs  # Run specific test file
mix coveralls.html    # Generate coverage report
MIX_ENV=test mix compile              # Compile for test environment

# Documentation
mix docs              # Generate docs; undefined references fail the build
iex -S mix            # Start interactive shell with project loaded

# Official MCP conformance
./scripts/conformance.sh modern # Complete MCP 2026-07-28 client + server suites
./scripts/conformance.sh server # Published legacy/core server suite
./scripts/conformance.sh client # Published legacy/core client suite

# Emulate the scheduled upstream check with a specific newly published harness.
CONFORMANCE_ALPHA_VERSION=0.2.0-alpha.11 ./scripts/conformance.sh modern

# Broader legacy/draft report; this aggregate command is intentionally non-gating.
./scripts/conformance.sh all-versions

# Official TypeScript SDK interop. test/interop/package-lock.json pins the
# legacy SDK separately from @modelcontextprotocol/{client,server,node}@2.0.0
# (Node.js 20+ for SDK interop; Node.js 22+ for the modern conformance harness).
mix test --only interop_ts_client
mix test --only interop_ex_mcp_client
mix test --only interop_modern_ts_client
mix test --only interop_modern_ex_mcp_client
mix test --only interop_modern_ts_http_client
mix test --only interop_modern_ex_mcp_http_client

# After doc or example changes, re-verify key snippets and the getting-started demo:
#   elixir examples/getting_started/demo_client.exs
#   mix examples.getting_started   # fast alias (see examples/README.md)

```

## Code Quality Tools

ArborMCP uses a comprehensive set of code quality tools to ensure maintainable, reliable code:

### Formatter
- **Tool**: Elixir's built-in code formatter
- **Usage**: `mix format`
- **Purpose**: Consistent code formatting across the project
- **Required**: Yes, before every commit

### Credo
- **Tool**: Static code analysis
- **Usage**: `mix credo` or `mix credo --strict`
- **Purpose**: Code readability, consistency, and best practices
- **Configuration**: See `.credo.exs`
- **Thresholds**: 
  - Cyclomatic complexity max: 11
  - Function length max: reasonable (enforced by review)

### Dialyzer
- **Tool**: Type checking and static analysis
- **Usage**: `mix dialyzer`
- **Purpose**: Find type inconsistencies and potential runtime errors
- **When to run**: After significant changes or before releases
- **PLT location**: `priv/plts/` (gitignored)

### Sobelow
- **Tool**: Security analysis
- **Usage**: `mix sobelow --skip`
- **Purpose**: Identify security vulnerabilities
- **Focus**: Input validation, SQL injection, XSS prevention

### ExCoveralls
- **Tool**: Test coverage analysis
- **Usage**: `mix coveralls.html`
- **Purpose**: Ensure comprehensive test coverage
- **Target**: Aim for >80% coverage on core modules

### Git Hooks
- **Pre-commit**: Checks formatting, compilation, Credo, Dialyzer and staged skip tags
- **Pre-push**: No tasks are currently configured; run relevant tests before pushing
- **Setup**: `mix git_hooks.install`; the development config also enables auto-install
- **Source of truth**: `config/config.exs`

## Testing Strategy

ArborMCP uses a sophisticated test tagging strategy for efficient test execution across different scenarios.

### Test Categories

#### Core Test Suites

```bash
# Unit-tagged tests
mix test.suite unit

# MCP specification compliance tests
mix test.suite compliance

# Integration tests with real components
mix test.suite integration

# CI-appropriate tests (excludes slow tests)
mix test.suite ci

# All tests including slow ones
mix test.suite all
```

#### Transport-Specific Tests

```bash
# BEAM transport tests
mix test --only beam

# HTTP transport tests (Streamable HTTP with SSE)
mix test --only http

# stdio transport tests
mix test --only stdio
```

#### Feature-Specific Tests

```bash
# Security and authentication tests
mix test --only security

# Progress notification tests
mix test --only progress

# Resource management tests
mix test --only resources

# Performance and benchmarking tests
mix test --only performance
```

#### Development Workflows

```bash
# Include normally excluded slow tests
mix test --include slow

# Skip integration tests for faster feedback
mix test --exclude integration

# Skip external dependencies
mix test --exclude external

# List all available tags
mix test.tags
```

### Test Organization

Tests follow a clear structure mirroring the source code:

```
test/
├── arbor_mcp/                 # Core module tests
│   ├── client/               # Client implementation tests
│   ├── server/               # Server implementation tests
│   ├── transport/            # Transport layer tests
│   └── compliance/           # MCP revision/compliance tests
├── interop/                  # TypeScript MCP SDK fixtures
├── conformance/              # External harness entry points
└── support/                  # Test helpers and utilities
```

### Test Patterns

#### Unit Tests
- Test individual functions and modules in isolation
- Use mocks for external dependencies
- Fast execution (typically <100ms per test)
- Tagged with `:unit` (default)

#### Integration Tests
- Test component interactions
- May use real external services or subprocess
- Slower execution
- Tagged with `:integration`

#### Compliance Tests
- Verify MCP specification adherence
- Test protocol message formats
- Cross-version compatibility
- Tagged with `:compliance`

#### Property-Based Tests
- Used for protocol encoding/decoding
- Input validation testing
- Edge case discovery
- Uses PropCheck library

#### ACP and adapter tests

ACP protocol, native agent and vendor golden transcript tests belong to
[ArborACP](https://github.com/trust-arbor/arbor_acp). They are not part of the MCP
package or its CI jobs. Shared JSON-RPC and framing contracts are tested in the
`arbor_rpc` package; MCP integration tests still check their use at each MCP
transport boundary.

### Writing Tests

Follow these patterns when writing tests:

```elixir
defmodule Arbor.MCP.SomeModuleTest do
  use ExUnit.Case, async: true  # Use async: false for shared state
  
  # Add appropriate tags
  @moduletag :unit
  @moduletag :some_feature
  
  # Use descriptive test names
  describe "function_name/2" do
    test "handles valid input correctly" do
      # Arrange
      input = %{valid: "data"}
      
      # Act
      result = SomeModule.function_name(input, [])
      
      # Assert
      assert {:ok, expected} = result
    end
    
    test "returns error for invalid input" do
      # Test error conditions
      assert {:error, _reason} = SomeModule.function_name(nil, [])
    end
  end
end
```

## Test Process Cleanup

Use ExUnit supervision (`start_supervised!/1`) for test-owned server/client
fixtures and distinct names or ephemeral ports for independent tests. The
normal test support reports occupied ports; a port number alone does not prove
that its listener belongs to the test run.

To investigate a collision without stopping anything:

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
mix test.cleanup --dry-run --verbose
```

The legacy cleanup task can stop matching listeners/processes and target common
test ports. Review its dry-run output before using it in a shared development
session. Stop only processes that you started and can identify; broad `pkill`
patterns can terminate unrelated applications. Runtime-owned resources should
normally be reclaimed through their supervising test or Runtime shutdown.

## Contributing

### Contribution Workflow

1. **Fork the repository** on GitHub
2. **Create a feature branch** from the default branch:
   ```bash
   git checkout master
   git checkout -b codex/your-feature-name
   ```
3. **Make your changes** following the coding standards
4. **Run quality checks**:
   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix credo
   mix test
   mix docs --warnings-as-errors
   ```
5. **Commit your changes** with conventional commit messages:
   ```bash
   git commit -m "feat: add new transport option"
   git commit -m "fix: resolve connection timeout issue"
   git commit -m "docs: update configuration examples"
   ```
6. **Push to your fork** and create a pull request

### Code Standards

#### Formatting and Style
- **Always run `mix format`** before committing
- Follow Elixir community conventions
- Use descriptive variable and function names
- Add appropriate documentation to public functions

#### Documentation
- Add `@doc` to all public functions
- Include examples in documentation when helpful
- Update guides when adding new features
- Ensure examples work with current codebase

#### Testing
- Write tests for all new functionality
- Maintain or improve test coverage
- Add appropriate test tags
- Test both success and error cases

#### Git Commit Messages
Follow [Conventional Commits](https://conventionalcommits.org/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Types:
- `feat`: New features
- `fix`: Bug fixes
- `docs`: Documentation changes
- `test`: Test additions or modifications
- `refactor`: Code refactoring
- `perf`: Performance improvements
- `chore`: Maintenance tasks

### Pull Request Guidelines

#### Before Submitting
- [ ] All tests pass locally
- [ ] Code is formatted with `mix format`
- [ ] No credo warnings
- [ ] Documentation is updated if needed
- [ ] CHANGELOG.md is updated for user-facing changes

#### PR Description
Include:
- Clear description of the change
- Motivation and context
- Breaking changes (if any)
- Testing approach
- Related issues

### Code Review Process

1. **Automated checks** must pass (CI, formatting, tests)
2. **Manual review** by maintainers
3. **Feedback incorporation** and iteration
4. **Final approval** and merge

## Release Process

The [v2 release plan](RELEASING.md)
records the current package split, release order and qualification gates. The
protocol transition checklist below is the historical 1.0 checklist and does not
replace the v2 gates. A target date never waives a failing release gate.

### Version Management

ArborMCP follows [Semantic Versioning](https://semver.org/):

- **Patch** (`0.6.1`): Bug fixes, documentation updates
- **Minor** (`0.7.0`): New features, non-breaking changes
- **Major** (`1.0.0`): Breaking changes

### Current qualification

Use the [release checklist](RELEASING.md) for source/archive association,
protocol coverage, dependency contracts, downstream/vendor testing and the
accepted continuous 48-hour soak. Preserve exact source and lockfile identities
for each result. The historical 1.0 seven-day rollout is recorded in Git history.

### Hotfix Process

For critical bugs in production releases:

1. Create hotfix branch from release tag
2. Apply minimal fix
3. Update version (patch bump)
4. Release immediately
5. Merge back to master

## Getting Help

### Development Questions
- **GitHub Discussions**: For general development questions
- **GitHub Issues**: For bug reports and feature requests
- **Code Review**: In pull requests

### Documentation
- **This guide**: Development setup and processes
- **[User Guide](guides/USER_GUIDE.md)**: Feature usage and examples  
- **[Architecture Guide](ARCHITECTURE.md)**: Internal design decisions
- **[MCP 2026-07-28 Migration Plan](https://github.com/trust-arbor/arbor_mcp/blob/6c32d32de623962cef0322b2763068c2965980b6/docs/MCP_2026_07_28_MIGRATION_PLAN.md)**: Release gates and implementation record
- **[MCP Coverage Matrix](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md)**: Protocol-by-protocol test evidence
- **[rc.5 to 1.0 API Diff](https://github.com/trust-arbor/arbor_mcp/blob/6c32d32de623962cef0322b2763068c2965980b6/docs/API_DIFF_RC5_TO_1_0.md)**: Public compatibility audit
- **[Published 1.x API Docs](https://hexdocs.pm/ex_mcp)**: Previous package reference; v2 documentation is generated with `mix docs` during development

### Community
- **Elixir Forum**: For general Elixir questions
- **ArborMCP Community**: Growing community of contributors and users

---

Thank you for contributing to ArborMCP! Your contributions help make MCP implementation in Elixir more robust and accessible to the community.
