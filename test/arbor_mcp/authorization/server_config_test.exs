defmodule Arbor.MCP.Authorization.ServerConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Authorization.ServerConfig

  setup do
    # Start the GenServer for each test
    {:ok, _pid} = start_supervised({ServerConfig, []})

    # Clear any existing application environment
    Application.delete_env(:arbor_mcp, ServerConfig)

    on_exit(fn ->
      Application.delete_env(:arbor_mcp, ServerConfig)
    end)

    :ok
  end

  describe "validate_config/1" do
    test "validates valid HTTPS configuration" do
      config = %{
        introspection_endpoint: "https://auth.example.com/introspect",
        realm: "test-realm"
      }

      assert :ok = ServerConfig.validate_config(config)
    end

    test "allows HTTP for localhost" do
      config = %{
        introspection_endpoint: "http://localhost:4000/introspect"
      }

      assert :ok = ServerConfig.validate_config(config)
    end

    test "allows HTTP for 127.0.0.1" do
      config = %{
        introspection_endpoint: "http://127.0.0.1:4000/introspect"
      }

      assert :ok = ServerConfig.validate_config(config)
    end

    test "rejects HTTP for non-localhost" do
      config = %{
        introspection_endpoint: "http://example.com/introspect"
      }

      assert {:error, :https_required} = ServerConfig.validate_config(config)
    end

    test "validates optional fields" do
      config = %{
        introspection_endpoint: "https://auth.example.com/introspect",
        realm: "test-realm",
        client_id: "client-123",
        client_secret: "secret-456",
        timeout: 5000,
        retries: 3
      }

      assert :ok = ServerConfig.validate_config(config)
    end

    test "rejects invalid timeout" do
      config = %{
        introspection_endpoint: "https://auth.example.com/introspect",
        timeout: -1
      }

      assert {:error, :invalid_config} = ServerConfig.validate_config(config)
    end

    test "rejects invalid retries" do
      config = %{
        introspection_endpoint: "https://auth.example.com/introspect",
        retries: -1
      }

      assert {:error, :invalid_config} = ServerConfig.validate_config(config)
    end

    test "rejects empty realm" do
      config = %{
        introspection_endpoint: "https://auth.example.com/introspect",
        realm: ""
      }

      assert {:error, :invalid_config} = ServerConfig.validate_config(config)
    end

    test "rejects missing introspection_endpoint" do
      config = %{realm: "test-realm"}

      assert {:error, :invalid_config} = ServerConfig.validate_config(config)
    end

    test "rejects invalid introspection_endpoint" do
      config = %{introspection_endpoint: "not-a-url"}

      assert {:error, :invalid_config} = ServerConfig.validate_config(config)
    end
  end

  describe "server management" do
    test "put_server/2 and get_server/1 with valid config" do
      config = %{
        introspection_endpoint: "https://auth.example.com/introspect",
        realm: "test-realm"
      }

      assert :ok = ServerConfig.put_server(:test_server, config)
      assert {:ok, ^config} = ServerConfig.get_server(:test_server)
    end

    test "put_server/2 rejects invalid config" do
      invalid_config = %{introspection_endpoint: "not-a-url"}

      assert {:error, :invalid_config} = ServerConfig.put_server(:test_server, invalid_config)
      assert {:error, :not_found} = ServerConfig.get_server(:test_server)
    end

    test "get_server/1 returns error for non-existent server" do
      assert {:error, :not_found} = ServerConfig.get_server(:non_existent)
    end

    test "delete_server/1 removes server configuration" do
      config = %{introspection_endpoint: "https://auth.example.com/introspect"}

      assert :ok = ServerConfig.put_server(:test_server, config)
      assert {:ok, ^config} = ServerConfig.get_server(:test_server)

      assert :ok = ServerConfig.delete_server(:test_server)
      assert {:error, :not_found} = ServerConfig.get_server(:test_server)
    end

    test "list_servers/0 returns all server IDs" do
      config1 = %{introspection_endpoint: "https://auth1.example.com/introspect"}
      config2 = %{introspection_endpoint: "https://auth2.example.com/introspect"}

      assert :ok = ServerConfig.put_server(:server1, config1)
      assert :ok = ServerConfig.put_server(:server2, config2)

      servers = ServerConfig.list_servers()
      assert :server1 in servers
      assert :server2 in servers
      assert length(servers) == 2
    end
  end

  describe "default server management" do
    test "get_default_server_id/0 returns configured default" do
      Application.put_env(:arbor_mcp, ServerConfig, default_server: :my_default)

      assert :my_default = ServerConfig.get_default_server_id()
    end

    test "get_default_server_id/0 returns :default when not configured" do
      assert :default = ServerConfig.get_default_server_id()
    end

    test "set_default_server_id/1 updates default server" do
      assert :ok = ServerConfig.set_default_server_id(:new_default)
      # Note: This changes the GenServer state but not application env
    end

    test "get_server/0 uses default server" do
      config = %{introspection_endpoint: "https://auth.example.com/introspect"}
      default_id = ServerConfig.get_default_server_id()

      assert :ok = ServerConfig.put_server(default_id, config)
      assert {:ok, ^config} = ServerConfig.get_server()
    end

    test "get_server/0 returns error when default server not configured" do
      assert {:error, :not_found} = ServerConfig.get_server()
    end
  end

  describe "environment configuration loading" do
    test "loads servers from application environment" do
      servers = %{
        auth_server: %{
          introspection_endpoint: "https://auth.example.com/introspect",
          realm: "main-realm"
        },
        backup_server: %{
          introspection_endpoint: "https://backup.example.com/introspect",
          realm: "backup-realm"
        }
      }

      Application.put_env(:arbor_mcp, ServerConfig,
        default_server: :auth_server,
        servers: servers
      )

      assert :ok = ServerConfig.reload_from_env()

      assert {:ok, main_config} = ServerConfig.get_server(:auth_server)
      assert main_config.introspection_endpoint == "https://auth.example.com/introspect"
      assert main_config.realm == "main-realm"

      assert {:ok, backup_config} = ServerConfig.get_server(:backup_server)
      assert backup_config.introspection_endpoint == "https://backup.example.com/introspect"
      assert backup_config.realm == "backup-realm"
    end

    test "skips invalid servers from environment" do
      servers = %{
        valid_server: %{
          introspection_endpoint: "https://auth.example.com/introspect"
        },
        invalid_server: %{
          introspection_endpoint: "not-a-url"
        }
      }

      Application.put_env(:arbor_mcp, ServerConfig, servers: servers)

      assert :ok = ServerConfig.reload_from_env()

      assert {:ok, _config} = ServerConfig.get_server(:valid_server)
      assert {:error, :not_found} = ServerConfig.get_server(:invalid_server)
    end

    test "handles missing servers configuration gracefully" do
      Application.put_env(:arbor_mcp, ServerConfig, default_server: :test)

      assert :ok = ServerConfig.reload_from_env()
      assert [] = ServerConfig.list_servers()
    end

    test "handles invalid servers configuration gracefully" do
      Application.put_env(:arbor_mcp, ServerConfig, servers: "not-a-map")

      assert :ok = ServerConfig.reload_from_env()
      assert [] = ServerConfig.list_servers()
    end
  end

  describe "integration scenarios" do
    test "typical OAuth 2.1 server configuration workflow" do
      # 1. Set up main auth server
      main_config = %{
        introspection_endpoint: "https://auth.company.com/introspect",
        realm: "company-mcp",
        client_id: "mcp-server-prod",
        timeout: 10_000,
        retries: 2
      }

      assert :ok = ServerConfig.put_server(:main_auth, main_config)
      assert :ok = ServerConfig.set_default_server_id(:main_auth)

      # 2. Set up backup auth server
      backup_config = %{
        introspection_endpoint: "https://backup-auth.company.com/introspect",
        realm: "company-mcp-backup",
        timeout: 5_000,
        retries: 1
      }

      assert :ok = ServerConfig.put_server(:backup_auth, backup_config)

      # 3. Verify configurations
      assert {:ok, retrieved_main} = ServerConfig.get_server()
      assert retrieved_main.introspection_endpoint == "https://auth.company.com/introspect"
      assert retrieved_main.realm == "company-mcp"

      assert {:ok, retrieved_backup} = ServerConfig.get_server(:backup_auth)

      assert retrieved_backup.introspection_endpoint ==
               "https://backup-auth.company.com/introspect"

      # 4. List all configured servers
      servers = ServerConfig.list_servers()
      assert :main_auth in servers
      assert :backup_auth in servers

      # 5. Validate configurations
      assert :ok = ServerConfig.validate_config(retrieved_main)
      assert :ok = ServerConfig.validate_config(retrieved_backup)
    end

    test "development environment with localhost configuration" do
      dev_config = %{
        introspection_endpoint: "http://localhost:8080/auth/introspect",
        realm: "dev-mcp",
        client_id: "dev-client",
        client_secret: "dev-secret"
      }

      assert :ok = ServerConfig.validate_config(dev_config)
      assert :ok = ServerConfig.put_server(:dev_auth, dev_config)
      assert {:ok, ^dev_config} = ServerConfig.get_server(:dev_auth)
    end
  end
end
