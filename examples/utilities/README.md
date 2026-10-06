# ArborMCP Utility Examples

This directory contains utility examples that demonstrate focused ArborMCP features in isolation.

## Examples

### structured_responses.exs
Understanding the Response and Error helpers:
- Creating text, JSON, and error responses
- Extracting content from responses
- Error types and categories
- Converting between formats

### error_handling.exs
Error handling patterns and best practices:
- Creating different error types
- Error responses vs exceptions
- Error context and metadata
- Practical error handling patterns

### client_config.exs
Using the ClientConfig builder pattern:
- Transport configuration
- Authentication setup
- Timeout and retry policies
- Connection-pool configuration fields
- Profile-based configuration

## Running the Examples

These are pure API demonstrations that load the local MCP package with
`Mix.install`; they do not start real connections or qualify an external server.
Before running an unpublished checkout, set `ARBOR_RPC_PATH` to the shared RPC
checkout and provide the C17 compiler required by its source install:

```bash
# Run any utility example
export ARBOR_RPC_PATH=/absolute/path/to/arbor_rpc
cd examples/utilities # From the MCP repository root.
elixir <example_name>.exs
```

## When to Use These

- **Before building a server** - Understand response types
- **When debugging** - See how errors should be structured
- **Client development** - Learn configuration options
- **Learning the API** - See patterns in isolation
