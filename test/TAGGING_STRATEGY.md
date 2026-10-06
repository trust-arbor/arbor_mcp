# ArborMCP Test Tagging Strategy

This document describes the test tagging strategy for ArborMCP, which enables running specific test suites and managing test execution efficiently.

## Overview

Tests are tagged to categorize them by:
- Purpose (unit, integration, compliance)
- Requirements (external services, specific transports)
- Characteristics (slow, flaky, performance)
- Features (specific MCP functionality)

## Tag Categories

### Test Types

- **`:unit`** - Fast unit tests with mocked dependencies
- **`:integration`** - Tests with real components/transports
- **`:compliance`** - MCP specification compliance tests
- **`:security`** - Security-related tests
- **`:performance`** - Performance benchmarks and stress tests

### Requirements

- **`:requires_http`** - Tests requiring HTTP server
- **`:requires_stdio`** - Tests requiring stdio transport
- **`:requires_beam`** - Tests requiring BEAM transport
- **`:external`** - Tests requiring external services

### Characteristics

- **`:slow`** - Tests that take significant time (>1s)
- **`:stress`** - Stress tests with high load
- **`:flaky`** - Tests that may fail intermittently
- **`:capture_log`** - Tests that capture log output

### Transport-Specific

- **`:transport`** - General transport tests
- **`:stdio`** - stdio transport specific tests
- **`:http`** - Streamable HTTP transport tests
- **`:beam`** - BEAM/Erlang process transport tests

### Feature-Specific

- **`:protocol`** - Protocol-level tests
- **`:batch`** - Batch request tests
- **`:progress`** - Progress notification tests
- **`:cancellation`** - Request cancellation tests
- **`:roots`** - Roots functionality tests
- **`:resources`** - Resource management tests
- **`:tools`** - Tools functionality tests
- **`:prompts`** - Prompts functionality tests
- **`:logging`** - Logging functionality tests
- **`:completion`** - Completion functionality tests

### Development

- **`:wip`** - Work in progress tests
- **`:skip`** - Tests to skip (failing/incomplete)
- **`:manual_only`** - Tests requiring manual intervention

## Usage

### Running Specific Tags

```bash
# Run only compliance tests
mix test --only compliance

# Run unit tests (exclude integration tests)
mix test --exclude integration

# Include slow tests (normally excluded)
mix test --include slow

# Run multiple tags
mix test --only compliance --include slow
```

### Using Test Suites

```bash
# Available suites
mix test.suite unit        # Fast unit tests only
mix test.suite compliance  # MCP compliance tests
mix test.suite integration # Integration tests
mix test.suite transport   # Transport-specific tests
mix test.suite security    # Security tests
mix test.suite performance # Performance tests
mix test.suite all        # All tests
mix test.suite ci         # CI-appropriate tests

# With options
mix test.suite compliance --cover
mix test.suite unit --trace
```

### Listing Tags

```bash
# Show all available tags and descriptions
mix test.tags
```

## Tagging Guidelines

### When to Use Module Tags

Use `@moduletag` when all tests in a module share the same characteristic:

```elixir
defmodule Arbor.MCP.Compliance.ProtocolTest do
  use ExUnit.Case
  
  @moduletag :compliance
  @moduletag :protocol
  
  # All tests here are compliance and protocol tests
end
```

### When to Use Test Tags

Use `@tag` for individual test characteristics:

```elixir
@tag :slow
@tag timeout: :infinity
test "stress test with 10k concurrent requests" do
  # ...
end

@tag :skip
@tag :wip
test "new feature not yet implemented" do
  # ...
end
```

### Multiple Tags

Tests can have multiple tags for fine-grained control:

```elixir
@moduletag :integration
@moduletag :transport
@moduletag :http

test "Streamable HTTP transport with real server" do
  # This test is: integration + transport + http
end

@tag :slow
@tag :stress
test "Streamable HTTP transport under load" do
  # This test is: integration + transport + http + slow + stress
end
```

## Default Exclusions

The following tags are excluded by default for faster development:
- `:integration`
- `:external`
- `:slow`
- `:performance`
- `:stress`
- `:wip`
- `:skip`
- `:requires_http`
- `:requires_stdio`
- `:requires_beam`

Run with `--include <tag>` to include these tests.

## CI Configuration

For CI environments, use:

```bash
# Runs integration and compliance tests, excludes flaky/manual tests
mix test.suite ci
```

Or configure in your CI pipeline:

```yaml
# Example GitHub Actions
- run: mix test.suite ci --cover
```

## Best Practices

1. **Tag Consistently** - Use standard tags rather than creating new ones
2. **Tag Minimally** - Only add tags that affect test execution
3. **Document WIP** - Always include a comment explaining why a test is `:wip` or `:skip`
4. **Performance Tests** - Tag with both `:performance` and `:slow`
5. **Flaky Tests** - Fix them rather than marking `:flaky` when possible
6. **Transport Tests** - Tag with both general `:transport` and specific transport tag

## Examples

### Compliance Test
```elixir
defmodule Arbor.MCP.Compliance.BatchTest do
  use ExUnit.Case
  
  @moduletag :compliance
  @moduletag :batch
  @moduletag :protocol
  
  test "empty batch returns error" do
    # ...
  end
end
```

### Integration Test
```elixir
defmodule Arbor.MCP.Integration.StreamableHTTPTransportTest do
  use ExUnit.Case
  
  @moduletag :integration
  @moduletag :transport
  @moduletag :http
  @moduletag :requires_http
  
  @tag :slow
  test "handles reconnection with backoff" do
    # ...
  end
end
```

### Performance Test
```elixir
defmodule Arbor.MCP.Performance.ThroughputTest do
  use ExUnit.Case
  
  @moduletag :performance
  @moduletag :stress
  @moduletag :slow
  
  @tag timeout: :infinity
  test "handles 10k messages per second" do
    # ...
  end
end
```
