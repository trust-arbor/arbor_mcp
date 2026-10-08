defmodule Arbor.MCP.Test.HTTPServer do
  @moduledoc """
  Simple HTTP server for testing SSE and other HTTP-based transports.
  """
  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:port, :ref, :requests, :sse_clients]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(server) do
    if Process.alive?(server) do
      GenServer.stop(server)
    else
      :ok
    end
  end

  def get_url(server) do
    GenServer.call(server, :get_url)
  end

  def get_requests(server) do
    GenServer.call(server, :get_requests)
  end

  def get_last_request(server) do
    GenServer.call(server, :get_last_request)
  end

  def clear_requests(server) do
    GenServer.call(server, :clear_requests)
  end

  def send_sse_event(server, data) do
    GenServer.call(server, {:send_sse_event, data})
  end

  def get_last_headers(server) do
    case get_last_request(server) do
      %{headers: headers} -> headers
      _ -> %{}
    end
  end

  def close_sse_connections(server) do
    GenServer.call(server, :close_sse_connections)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    port = opts[:port] || 0
    ref = make_ref()

    # Start the HTTP server
    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           # Standard endpoints
           {"/mcp/v1/sse", Arbor.MCP.Test.HTTPServer.SSEHandler, [server: self()]},
           {"/mcp/v1/messages", Arbor.MCP.Test.HTTPServer.MessageHandler, [server: self()]},
           # Support custom endpoints for testing
           {"/custom/api/sse", Arbor.MCP.Test.HTTPServer.SSEHandler, [server: self()]},
           {"/custom/api/messages", Arbor.MCP.Test.HTTPServer.MessageHandler, [server: self()]},
           {"/v2/mcp/sse", Arbor.MCP.Test.HTTPServer.SSEHandler, [server: self()]},
           {"/v2/mcp/messages", Arbor.MCP.Test.HTTPServer.MessageHandler, [server: self()]},
           {"/api/mcp/sse", Arbor.MCP.Test.HTTPServer.SSEHandler, [server: self()]},
           {"/api/mcp/messages", Arbor.MCP.Test.HTTPServer.MessageHandler, [server: self()]},
           {"/api/messages", Arbor.MCP.Test.HTTPServer.MessageHandler, [server: self()]},
           {"/api/sse", Arbor.MCP.Test.HTTPServer.SSEHandler, [server: self()]},
           {"/messages", Arbor.MCP.Test.HTTPServer.MessageHandler, [server: self()]},
           {"/sse", Arbor.MCP.Test.HTTPServer.SSEHandler, [server: self()]},
           {:_, Arbor.MCP.Test.HTTPServer.NotFoundHandler, []}
         ]}
      ])

    {:ok, _} =
      :cowboy.start_clear(
        ref,
        [{:port, port}],
        %{env: %{dispatch: dispatch}}
      )

    # Get actual port
    actual_port = :ranch.get_port(ref)

    {:ok,
     %State{
       port: actual_port,
       ref: ref,
       requests: [],
       sse_clients: []
     }}
  end

  @impl true
  def terminate(_reason, state) do
    :cowboy.stop_listener(state.ref)
    :ok
  end

  @impl true
  def handle_call(:get_url, _from, state) do
    {:reply, "http://localhost:#{state.port}", state}
  end

  @impl true
  def handle_call(:get_requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  @impl true
  def handle_call(:get_last_request, _from, state) do
    {:reply, List.first(state.requests), state}
  end

  @impl true
  def handle_call(:clear_requests, _from, state) do
    {:reply, :ok, %{state | requests: []}}
  end

  @impl true
  def handle_call({:add_request, request}, _from, state) do
    {:reply, :ok, %{state | requests: [request | state.requests]}}
  end

  @impl true
  def handle_call({:add_sse_client, client_pid}, _from, state) do
    {:reply, :ok, %{state | sse_clients: [client_pid | state.sse_clients]}}
  end

  @impl true
  def handle_call({:send_sse_event, data}, _from, state) do
    # Send event to all connected SSE clients
    for client_pid <- state.sse_clients do
      send(client_pid, {:send_event, data})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:close_sse_connections, _from, state) do
    # Close all SSE connections
    for client_pid <- state.sse_clients do
      send(client_pid, :close)
    end

    {:reply, :ok, %{state | sse_clients: []}}
  end
end

defmodule Arbor.MCP.Test.HTTPServer.MessageHandler do
  @moduledoc false
  require Logger

  def init(req, opts) do
    server = Keyword.get(opts, :server)

    # Read body
    {:ok, body, req2} = :cowboy_req.read_body(req)

    # Parse JSON body
    case Jason.decode(body) do
      {:ok, json} ->
        # Extract headers
        headers = :cowboy_req.headers(req2)
        auth = headers["authorization"]
        origin = headers["origin"]

        # Store request
        request = %{
          path: :cowboy_req.path(req2),
          method: :cowboy_req.method(req2),
          headers: headers,
          body: json,
          auth: auth,
          origin: origin,
          timestamp: System.system_time(:millisecond)
        }

        GenServer.call(server, {:add_request, request})

        # Send response
        response = %{
          "jsonrpc" => "2.0",
          "id" => Map.get(json, "id"),
          "result" => %{
            "content" => [
              %{"type" => "text", "text" => "Test response"}
            ]
          }
        }

        resp_body = Jason.encode!(response)

        req3 =
          :cowboy_req.reply(
            200,
            %{
              "content-type" => "application/json"
            },
            resp_body,
            req2
          )

        {:ok, req3, opts}

      {:error, reason} ->
        Logger.error("Failed to parse JSON: #{inspect(reason)}, body: #{inspect(body)}")

        req3 =
          :cowboy_req.reply(
            400,
            %{
              "content-type" => "application/json"
            },
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "error" => %{
                "code" => -32700,
                "message" => "Parse error"
              }
            }),
            req2
          )

        {:ok, req3, opts}
    end
  rescue
    e ->
      Logger.error("Error in MessageHandler: #{inspect(e)}")
      Logger.error(Exception.format(:error, e, __STACKTRACE__))

      req3 =
        :cowboy_req.reply(
          500,
          %{
            "content-type" => "text/plain"
          },
          "Internal server error",
          req
        )

      {:ok, req3, opts}
  end
end

defmodule Arbor.MCP.Test.HTTPServer.SSEHandler do
  @moduledoc false

  def init(req, opts) do
    server = Keyword.get(opts, :server)

    # Generate client ID
    client_id = :crypto.strong_rand_bytes(16) |> Base.encode16()

    # Store SSE connection
    headers = :cowboy_req.headers(req)

    request = %{
      type: :sse_connect,
      client_id: client_id,
      headers: headers,
      path: :cowboy_req.path(req),
      timestamp: System.system_time(:millisecond)
    }

    GenServer.call(server, {:add_request, request})
    GenServer.call(server, {:add_sse_client, self()})

    # Send SSE headers
    req2 =
      :cowboy_req.stream_reply(
        200,
        %{
          "content-type" => "text/event-stream",
          "cache-control" => "no-cache",
          "connection" => "keep-alive",
          "access-control-allow-origin" => "*"
        },
        req
      )

    # Send initial event after a small delay to ensure client is ready
    Process.send_after(self(), :send_initial_event, 50)

    # Keep connection alive
    sse_loop(req2, client_id)
  end

  defp sse_loop(req, client_id) do
    receive do
      :send_initial_event ->
        :cowboy_req.stream_body(
          ~s(event: connected\ndata: {"clientId":"#{client_id}"}\n\n),
          :nofin,
          req
        )

        sse_loop(req, client_id)

      {:send_event, event} ->
        :cowboy_req.stream_body(event, :nofin, req)
        sse_loop(req, client_id)

      :close ->
        :cowboy_req.stream_body("", :fin, req)
        {:ok, req, []}
    after
      30_000 ->
        # Send ping
        :cowboy_req.stream_body(":ping\n\n", :nofin, req)
        sse_loop(req, client_id)
    end
  end
end

defmodule Arbor.MCP.Test.HTTPServer.NotFoundHandler do
  @moduledoc false

  def init(req, opts) do
    req2 =
      :cowboy_req.reply(
        404,
        %{
          "content-type" => "text/plain"
        },
        "Not found",
        req
      )

    {:ok, req2, opts}
  end
end
