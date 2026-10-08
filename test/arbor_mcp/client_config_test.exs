defmodule Arbor.MCP.ClientConfigTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.ClientConfig

  describe "new/0" do
    test "creates default configuration" do
      config = ClientConfig.new()

      assert config.profile == :development
      assert config.transport.type == :http
      assert config.transport.host == "localhost"
      assert config.transport.port == 8080
      assert config.retry_policy.enabled == true
      assert config.retry_policy.max_attempts == 3
      assert config.timeouts.connect == 5_000
      assert config.auth.type == :none
      assert config.pool.enabled == false
      assert config.observability.logging.enabled == true
    end
  end

  describe "new/1 with profiles" do
    test "creates development profile" do
      config = ClientConfig.new(:development)

      assert config.profile == :development
      assert config.timeouts.connect == 5_000
      assert config.retry_policy.max_attempts == 3
      assert config.observability.logging.level == :debug
      assert config.pool.enabled == false
    end

    test "creates test profile" do
      config = ClientConfig.new(:test)

      assert config.profile == :test
      assert config.timeouts.connect == 1_000
      assert config.retry_policy.enabled == false
      assert config.observability.logging.enabled == false
      assert config.pool.enabled == false
    end

    test "creates production profile" do
      config = ClientConfig.new(:production)

      assert config.profile == :production
      assert config.timeouts.connect == 10_000
      assert config.retry_policy.max_attempts == 5
      assert config.retry_policy.backoff_type == :exponential
      assert config.observability.logging.format == :json
      assert config.pool.enabled == true
    end

    test "creates http profile" do
      config = ClientConfig.new(:http)

      assert config.transport.type == :http
      assert config.transport.url == "http://localhost:8080/mcp/v1"
    end

    test "creates stdio profile" do
      config = ClientConfig.new(:stdio)

      assert config.transport.type == :stdio
      assert config.transport.command == "mcp-server"
    end

    test "creates BEAM profile" do
      config = ClientConfig.new(:beam)

      assert config.transport.type == :beam
    end
  end

  describe "new/2 with transport type and options" do
    test "creates HTTP transport configuration" do
      config = ClientConfig.new(:http, url: "http://example.com:9090")

      assert config.transport.type == :http
      assert config.transport.url == "http://example.com:9090"
    end

    test "creates stdio transport configuration" do
      config = ClientConfig.new(:stdio, command: ["python", "server.py"])

      assert config.transport.type == :stdio
      assert config.transport.command == ["python", "server.py"]
    end

    test "creates configuration with custom options" do
      config = ClientConfig.new(:development, custom_option: "value")

      assert config.custom_options.custom_option == "value"
    end
  end

  describe "put_transport/3" do
    test "configures HTTP transport" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_transport(:http, url: "https://api.example.com", ssl: true)

      assert config.transport.type == :http
      assert config.transport.url == "https://api.example.com"
      assert config.transport.ssl == true
    end

    test "configures stdio transport" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_transport(:stdio, command: ["node", "server.js"])

      assert config.transport.type == :stdio
      assert config.transport.command == ["node", "server.js"]
    end

    test "auto-generates URL from host and port for HTTP" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_transport(:http, host: "example.com", port: 9090, ssl: true)

      assert config.transport.url == "https://example.com:9090/mcp/v1"
    end

    test "sets default command for stdio when none provided" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_transport(:stdio)

      assert config.transport.command == "mcp-server"
    end
  end

  describe "add_fallback/3" do
    test "adds fallback transport configurations" do
      config =
        ClientConfig.new(:http, url: "http://primary:8080")
        |> ClientConfig.add_fallback(:http, url: "http://backup:8080")
        |> ClientConfig.add_fallback(:stdio, command: "local-server")

      assert length(config.fallback_transports) == 2

      [http_fallback, stdio_fallback] = config.fallback_transports
      assert http_fallback.type == :http
      assert http_fallback.url == "http://backup:8080"
      assert stdio_fallback.type == :stdio
      assert stdio_fallback.command == "local-server"
    end
  end

  describe "put_retry_policy/2" do
    test "configures retry policy" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_retry_policy(
          max_attempts: 5,
          base_interval: 2000,
          backoff_type: :exponential,
          jitter: true
        )

      assert config.retry_policy.max_attempts == 5
      assert config.retry_policy.base_interval == 2000
      assert config.retry_policy.backoff_type == :exponential
      assert config.retry_policy.jitter == true
    end
  end

  describe "put_timeout/2" do
    test "configures timeout settings" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_timeout(
          connect: 15_000,
          request: 45_000,
          idle: 120_000
        )

      assert config.timeouts.connect == 15_000
      assert config.timeouts.request == 45_000
      assert config.timeouts.idle == 120_000
    end
  end

  describe "put_auth/3" do
    test "configures bearer token authentication" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_auth(:bearer, token: "my-secret-token")

      assert config.auth.type == :bearer
      assert config.auth.token == "my-secret-token"
    end

    test "configures basic authentication" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_auth(:basic, username: "user", password: "pass")

      assert config.auth.type == :basic
      assert config.auth.username == "user"
      assert config.auth.password == "pass"
    end

    test "configures custom header authentication" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_auth(:custom, headers: %{"X-API-Key" => "secret"})

      assert config.auth.type == :custom
      assert config.auth.headers["X-API-Key"] == "secret"
    end
  end

  describe "put_pool/2" do
    test "configures connection pooling" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_pool(
          enabled: true,
          size: 15,
          max_overflow: 10,
          checkout_timeout: 8_000
        )

      assert config.pool.enabled == true
      assert config.pool.size == 15
      assert config.pool.max_overflow == 10
      assert config.pool.checkout_timeout == 8_000
    end
  end

  describe "put_observability/2" do
    test "configures logging settings" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_observability(logging: [enabled: true, level: :warn, format: :json])

      assert config.observability.logging.enabled == true
      assert config.observability.logging.level == :warn
      assert config.observability.logging.format == :json
    end

    test "configures telemetry settings" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_observability(telemetry: [enabled: true, prefix: [:my_app, :mcp]])

      assert config.observability.telemetry.enabled == true
      assert config.observability.telemetry.prefix == [:my_app, :mcp]
    end

    test "configures multiple observability aspects" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_observability(
          logging: [level: :error],
          telemetry: [enabled: false],
          tracing: [enabled: true]
        )

      assert config.observability.logging.level == :error
      assert config.observability.telemetry.enabled == false
      assert config.observability.tracing.enabled == true
    end
  end

  describe "put_client_info/2" do
    test "configures client information" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_client_info(
          name: "MyApp MCP Client",
          version: "2.1.0"
        )

      assert config.client_info.name == "MyApp MCP Client"
      assert config.client_info.version == "2.1.0"
      assert String.contains?(config.client_info.user_agent, "MyApp MCP Client/2.1.0")
    end
  end

  describe "put_custom/3" do
    test "adds custom configuration options" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_custom(:my_option, "custom_value")
        |> ClientConfig.put_custom(:another_option, %{nested: "data"})

      assert config.custom_options.my_option == "custom_value"
      assert config.custom_options.another_option == %{nested: "data"}
    end
  end

  describe "validate/1" do
    test "validates valid configuration" do
      config = ClientConfig.new(:http, url: "http://localhost:8080")

      assert ClientConfig.validate(config) == :ok
    end

    test "detects missing URL for HTTP transport" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_transport(:http, host: nil, port: nil)

      config = Map.put(config, :transport, %{config.transport | url: nil})

      assert {:error, errors} = ClientConfig.validate(config)
      assert "HTTP transport requires URL" in errors
    end

    test "detects missing command for stdio transport" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_transport(:stdio)

      config = Map.put(config, :transport, %{config.transport | command: nil})

      assert {:error, errors} = ClientConfig.validate(config)
      assert "Stdio transport requires command" in errors
    end

    test "detects invalid retry configuration" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_retry_policy(max_attempts: 0, base_interval: -100)

      assert {:error, errors} = ClientConfig.validate(config)
      assert "Retry max_attempts must be positive" in errors
      assert "Retry base_interval must be non-negative" in errors
    end

    test "detects invalid timeout configuration" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_timeout(connect: -1, request: -1)

      assert {:error, errors} = ClientConfig.validate(config)
      assert "Connect timeout must be non-negative" in errors
      assert "Request timeout must be non-negative" in errors
    end

    test "detects missing bearer token" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_auth(:bearer, token: nil)

      assert {:error, errors} = ClientConfig.validate(config)
      assert "Bearer auth requires token" in errors
    end

    test "detects missing basic auth credentials" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_auth(:basic, username: nil, password: nil)

      assert {:error, errors} = ClientConfig.validate(config)
      assert "Basic auth requires username" in errors
      assert "Basic auth requires password" in errors
    end

    test "detects invalid pool configuration" do
      config =
        ClientConfig.new()
        |> ClientConfig.put_pool(size: 0, max_overflow: -1)

      assert {:error, errors} = ClientConfig.validate(config)
      assert "Pool size must be positive" in errors
      assert "Pool max_overflow must be non-negative" in errors
    end
  end

  describe "to_client_opts/1" do
    test "converts basic HTTP configuration" do
      config = ClientConfig.new(:http, url: "http://localhost:8080")
      opts = ClientConfig.to_client_opts(config)

      assert Keyword.get(opts, :transport) == :http
      assert Keyword.get(opts, :url) == "http://localhost:8080"
      assert Keyword.get(opts, :timeout) == 5_000
    end

    test "converts configuration with authentication" do
      config =
        ClientConfig.new(:http, url: "http://localhost:8080")
        |> ClientConfig.put_auth(:bearer, token: "secret-token")

      opts = ClientConfig.to_client_opts(config)
      headers = Keyword.get(opts, :headers, [])

      assert {"Authorization", "Bearer secret-token"} in headers
    end

    test "converts configuration with basic auth" do
      config =
        ClientConfig.new(:http, url: "http://localhost:8080")
        |> ClientConfig.put_auth(:basic, username: "user", password: "pass")

      opts = ClientConfig.to_client_opts(config)
      headers = Keyword.get(opts, :headers, [])

      expected_auth = "Basic " <> Base.encode64("user:pass")
      assert {"Authorization", expected_auth} in headers
    end

    test "converts configuration with custom headers" do
      config =
        ClientConfig.new(:http, url: "http://localhost:8080")
        |> ClientConfig.put_auth(:custom, headers: %{"X-API-Key" => "secret"})

      opts = ClientConfig.to_client_opts(config)
      headers = Keyword.get(opts, :headers, [])

      assert {"X-API-Key", "secret"} in headers
    end

    test "converts configuration with pool settings" do
      config =
        ClientConfig.new(:http, url: "http://localhost:8080")
        |> ClientConfig.put_pool(enabled: true, size: 10, max_overflow: 5)

      opts = ClientConfig.to_client_opts(config)

      assert Keyword.get(opts, :pool_size) == 10
      assert Keyword.get(opts, :pool_max_overflow) == 5
    end

    test "converts configuration with observability settings" do
      config =
        ClientConfig.new(:http, url: "http://localhost:8080")
        |> ClientConfig.put_observability(
          logging: [enabled: true, level: :warn, format: :json],
          telemetry: [enabled: true, prefix: [:my_app]]
        )

      opts = ClientConfig.to_client_opts(config)

      assert Keyword.get(opts, :log_level) == :warn
      assert Keyword.get(opts, :log_format) == :json
      assert Keyword.get(opts, :telemetry_prefix) == [:my_app]
    end

    test "converts configuration with custom options" do
      config =
        ClientConfig.new(:http, url: "http://localhost:8080")
        |> ClientConfig.put_custom(:my_option, "value")
        |> ClientConfig.put_custom(:debug_mode, true)

      opts = ClientConfig.to_client_opts(config)

      assert Keyword.get(opts, :my_option) == "value"
      assert Keyword.get(opts, :debug_mode) == true
    end

    test "filters out nil values" do
      config = ClientConfig.new(:stdio, command: "server")
      opts = ClientConfig.to_client_opts(config)

      # URL should not be present for stdio transport
      refute Keyword.has_key?(opts, :url)
    end
  end

  describe "get_all_transports/1" do
    test "returns primary transport only when no fallbacks" do
      config = ClientConfig.new(:http, url: "http://localhost:8080")
      transports = ClientConfig.get_all_transports(config)

      assert length(transports) == 1
      assert List.first(transports).type == :http
    end

    test "returns primary and fallback transports" do
      config =
        ClientConfig.new(:http, url: "http://primary:8080")
        |> ClientConfig.add_fallback(:http, url: "http://backup:8080")
        |> ClientConfig.add_fallback(:stdio, command: "local-server")

      transports = ClientConfig.get_all_transports(config)

      assert length(transports) == 3
      assert Enum.at(transports, 0).type == :http
      assert Enum.at(transports, 0).url == "http://primary:8080"
      assert Enum.at(transports, 1).type == :http
      assert Enum.at(transports, 1).url == "http://backup:8080"
      assert Enum.at(transports, 2).type == :stdio
      assert Enum.at(transports, 2).command == "local-server"
    end
  end

  describe "integration scenarios" do
    test "complete production configuration" do
      config =
        ClientConfig.new(:production)
        |> ClientConfig.put_transport(:http, url: "https://api.example.com", ssl: true)
        |> ClientConfig.add_fallback(:http, url: "https://backup.example.com")
        |> ClientConfig.put_auth(:bearer, token: "prod-token")
        |> ClientConfig.put_retry_policy(max_attempts: 10, jitter: true)
        |> ClientConfig.put_timeout(connect: 15_000, request: 60_000)
        |> ClientConfig.put_pool(enabled: true, size: 20)
        |> ClientConfig.put_observability(
          logging: [level: :warn, format: :json],
          telemetry: [enabled: true, prefix: [:prod_app, :mcp]]
        )
        |> ClientConfig.put_client_info(name: "Production Client", version: "1.0.0")

      assert ClientConfig.validate(config) == :ok

      opts = ClientConfig.to_client_opts(config)
      assert Keyword.get(opts, :transport) == :http
      assert Keyword.get(opts, :url) == "https://api.example.com"
      assert Keyword.get(opts, :retry_attempts) == 10
      assert Keyword.get(opts, :pool_size) == 20

      transports = ClientConfig.get_all_transports(config)
      assert length(transports) == 2
    end

    test "development configuration with stdio" do
      config =
        ClientConfig.new(:development)
        |> ClientConfig.put_transport(:stdio, command: ["python", "dev-server.py"])
        |> ClientConfig.put_observability(logging: [level: :debug])
        |> ClientConfig.put_custom(:debug_mode, true)

      assert ClientConfig.validate(config) == :ok

      opts = ClientConfig.to_client_opts(config)
      assert Keyword.get(opts, :transport) == :stdio
      assert Keyword.get(opts, :command) == ["python", "dev-server.py"]
      assert Keyword.get(opts, :log_level) == :debug
      assert Keyword.get(opts, :debug_mode) == true
    end

    test "test configuration with minimal settings" do
      config =
        ClientConfig.new(:test)
        |> ClientConfig.put_transport(:beam)

      assert ClientConfig.validate(config) == :ok

      opts = ClientConfig.to_client_opts(config)
      assert Keyword.get(opts, :transport) == :beam
      # Fast test timeout
      assert Keyword.get(opts, :timeout) == 1_000
    end
  end
end
