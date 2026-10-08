#!/usr/bin/env elixir

# ClientConfig Builder Example
# Demonstrates pipe-friendly client configuration

Mix.install([
  {:arbor_mcp, path: Path.expand("../..", __DIR__)}
])

alias Arbor.MCP.ClientConfig

IO.puts("""
==========================================
Arbor.MCP ClientConfig Builder Demo
==========================================
""")

# 1. Basic Configuration
IO.puts("1. Basic stdio configuration:\n")

stdio_config =
  ClientConfig.new()
  |> ClientConfig.put_transport(:stdio, command: ["python", "server.py"])

IO.inspect(stdio_config.transport, label: "Stdio transport")

# 2. HTTP Configuration with Options
IO.puts("\n2. HTTP configuration with options:\n")

http_config =
  ClientConfig.new()
  |> ClientConfig.put_transport(:http,
    url: "https://api.example.com",
    path: "/mcp/v1"
  )
  |> ClientConfig.put_auth(:bearer, token: "secret-token-123")
  |> ClientConfig.put_timeout(
    connect: 10_000,
    request: 30_000
  )
  |> ClientConfig.put_retry_policy(
    max_attempts: 5,
    base_interval: 1000,
    backoff_type: :exponential
  )

IO.inspect(http_config.auth, label: "Auth config")
IO.inspect(http_config.timeouts, label: "Timeout config")
IO.inspect(http_config.retry_policy, label: "Retry config")

# 3. Client Information
IO.puts("\n3. Client information:\n")

client_config =
  ClientConfig.new()
  |> ClientConfig.put_client_info(
    name: "My Awesome MCP Client",
    version: "2.0.0"
  )

IO.inspect(client_config.client_info, label: "Client info")

# 4. Pool Configuration
IO.puts("\n4. Connection pool configuration:\n")

pool_config =
  ClientConfig.new()
  |> ClientConfig.put_pool(
    enabled: true,
    size: 10,
    max_overflow: 5
  )

IO.inspect(pool_config.pool, label: "Pool config")

# 5. Observability Configuration
IO.puts("\n5. Observability configuration:\n")

obs_config =
  ClientConfig.new()
  |> ClientConfig.put_observability(
    logging: %{
      enabled: true,
      level: :debug,
      format: :json
    },
    telemetry: %{
      enabled: true,
      prefix: [:my_app, :mcp]
    }
  )

IO.inspect(obs_config.observability, label: "Observability config")

# 6. Profile-based Configuration
IO.puts("\n6. Profile-based configuration:\n")

# Development profile
dev_config = ClientConfig.new(:development)
IO.puts("Development timeouts: #{inspect(dev_config.timeouts)}")

# Production profile
prod_config = ClientConfig.new(:production)
IO.puts("Production timeouts: #{inspect(prod_config.timeouts)}")

# Test profile
test_config = ClientConfig.new(:test)
IO.puts("Test timeouts: #{inspect(test_config.timeouts)}")

# 7. Configuration Validation
IO.puts("\n7. Configuration validation:\n")

# Valid configuration
valid_config =
  ClientConfig.new()
  |> ClientConfig.put_transport(:http, url: "http://localhost:8080")

case ClientConfig.validate(valid_config) do
  :ok -> IO.puts("✓ Valid configuration")
  {:error, errors} -> IO.puts("✗ Errors: #{inspect(errors)}")
end

# Invalid configuration
invalid_config =
  ClientConfig.new()
  |> ClientConfig.put_retry_policy(max_attempts: 0, base_interval: -100)

case ClientConfig.validate(invalid_config) do
  :ok -> IO.puts("✓ Valid configuration")
  {:error, errors} -> IO.puts("✗ Errors: #{inspect(errors)}")
end

# 8. Converting to Options
IO.puts("\n8. Converting to client options:\n")

final_config =
  ClientConfig.new()
  |> ClientConfig.put_transport(:stdio, command: ["elixir", "server.exs"])
  |> ClientConfig.put_retry_policy(max_attempts: 3)
  |> ClientConfig.put_custom(:my_option, "custom_value")

opts = ClientConfig.to_client_opts(final_config)
IO.inspect(opts, label: "Client options")

IO.puts("""

==========================================
Key Takeaways:
==========================================

1. Use ClientConfig.new/0 to start
2. Chain put_* functions to configure
3. Use profiles for environment presets
4. Validate before connecting
5. Convert to options for client APIs
6. All configuration is immutable
""")
