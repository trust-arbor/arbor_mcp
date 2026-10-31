if Code.ensure_loaded?(Plug) do
  defmodule ExMCP.Transport.HTTPServer do
    @moduledoc deprecated:
                 "Use ExMCP.HttpPlug instead. ExMCP.Transport.HTTPServer will be removed in 2.0.0."
    @moduledoc """
      HTTP server transport for MCP with security and CORS support.

      > #### Deprecated {: .error}
      >
      > This module is deprecated and will be removed in 2.0.0. It reads the
      > request body itself, so it cannot run behind `Plug.Parsers` (every POST
      > forwarded from a stock Phoenix router fails with "Invalid JSON"), its
      > SSE route only matches at the host root, and its `initialize` response
      > is canned. Use `ExMCP.HttpPlug`, which handles all of these.

      This module provides a Plug-compatible HTTP server that handles MCP requests
      with comprehensive security features including:

      - Origin header validation (DNS rebinding protection)
      - CORS headers with configurable policies
      - Security headers (XSS, frame options, etc.)
      - HTTPS enforcement
      - Request validation

      > #### Simplified example transport {: .warning}
      >
      > This Plug is retained as a simplified example and includes a canned
      > `initialize` response. It is not the production HTTP server path. Use
      > `ExMCP.HttpPlug` for protocol-complete HTTP deployments.

      ## Usage with Phoenix

          # In your router
          scope "/mcp" do
            forward "/", ExMCP.Transport.HTTPServer,
              handler: MyMCPHandler,
              security: %{
              validate_origin: true,
              allowed_origins: ["https://app.example.com"],
              cors: %{
                allowed_methods: ["GET", "POST", "OPTIONS"],
                allowed_headers: ["Content-Type", "Authorization"],
                allow_credentials: true
              }
            }
        end

    ## Usage with Plug.Router

        defmodule MyMCPRouter do
          use Plug.Router

          plug :match
          plug :dispatch

          forward "/mcp", to: ExMCP.Transport.HTTPServer,
            init_opts: [
              handler: MyMCPHandler,
              security: %{validate_origin: true}
            ]
        end

    ## Security Configuration

    The `:security` option accepts:

    - `validate_origin: boolean()` - Enable origin validation (default: true)
    - `allowed_origins: [String.t()]` - List of allowed origins
    - `allowed_hosts: [String.t()]` - List of allowed host headers
    - `enforce_https: boolean()` - Require HTTPS for non-localhost (default: true)
    - `cors: map()` - CORS configuration
    - `include_security_headers: boolean()` - Include standard security headers (default: true)
    """

    import Plug.Conn
    require Logger

    alias ExMCP.Internal.{Protocol, Security}
    alias ExMCP.Protocol.Initialize
    alias ExMCP.Server.HandlerServer, as: Server

    @behaviour Plug

    @deprecated "Use ExMCP.HttpPlug instead. ExMCP.Transport.HTTPServer will be removed in 2.0.0."
    @doc """
    Initializes the HTTP server with configuration.
    """
    def init(opts) do
      warn_deprecated()
      handler = Keyword.fetch!(opts, :handler)
      security_config = Keyword.get(opts, :security, %{})

      # Set secure defaults
      security_config =
        Map.merge(
          %{
            validate_origin: true,
            enforce_https: true,
            include_security_headers: true
          },
          security_config
        )

      %{
        handler: handler,
        security: security_config,
        cors: Map.get(security_config, :cors, %{})
      }
    end

    @deprecated "Use ExMCP.HttpPlug instead. ExMCP.Transport.HTTPServer will be removed in 2.0.0."
    @doc """
    Handles HTTP requests for MCP.
    """
    def call(conn, config) do
      conn
      |> put_private(:mcp_config, config)
      |> handle_request()
    rescue
      error ->
        Logger.error("MCP HTTP transport error: #{inspect(error)}")
        send_error_response(conn, 500, "Internal server error")
    end

    defp handle_request(conn) do
      config = conn.private.mcp_config

      # Validate security requirements
      case validate_security(conn, config.security) do
        :ok ->
          conn
          |> add_security_headers(config.security)
          |> handle_method(config)

        {:error, reason} ->
          Logger.warning("Security validation failed: #{inspect(reason)}")
          send_security_error(conn, reason)
      end
    end

    defp validate_security(conn, security_config) do
      # Build headers list including host from conn
      headers = [{"host", conn.host} | conn.req_headers]
      Security.validate_request(headers, security_config)
    end

    defp add_security_headers(conn, security_config) do
      conn =
        if Map.get(security_config, :include_security_headers, true) do
          Security.build_standard_security_headers()
          |> Enum.reduce(conn, fn {name, value}, acc ->
            put_resp_header(acc, String.downcase(name), value)
          end)
        else
          conn
        end

      # Add CORS headers if configured
      cors_config = Map.get(security_config, :cors, %{})

      if cors_config != %{} do
        origin = get_req_header(conn, "origin") |> List.first()

        Security.build_cors_headers(cors_config, origin)
        |> Enum.reduce(conn, fn {name, value}, acc ->
          put_resp_header(acc, String.downcase(name), value)
        end)
      else
        conn
      end
    end

    defp handle_method(%{method: "OPTIONS"} = conn, _config) do
      # Handle CORS preflight
      conn
      |> send_resp(200, "")
    end

    defp handle_method(%{method: "POST"} = conn, config) do
      handle_mcp_request(conn, config)
    end

    defp handle_method(%{method: "GET", request_path: path} = conn, config)
         when path in ["/sse", "/events"] do
      handle_sse_request(conn, config)
    end

    defp handle_method(conn, _config) do
      send_error_response(conn, 405, "Method not allowed")
    end

    defp handle_mcp_request(conn, config) do
      case read_body(conn, length: 1_000_000) do
        {:ok, body, conn} ->
          process_mcp_message(conn, body, config)

        {:error, reason} ->
          Logger.warning("Failed to read request body: #{inspect(reason)}")
          send_error_response(conn, 400, "Invalid request body")
      end
    end

    defp process_mcp_message(conn, body, config) do
      case Jason.decode(body) do
        {:ok, message} ->
          handle_parsed_message(conn, message, config)

        {:error, reason} ->
          Logger.warning("JSON decode error: #{inspect(reason)}")
          send_error_response(conn, 400, "Invalid JSON")
      end
    end

    defp handle_parsed_message(conn, message, config) do
      # Start a temporary MCP server to handle the request
      {:ok, server_pid} = start_temporary_server(config.handler)

      try do
        # Process the MCP message
        # Check if it's a batch request first
        case message do
          messages when is_list(messages) ->
            handle_mcp_batch(conn, server_pid, messages)

          _ ->
            case Protocol.parse_message(message) do
              {:request, method, params, id} ->
                handle_mcp_method(conn, server_pid, method, params, id)

              {:notification, method, params} ->
                handle_mcp_notification(conn, server_pid, method, params)

              _ ->
                send_error_response(conn, 400, "Invalid MCP message format")
            end
        end
      after
        # Clean up the temporary server
        if Process.alive?(server_pid) do
          GenServer.stop(server_pid)
        end
      end
    end

    defp start_temporary_server(handler) do
      # Start a temporary server for this request
      Server.start_link(
        handler: handler,
        transport: :test
        # No name - let it be anonymous
      )
    end

    defp handle_mcp_method(conn, server_pid, method, params, id) do
      # Forward the method to the server and get response
      case call_server_method(server_pid, method, params) do
        {:ok, result} ->
          response = Protocol.encode_response(result, id)
          send_json_response(conn, 200, response)

        {:error, error} ->
          response =
            Protocol.encode_error(
              -32603,
              "Internal error",
              to_string(error),
              id
            )

          send_json_response(conn, 200, response)
      end
    end

    defp handle_mcp_notification(conn, _server_pid, _method, _params) do
      # Notifications don't require a response
      send_resp(conn, 200, "")
    end

    defp handle_mcp_batch(conn, server_pid, messages) do
      # Process each message in the batch
      responses =
        Enum.map(messages, fn message ->
          case Protocol.parse_message(message) do
            {:request, method, params, id} ->
              case call_server_method(server_pid, method, params) do
                {:ok, result} ->
                  Protocol.encode_response(result, id)

                {:error, error} ->
                  Protocol.encode_error(
                    -32603,
                    "Internal error",
                    to_string(error),
                    id
                  )
              end

            _ ->
              # Skip non-request messages in batch
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      send_json_response(conn, 200, responses)
    end

    defp call_server_method(server_pid, method, params) do
      # Simplified example mapping; production servers use ExMCP.HttpPlug.
      case method do
        "initialize" ->
          {:ok,
           Initialize.build_initialize_result(params, %{
             serverInfo: %{name: "http-server", version: "1.0.0"},
             capabilities: %{}
           })}

        "tools/list" ->
          # Call the actual server
          GenServer.call(server_pid, {:handle_list_tools, nil})

        _ ->
          {:error, "Method not implemented: #{method}"}
      end
    rescue
      error ->
        {:error, "Server error: #{inspect(error)}"}
    end

    defp handle_sse_request(conn, _config) do
      # Set up Server-Sent Events
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      # Send initial connection event
      {:ok, conn} = chunk(conn, "event: connect\ndata: {\"type\":\"connected\"}\n\n")

      # Keep connection alive (in real implementation, this would be managed differently)
      Process.sleep(100)
      {:ok, conn} = chunk(conn, "event: ping\ndata: {\"type\":\"ping\"}\n\n")

      conn
    end

    defp send_security_error(conn, reason) do
      {status, message} =
        case reason do
          :origin_header_required -> {400, "Origin header required"}
          :origin_not_allowed -> {403, "Origin not allowed"}
          :host_header_required -> {400, "Host header required"}
          :host_not_allowed -> {403, "Host not allowed"}
          :https_required -> {400, "HTTPS required"}
        end

      send_error_response(conn, status, message)
    end

    defp send_error_response(conn, status, message) do
      error_response = %{
        error: %{
          code: -32600,
          message: message
        }
      }

      send_json_response(conn, status, error_response)
    end

    defp send_json_response(conn, status, data) do
      case Jason.encode(data) do
        {:ok, json} ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(status, json)

        {:error, reason} ->
          Logger.error("JSON encoding error: #{inspect(reason)}")
          send_resp(conn, 500, "Internal server error")
      end
    end

    # Phoenix `forward` calls `init/1` on every request, so warn once per VM
    # rather than once per request.
    defp warn_deprecated do
      unless :persistent_term.get({__MODULE__, :deprecation_warned}, false) do
        :persistent_term.put({__MODULE__, :deprecation_warned}, true)

        Logger.warning(
          "ExMCP.Transport.HTTPServer is deprecated and will be removed in 2.0.0. " <>
            "Use ExMCP.HttpPlug instead."
        )
      end
    end
  end
end
