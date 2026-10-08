defmodule Arbor.MCP.Test.Support.Transports do
  @moduledoc """
  Test support module for transport-related testing utilities.

  This module provides helpers for testing different transport mechanisms
  used in Arbor.MCP, including HTTP, stdio, and BEAM transports. It includes
  mock transport implementations and utilities for testing transport behavior.
  """

  @doc """
  Creates a mock transport configuration for testing.

  ## Parameters
  - `transport_type` - The type of transport (:http, :stdio, :beam, :test)
  - `opts` - Additional options for the transport

  ## Returns
  A transport configuration map suitable for testing.
  """
  @spec mock_transport_config(atom(), keyword()) :: map()
  def mock_transport_config(transport_type, opts \\ []) do
    base_config = %{
      type: transport_type,
      test_mode: true,
      timeout: Keyword.get(opts, :timeout, 5000)
    }

    case transport_type do
      :http ->
        Map.merge(base_config, %{
          host: Keyword.get(opts, :host, "localhost"),
          # Use random port for testing
          port: Keyword.get(opts, :port, 0),
          path: Keyword.get(opts, :path, "/mcp"),
          ssl: Keyword.get(opts, :ssl, false)
        })

      :stdio ->
        Map.merge(base_config, %{
          command: Keyword.get(opts, :command, "echo"),
          args: Keyword.get(opts, :args, []),
          cwd: Keyword.get(opts, :cwd, System.tmp_dir())
        })

      :beam ->
        Map.merge(base_config, %{
          target_node: Keyword.get(opts, :target_node, node()),
          module: Keyword.get(opts, :module, Arbor.MCP.TestServer),
          function: Keyword.get(opts, :function, :handle_message)
        })

      :test ->
        Map.merge(base_config, %{
          mock_responses: Keyword.get(opts, :mock_responses, []),
          fail_after: Keyword.get(opts, :fail_after, nil),
          delay: Keyword.get(opts, :delay, 0)
        })

      _ ->
        base_config
    end
  end

  @doc """
  Creates a mock transport process for testing.

  This creates a GenServer process that simulates transport behavior
  for testing purposes without requiring actual network connections.
  """
  @spec start_mock_transport(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_mock_transport(transport_type, opts \\ []) do
    config = mock_transport_config(transport_type, opts)

    GenServer.start_link(__MODULE__.MockTransport, config, [])
  end

  @doc """
  Simulates a transport connection for testing.

  This function creates a mock connection that can be used in tests
  to verify transport behavior without external dependencies.
  """
  @spec mock_connection(atom(), keyword()) :: %{
          transport: atom(),
          config: map(),
          pid: pid() | nil
        }
  def mock_connection(transport_type, opts \\ []) do
    config = mock_transport_config(transport_type, opts)

    case start_mock_transport(transport_type, opts) do
      {:ok, pid} ->
        %{transport: transport_type, config: config, pid: pid}

      {:error, _reason} ->
        %{transport: transport_type, config: config, pid: nil}
    end
  end

  @doc """
  Validates transport configuration for testing.

  Ensures that transport configurations are valid and contain
  required fields for testing scenarios.
  """
  @spec validate_transport_config(map()) :: :ok | {:error, String.t()}
  def validate_transport_config(%{type: type} = config)
      when type in [:http, :stdio, :beam, :test] do
    case type do
      :http ->
        required_fields = [:host, :port]
        validate_required_fields(config, required_fields)

      :stdio ->
        required_fields = [:command]
        validate_required_fields(config, required_fields)

      :beam ->
        required_fields = [:target_node, :module]
        validate_required_fields(config, required_fields)

      :test ->
        # Test transport is always valid
        :ok
    end
  end

  def validate_transport_config(_config) do
    {:error, "Transport configuration must include :type field"}
  end

  @doc """
  Creates transport headers for HTTP testing.

  Generates appropriate headers for different HTTP test scenarios,
  including authentication headers and content type headers.
  """
  @spec mock_http_headers(keyword()) :: map()
  def mock_http_headers(opts \\ []) do
    base_headers = %{
      "content-type" => "application/json",
      "user-agent" => "Arbor.MCP-Test/1.0"
    }

    auth_headers =
      case Keyword.get(opts, :auth) do
        {:bearer, token} ->
          %{"authorization" => "Bearer #{token}"}

        {:api_key, key} ->
          %{"x-api-key" => key}

        {:basic, {user, pass}} ->
          encoded = Base.encode64("#{user}:#{pass}")
          %{"authorization" => "Basic #{encoded}"}

        _ ->
          %{}
      end

    custom_headers = Keyword.get(opts, :headers, %{})

    Map.merge(base_headers, auth_headers)
    |> Map.merge(custom_headers)
  end

  @doc """
  Simulates transport errors for testing error handling.

  Creates various error scenarios that can occur during transport
  operations to test error handling and recovery mechanisms.
  """
  @spec simulate_transport_error(atom()) :: {:error, term()}
  def simulate_transport_error(error_type) do
    case error_type do
      :connection_refused -> {:error, :econnrefused}
      :timeout -> {:error, :timeout}
      :network_unreachable -> {:error, :enetunreach}
      :host_unreachable -> {:error, :ehostunreach}
      :ssl_error -> {:error, {:tls_alert, {:handshake_failure, "SSL handshake failed"}}}
      :authentication_failed -> {:error, :authentication_failed}
      :protocol_error -> {:error, :protocol_error}
      :invalid_response -> {:error, :invalid_response}
      _ -> {:error, :unknown_transport_error}
    end
  end

  @doc """
  Creates a transport message in the expected format.

  Formats messages according to the transport protocol specifications
  for use in testing scenarios.
  """
  @spec format_transport_message(String.t(), map()) :: map()
  def format_transport_message(method, params) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => Arbor.MCP.Internal.Protocol.generate_id()
    }
  end

  # Private helper functions

  defp validate_required_fields(config, required_fields) do
    missing_fields = Enum.reject(required_fields, &Map.has_key?(config, &1))

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end
end

defmodule Arbor.MCP.Test.Support.Transports.MockTransport do
  @moduledoc false
  # Mock transport GenServer for testing

  use GenServer

  def init(config) do
    {:ok, %{config: config, messages: [], connected: false}}
  end

  def handle_call(:connect, _from, state) do
    {:reply, :ok, %{state | connected: true}}
  end

  def handle_call(:disconnect, _from, state) do
    {:reply, :ok, %{state | connected: false}}
  end

  def handle_call({:send_message, message}, _from, state) do
    new_messages = [message | state.messages]
    response = mock_response(message, state.config)
    {:reply, {:ok, response}, %{state | messages: new_messages}}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  def handle_call(:clear_messages, _from, state) do
    {:reply, :ok, %{state | messages: []}}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unknown_request}, state}
  end

  def handle_cast(_request, state) do
    {:noreply, state}
  end

  def handle_info(_info, state) do
    {:noreply, state}
  end

  # Generate mock responses based on message type
  defp mock_response(%{"method" => "initialize"}, _config) do
    %{
      "jsonrpc" => "2.0",
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "MockServer", "version" => "1.0.0"}
      },
      "id" => 1
    }
  end

  defp mock_response(%{"method" => "tools/list"}, _config) do
    %{
      "jsonrpc" => "2.0",
      "result" => %{"tools" => []},
      "id" => 2
    }
  end

  defp mock_response(%{"method" => "ping"}, _config) do
    %{
      "jsonrpc" => "2.0",
      "result" => %{},
      "id" => 3
    }
  end

  defp mock_response(_message, _config) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32601, "message" => "Method not found"},
      "id" => nil
    }
  end
end

defmodule Arbor.MCP.Test.Support.Transports.Http do
  @moduledoc """
  HTTP transport test helper with SecurityGuard integration.

  Provides test HTTP endpoints that integrate with SecurityGuard middleware
  for testing security policies across HTTP transport.
  """

  use GenServer

  alias Arbor.MCP.Transport.SecurityGuard

  defstruct [:port, :server_pid, :security_guard, :requests, :responses]

  @doc """
  Starts a test HTTP endpoint with SecurityGuard middleware.

  ## Options
  - `:security_guard` - SecurityGuard module to use for validation
  - `:port` - Port to bind to (defaults to random available port)

  ## Returns
  `{:ok, endpoint}` where endpoint can be used with `request/3`
  """
  def start_test_endpoint(opts \\ []) do
    security_guard = Keyword.get(opts, :security_guard, SecurityGuard)
    port = Keyword.get(opts, :port, 0)

    state = %__MODULE__{
      port: port,
      security_guard: security_guard,
      requests: [],
      responses: %{}
    }

    case GenServer.start_link(__MODULE__, state) do
      {:ok, pid} ->
        # Return endpoint reference that can be used with request/3
        {:ok, %{pid: pid, type: :http, port: port}}

      error ->
        error
    end
  end

  @doc """
  Sends a request through the HTTP test endpoint with security validation.

  ## Parameters
  - `endpoint` - Endpoint returned from `start_test_endpoint/1`
  - `command` - JSON-RPC command to send
  - `headers` - HTTP headers including authorization

  ## Returns
  - `{:ok, response, received_command}` - Success with response and command after security processing
  - `{:error, reason}` - Security violation or other error
  """
  def request(endpoint, command, headers) do
    GenServer.call(endpoint.pid, {:http_request, command, headers})
  end

  # GenServer implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def handle_call({:http_request, command, headers}, _from, state) do
    # Extract authorization token from headers for security validation
    auth_header =
      Enum.find_value(headers, fn
        {"authorization", "Bearer " <> token} -> token
        {"Authorization", "Bearer " <> token} -> token
        _ -> nil
      end)

    # Extract user ID from token - in a real system this would be done by token validation
    user_id =
      if auth_header do
        case String.split(auth_header, "-") do
          ["secret", "test", "token", "for", user_id] -> user_id
          _ -> "test_user"
        end
      else
        "anonymous"
      end

    # For HTTP transport, validate based on the resource being accessed
    # Handle both string and atom keys since test data comes with atom keys
    method = Map.get(command, "method") || Map.get(command, :method)
    params = Map.get(command, "params") || Map.get(command, :params, %{})
    uri = Map.get(params, "uri") || Map.get(params, :uri)

    case method do
      "resources/read" when not is_nil(uri) ->
        validate_http_resource_security(uri, headers, user_id, command, state)

      "resources/list" when not is_nil(uri) ->
        validate_http_resource_security(uri, headers, user_id, command, state)

      _ ->
        # Other methods, simulate successful response
        received_command =
          if auth_header do
            Map.put(command, :meta, %{token: auth_header})
          else
            command
          end

        response = %{
          "jsonrpc" => "2.0",
          "result" => %{"status" => "success"},
          "id" => Map.get(command, "id") || Map.get(command, :id, 1)
        }

        {:reply, {:ok, response, received_command}, state}
    end
  end

  defp validate_http_resource_security(uri, headers, user_id, command, state) do
    # Only validate external URIs
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        # External resource, validate with SecurityGuard
        security_request = %{
          url: uri,
          headers: headers,
          method: "GET",
          transport: :http,
          user_id: user_id
        }

        config = %{
          consent_handler: Arbor.MCP.ConsentHandler.Test,
          trusted_hosts: ["localhost", "127.0.0.1"]
        }

        case SecurityGuard.validate_request(security_request, config) do
          {:ok, _sanitized_request} ->
            # Security passed
            response = %{
              "jsonrpc" => "2.0",
              "result" => %{"content" => "Resource content"},
              "id" => Map.get(command, "id", 1)
            }

            # Add token to command metadata for verification in tests
            auth_header =
              Enum.find_value(headers, fn
                {"authorization", "Bearer " <> token} -> token
                {"Authorization", "Bearer " <> token} -> token
                _ -> nil
              end)

            received_command =
              if auth_header do
                Map.put(command, :meta, %{token: auth_header})
              else
                command
              end

            {:reply, {:ok, response, received_command}, state}

          {:error, %Arbor.MCP.Transport.SecurityError{type: type}} ->
            # Security violation
            {:reply, {:error, type}, state}
        end

      _ ->
        # Local URI, allow through
        response = %{
          "jsonrpc" => "2.0",
          "result" => %{"content" => "Local resource content"},
          "id" => Map.get(command, "id", 1)
        }

        # Add token to command metadata for verification
        auth_header =
          Enum.find_value(headers, fn
            {"authorization", "Bearer " <> token} -> token
            {"Authorization", "Bearer " <> token} -> token
            _ -> nil
          end)

        received_command =
          if auth_header do
            Map.put(command, :meta, %{token: auth_header})
          else
            command
          end

        {:reply, {:ok, response, received_command}, state}
    end
  end
end

defmodule Arbor.MCP.Test.Support.Transports.Stdio do
  @moduledoc """
  Stdio transport test helper with SecurityGuard integration.

  Provides test stdio processes that integrate with SecurityGuard middleware
  for testing security policies across stdio transport.
  """

  use GenServer

  alias Arbor.MCP.Transport.SecurityGuard

  defstruct [:security_guard, :requests, :responses]

  @doc """
  Starts a test stdio process with SecurityGuard middleware.

  ## Options
  - `:security_guard` - SecurityGuard module to use for validation

  ## Returns
  `{:ok, pid}` where pid can be used with `request/2`
  """
  def start_test_process(opts \\ []) do
    security_guard = Keyword.get(opts, :security_guard, SecurityGuard)

    state = %__MODULE__{
      security_guard: security_guard,
      requests: [],
      responses: %{}
    }

    GenServer.start_link(__MODULE__, state)
  end

  @doc """
  Sends a request through the stdio test process with security validation.

  ## Parameters
  - `pid` - Process PID returned from `start_test_process/1`
  - `command` - JSON-RPC command to send

  ## Returns
  - `{:ok, response, received_command}` - Success with response and command after security processing
  - `{:error, reason}` - Security violation or other error
  """
  def request(pid, command) do
    GenServer.call(pid, {:stdio_request, command})
  end

  # GenServer implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:stdio_request, command}, _from, state) do
    # Extract token from command metadata
    token = get_in(command, [:meta, :token])

    # Check if this is a resource request that needs security validation
    # Handle both string and atom keys since test data comes with atom keys
    method = Map.get(command, "method") || Map.get(command, :method)
    params = Map.get(command, "params") || Map.get(command, :params, %{})
    uri = Map.get(params, "uri") || Map.get(params, :uri)

    case method do
      "resources/read" when not is_nil(uri) ->
        validate_stdio_security(uri, token, command, state)

      "resources/list" when not is_nil(uri) ->
        validate_stdio_security(uri, token, command, state)

      _ ->
        # Non-resource request, allow through
        response = %{
          "jsonrpc" => "2.0",
          "result" => %{"status" => "success"},
          "id" => Map.get(command, "id") || Map.get(command, :id, 1)
        }

        received_command = Map.delete(command, :meta)
        {:reply, {:ok, response, received_command}, state}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_stdio_security(uri, token, command, state) do
    # Extract user ID from token - in a real system this would be done by token validation
    user_id =
      if token do
        case String.split(token, "-") do
          ["secret", "test", "token", "for", user_id] -> user_id
          _ -> "test_user"
        end
      else
        "anonymous"
      end

    # Only validate external URIs
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        # External resource, validate with SecurityGuard
        security_request = %{
          url: uri,
          headers: if(token, do: [{"Authorization", "Bearer #{token}"}], else: []),
          method: "GET",
          transport: :stdio,
          user_id: user_id
        }

        config = %{
          consent_handler: Arbor.MCP.ConsentHandler.Test,
          trusted_hosts: ["localhost", "127.0.0.1"]
        }

        case SecurityGuard.validate_request(security_request, config) do
          {:ok, _sanitized_request} ->
            # Security passed
            response = %{
              "jsonrpc" => "2.0",
              "result" => %{"content" => "Resource content"},
              "id" => Map.get(command, "id", 1)
            }

            received_command = Map.delete(command, :meta)
            {:reply, {:ok, response, received_command}, state}

          {:error, %Arbor.MCP.Transport.SecurityError{type: type}} ->
            # Security violation
            {:reply, {:error, type}, state}
        end

      _ ->
        # Local URI, allow through
        response = %{
          "jsonrpc" => "2.0",
          "result" => %{"content" => "Local resource content"},
          "id" => Map.get(command, "id", 1)
        }

        received_command = Map.delete(command, :meta)
        {:reply, {:ok, response, received_command}, state}
    end
  end
end

defmodule Arbor.MCP.Test.Support.Transports.Beam do
  @moduledoc """
  BEAM transport test helper with SecurityGuard integration.

  Provides test BEAM servers that integrate with SecurityGuard middleware
  for testing security policies across BEAM transport.
  """

  use GenServer

  alias Arbor.MCP.Transport.SecurityGuard

  defstruct [:security_guard, :requests, :responses]

  @doc """
  Starts a test BEAM server with SecurityGuard middleware.

  ## Options
  - `:security_guard` - SecurityGuard module to use for validation

  ## Returns
  `{:ok, pid}` where pid can be used with `request/2`
  """
  def start_test_server(opts \\ []) do
    security_guard = Keyword.get(opts, :security_guard, SecurityGuard)

    state = %__MODULE__{
      security_guard: security_guard,
      requests: [],
      responses: %{}
    }

    GenServer.start_link(__MODULE__, state)
  end

  @doc """
  Sends a request through the BEAM test server with security validation.

  ## Parameters
  - `pid` - Process PID returned from `start_test_server/1`
  - `command` - JSON-RPC command to send

  ## Returns
  - `{:ok, response, received_command}` - Success with response and command after security processing
  - `{:error, reason}` - Security violation or other error
  """
  def request(pid, command) do
    GenServer.call(pid, {:beam_request, command})
  end

  # GenServer implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:beam_request, command}, _from, state) do
    # Extract token from command metadata
    token = get_in(command, [:meta, :token])

    # BEAM transport - validate external resource access
    # Handle both string and atom keys since test data comes with atom keys
    method = Map.get(command, "method") || Map.get(command, :method)
    params = Map.get(command, "params") || Map.get(command, :params, %{})
    uri = Map.get(params, "uri") || Map.get(params, :uri)

    case method do
      "resources/read" when not is_nil(uri) ->
        validate_beam_resource_security(uri, token, command, state)

      "resources/list" when not is_nil(uri) ->
        validate_beam_resource_security(uri, token, command, state)

      method when method in ["tools/call"] ->
        # Tools might access external resources, validate if token present
        validate_beam_security(token, command, state)

      _ ->
        # Other methods, allow through
        response = %{
          "jsonrpc" => "2.0",
          "result" => %{"status" => "success"},
          "id" => Map.get(command, "id") || Map.get(command, :id, 1)
        }

        received_command = Map.delete(command, :meta)
        {:reply, {:ok, response, received_command}, state}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_beam_resource_security(uri, token, command, state) do
    # Extract user ID from token
    user_id =
      if token do
        case String.split(token, "-") do
          ["secret", "test", "token", "for", user_id] -> user_id
          _ -> "test_user"
        end
      else
        "anonymous"
      end

    # Only validate external URIs
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        # External resource, validate with SecurityGuard
        security_request = %{
          url: uri,
          headers: if(token, do: [{"Authorization", "Bearer #{token}"}], else: []),
          method: "GET",
          transport: :beam,
          user_id: user_id
        }

        config = %{
          consent_handler: Arbor.MCP.ConsentHandler.Test,
          trusted_hosts: ["localhost", "127.0.0.1"]
        }

        case SecurityGuard.validate_request(security_request, config) do
          {:ok, _sanitized_request} ->
            # Security passed
            response = %{
              "jsonrpc" => "2.0",
              "result" => %{"content" => "Resource content"},
              "id" => Map.get(command, "id", 1)
            }

            received_command = Map.delete(command, :meta)
            {:reply, {:ok, response, received_command}, state}

          {:error, %Arbor.MCP.Transport.SecurityError{type: type}} ->
            # Security violation
            {:reply, {:error, type}, state}
        end

      _ ->
        # Local URI, allow through
        response = %{
          "jsonrpc" => "2.0",
          "result" => %{"content" => "Local resource content"},
          "id" => Map.get(command, "id", 1)
        }

        received_command = Map.delete(command, :meta)
        {:reply, {:ok, response, received_command}, state}
    end
  end

  defp validate_beam_security(token, command, state) do
    # For BEAM transport, we simulate security validation based on presence of token
    if token do
      # Assume token provides access - validate with SecurityGuard
      security_request = %{
        url: "beam://localhost/mcp",
        headers: [{"Authorization", "Bearer #{token}"}],
        method: "BEAM",
        transport: :beam,
        user_id: "test_user"
      }

      config = %{
        consent_handler: Arbor.MCP.ConsentHandler.Test,
        trusted_hosts: ["localhost", "127.0.0.1"]
      }

      case SecurityGuard.validate_request(security_request, config) do
        {:ok, _sanitized_request} ->
          # Security passed
          response = %{
            "jsonrpc" => "2.0",
            "result" => %{"status" => "authorized"},
            "id" => Map.get(command, "id", 1)
          }

          received_command = Map.delete(command, :meta)
          {:reply, {:ok, response, received_command}, state}

        {:error, _security_error} ->
          # Security violation
          {:reply, {:error, :consent_required}, state}
      end
    else
      # No token provided
      {:reply, {:error, :consent_required}, state}
    end
  end
end
