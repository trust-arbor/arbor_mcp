defmodule Arbor.MCP.HttpPlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, except: [get_session: 1, get_session: 2]
  import ExUnit.CaptureLog

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.HttpPlug.Core
  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.SessionManager
  alias Arbor.MCP.Test.RuntimeHTTPFixture
  alias Arbor.MCP.Transport.HTTP.RequestHeaders

  defmodule LegacyCaptureConn do
    @behaviour Arbor.MCP.HttpPlug.SSEConnection

    defstruct chunks: []

    @impl true
    def chunk(%__MODULE__{} = conn, data), do: {:ok, %{conn | chunks: conn.chunks ++ [data]}}

    @impl true
    def get_req_header(%__MODULE__{}, _header), do: []
  end

  defmodule TestServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "test", version: "1.0.0"

    tool "test_tool", "A test tool" do
      input_schema(%{
        type: "object",
        properties: %{
          message: %{type: "string"}
        },
        required: ["message"]
      })

      run(fn %{"message" => message}, state ->
        {:ok, %{content: [%{"type" => "text", "text" => "Echo: #{message}"}]}, state}
      end)
    end
  end

  defmodule PhoenixJsonLibrary do
    def decode!(body), do: Jason.decode!(body)
    def encode!(value), do: Jason.encode!(value)
    def encode_to_iodata!(value), do: Jason.encode!(value)
  end

  defmodule RequestAwareServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_initialize(_params, state) do
      context = Map.new(Context.current().application_context)

      {:ok,
       %{
         name: Map.fetch!(context, :request_path),
         version: Map.fetch!(context, :request_method),
         capabilities: %{}
       }, state}
    end
  end

  defmodule BlockingRequestServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def init(opts) do
      state = Map.new(opts)
      send(state.test_pid, {:blocking_handler_started, self()})
      {:ok, state}
    end

    @impl true
    def handle_list_tools(_cursor, state) do
      receive do
        :unblock -> {:ok, [], nil, state}
      end
    end
  end

  defmodule CapabilityErrorServer do
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_initialize(_params, state), do: {:ok, %{}, state}

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

    @impl true
    def handle_call_tool(_name, _arguments, state) do
      error = Arbor.MCP.Error.missing_required_client_capability(%{"sampling" => %{}})
      {:error, error, state}
    end
  end

  defmodule HeaderToolServer do
    use Arbor.MCP.Server.Handler

    @tool %{
      "name" => "routed_tool",
      "description" => "Exercises x-mcp-header validation",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "region" => %{"type" => "string", "x-mcp-header" => "Region"},
          "limit" => %{"type" => "integer", "x-mcp-header" => "Limit"}
        }
      }
    }

    @impl true
    def handle_list_tools(_cursor, state), do: {:ok, [@tool], nil, state}

    @impl true
    def handle_call_tool(_name, arguments, state) do
      {:ok, %{"content" => [%{"type" => "text", "text" => inspect(arguments)}]}, state}
    end
  end

  describe "HTTP Plug behavior" do
    test "implements Plug behavior correctly" do
      Code.ensure_loaded!(HttpPlug)

      assert function_exported?(HttpPlug, :init, 1)
      assert function_exported?(HttpPlug, :call, 2)
    end

    test "init/1 sets up configuration" do
      opts = [
        handler: TestServer,
        server_info: %{name: "test", version: "1.0.0"}
      ]

      config = mount_opts(opts)

      assert {:ok, _ref} = Runtime.ref(config.runtime)
      assert config.server_info.name == "test"
      refute Map.has_key?(config, :sse_enabled)
      refute Map.has_key?(config, :handler)
      assert config.legacy_http_sse == false
      assert config.cors_enabled == false
      assert config.validate_origin == true
      assert config.allowed_origins == []
      assert config.allowed_hosts == :any
      assert config.body_limit == 1_000_000
      assert config.handler_opts == []
      refute Map.has_key?(config, :handler_call_timeout)
      assert config.subscription_max_message_bytes == nil
      assert config.subscription_max_queue_bytes == nil
    end

    test "init/1 preserves subscription byte limits" do
      config =
        mount_opts(
          handler: TestServer,
          subscription_max_message_bytes: 12_345,
          subscription_max_queue_bytes: 67_890
        )

      assert config.subscription_max_message_bytes == 12_345
      assert config.subscription_max_queue_bytes == 67_890
    end

    test "init/1 accepts a server-side handler call deadline" do
      assert_raise ArgumentError, ~r/retired/, fn ->
        HttpPlug.init(runtime: __MODULE__.Unavailable, handler_call_timeout: 250)
      end
    end

    test "default initialized options are safe to embed at compile time" do
      assert Macro.escape(HttpPlug.init(runtime: __MODULE__.NamedRuntime))
    end

    test "retires sse_enabled while retaining explicit legacy HTTP transport" do
      assert_raise ArgumentError, ~r/retired/, fn ->
        HttpPlug.init(runtime: __MODULE__.Unavailable, sse_enabled: true)
      end

      assert mount_opts(legacy_http_sse: true).legacy_http_sse == true
    end

    test "normalizes legacy HTTP+SSE paths" do
      config =
        mount_opts(legacy_http_sse_path: "events", legacy_http_sse_post_path: "inbox")

      assert config.legacy_http_sse_path == "/events"
      assert config.legacy_http_sse_post_path == "/inbox"
    end

    test "init/1 resolves the SSE mode instead of branching at request time" do
      assert mount_opts(sse_mode: :stream).sse_mode == :stream
      assert mount_opts(sse_mode: :oneshot).sse_mode == :oneshot
      assert mount_opts([]).sse_mode in [:stream, :oneshot]
    end
  end

  describe "session deletion" do
    test "DELETE uses the runtime-owned session service" do
      opts = mount_opts(handler: TestServer)
      initialized = initialize_session_conn(1_200) |> call_http(opts)
      [id] = get_resp_header(initialized, "mcp-session-id")
      assert {:ok, %{initialized: true}} = session_state(id)

      result =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> call_http(opts)

      assert result.status == 204
      assert {:error, :session_not_found} = session_state(id)
    end

    test "rejects duplicate session headers without terminating the session" do
      opts = mount_opts(handler: TestServer, sse_enabled: false)
      initialized = initialize_session_conn(1_201) |> call_http(opts)
      [session_id] = get_resp_header(initialized, "mcp-session-id")

      base =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      for values <- [[session_id, session_id], [session_id, "different-session"]] do
        duplicated = %{
          base
          | req_headers:
              Enum.map(values, &{"mcp-session-id", &1}) ++
                Enum.reject(base.req_headers, fn {name, _value} -> name == "mcp-session-id" end)
        }

        rejected = call_http(duplicated, opts)
        assert rejected.status == 400
        assert {:ok, %{initialized: true}} = session_state(session_id)
      end
    end

    test "requires the negotiated protocol version before standard DELETE" do
      previous = Application.get_env(:arbor_mcp, :protocol_version_required)
      Application.put_env(:arbor_mcp, :protocol_version_required, true)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:arbor_mcp, :protocol_version_required),
          else: Application.put_env(:arbor_mcp, :protocol_version_required, previous)
      end)

      opts = mount_opts(handler: TestServer, sse_enabled: false)
      initialized = initialize_session_conn(1_202) |> call_http(opts)
      [session_id] = get_resp_header(initialized, "mcp-session-id")

      missing =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", session_id)
        |> call_http(opts)

      assert missing.status == 400
      assert {:ok, %{initialized: true}} = session_state(session_id)

      mismatched =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-03-26")
        |> call_http(opts)

      assert mismatched.status == 400
      assert {:ok, %{initialized: true}} = session_state(session_id)

      duplicate_base =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", session_id)

      duplicated_version = %{
        duplicate_base
        | req_headers: [
            {"mcp-protocol-version", "2025-06-18"},
            {"mcp-protocol-version", "2025-06-18"} | duplicate_base.req_headers
          ]
      }

      assert call_http(duplicated_version, opts).status == 400
      assert {:ok, %{initialized: true}} = session_state(session_id)

      valid =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> call_http(opts)

      assert valid.status == 204
      assert {:error, :session_not_found} = session_state(session_id)
    end
  end

  describe "handler call timeout" do
    @describetag capture_log: true

    test "runtime request deadline reaps a held callback" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => %{},
        "id" => 41
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_active_legacy_session()
        |> call_http(
          mount_opts(
            handler: BlockingRequestServer,
            handler_args: [test_pid: self()],
            request_timeout_ms: 25,
            sse_enabled: false
          )
        )

      assert conn.status == 200
      assert_received {:blocking_handler_started, _handler_pid}

      assert %{"error" => %{"code" => -32603, "data" => %{"type" => "handler_timeout"}}} =
               Jason.decode!(conn.resp_body)
    end
  end

  describe "CORS handling" do
    test "handles OPTIONS preflight request for explicitly allowed wildcard CORS" do
      conn =
        conn(:options, "/")
        |> call_http(mount_opts(cors_enabled: true, allowed_origins: :any))

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

      assert get_resp_header(conn, "access-control-allow-methods") == [
               "GET, POST, DELETE, OPTIONS"
             ]
    end

    test "rejects OPTIONS when CORS disabled" do
      conn =
        conn(:options, "/")
        |> call_http(mount_opts(cors_enabled: false))

      assert conn.status == 405
    end

    test "rejects browser origins unless explicitly allowed" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://evil.example")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 403
      assert conn.resp_body == "Origin not allowed"
    end

    test "rejects an Origin equal to the request Host when not allow-listed" do
      # DNS rebinding: the Host header is attacker-controlled, so an Origin
      # matching scheme://host:port must not be implicitly trusted.
      # Plug.Test conns use host www.example.com on port 80.
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "http://www.example.com")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 403
      assert conn.resp_body == "Origin not allowed"
    end

    test "allows requests without an Origin header when validate_origin is enabled" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{name: "test-client", version: "1.0.0"}
        },
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false, validate_origin: true))

      assert conn.status == 200
    end

    test "allows explicitly configured browser origins" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{name: "test-client", version: "1.0.0"}
        },
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", "https://client.example")
        |> call_http(
          mount_opts(
            handler: TestServer,
            sse_enabled: false,
            cors_enabled: true,
            allowed_origins: ["https://client.example"]
          )
        )

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://client.example"]
    end
  end

  # Helpers shared by the host validation and session ID validation tests.
  # (Function definitions are not allowed inside describe blocks.)
  defp initialize_conn do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{name: "test-client", version: "1.0.0"}
      },
      "id" => 1
    }

    conn(:post, "/", Jason.encode!(request))
    |> put_req_header("content-type", "application/json")
  end

  # Plug.Test forbids put_req_header("host", _); the Host is modelled by
  # conn.host, which is what HttpPlug falls back to when no header is present.
  defp with_host(conn, host), do: %{conn | host: host}

  defp put_modern_headers(conn, request) do
    meta = get_in(request, ["params", "_meta"])
    version = meta["io.modelcontextprotocol/protocolVersion"]
    method = request["method"]

    conn
    |> put_req_header("mcp-protocol-version", version)
    |> put_req_header("mcp-method", method)
    |> maybe_put_modern_name(method, request["params"] || %{})
  end

  defp maybe_put_modern_name(conn, "tools/call", params),
    do: put_req_header(conn, "mcp-name", RequestHeaders.encode_value(params["name"]))

  defp maybe_put_modern_name(conn, "resources/read", params),
    do: put_req_header(conn, "mcp-name", RequestHeaders.encode_value(params["uri"]))

  defp maybe_put_modern_name(conn, "prompts/get", params),
    do: put_req_header(conn, "mcp-name", RequestHeaders.encode_value(params["name"]))

  defp maybe_put_modern_name(conn, _method, _params), do: conn

  defp modern_request(method, params, id) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp session_request_conn do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/list",
      "id" => 10
    }

    conn(:post, "/", Jason.encode!(request))
    |> put_req_header("content-type", "application/json")
  end

  defp initialize_session_conn(id \\ 10) do
    request = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
      },
      "id" => id
    }

    conn(:post, "/", Jason.encode!(request))
    |> put_req_header("content-type", "application/json")
  end

  defp put_active_legacy_session(conn) do
    put_req_header(conn, "x-fixture-create-session", "true")
  end

  describe "host validation" do
    test "default allowed_hosts :any accepts any Host" do
      conn =
        initialize_conn()
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200
    end

    test "rejects a Host that is not allow-listed with 421" do
      conn =
        initialize_conn()
        |> with_host("evil.example")
        |> call_http(
          mount_opts(handler: TestServer, sse_enabled: false, allowed_hosts: ["localhost"])
        )

      assert conn.status == 421

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"]["code"] == -32600
      assert response["error"]["message"] =~ "Host"
    end

    test "rejects the Plug.Test default host when only localhost is allowed" do
      # No explicit Host header: falls back to conn.host (www.example.com).
      conn =
        initialize_conn()
        |> call_http(
          mount_opts(handler: TestServer, sse_enabled: false, allowed_hosts: ["localhost"])
        )

      assert conn.status == 421
    end

    test "accepts an allow-listed Host" do
      conn =
        initialize_conn()
        |> with_host("localhost")
        |> call_http(
          mount_opts(handler: TestServer, sse_enabled: false, allowed_hosts: ["localhost"])
        )

      assert conn.status == 200
    end

    test "accepts an allow-listed IPv6 Host" do
      conn =
        initialize_conn()
        |> with_host("::1")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false, allowed_hosts: ["::1"]))

      assert conn.status == 200
    end

    # Plug forbids setting the "host" request header directly (it is derived
    # from conn.host), so port and IPv6-bracket normalization is asserted
    # against the function that implements it.
    test "host matching ignores ports and IPv6 brackets" do
      assert Core.host_allowed?("localhost:4000", ["localhost"])
      assert Core.host_allowed?("LOCALHOST:4000", ["localhost"])
      assert Core.host_allowed?("[::1]:8080", ["::1"])
      assert Core.host_allowed?("[::1]:8080", ["[::1]"])
      assert Core.host_allowed?("::1", ["::1"])
      refute Core.host_allowed?("evil.example:8080", ["localhost"])
      refute Core.host_allowed?("evil.example", ["localhost"])
      refute Core.host_allowed?(nil, ["localhost"])
      assert Core.host_allowed?("anything.example", :any)
    end
  end

  describe "session ID validation" do
    test "modern requests are stateless and ignore legacy session headers" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => 9,
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> put_req_header("mcp-session-id", "ignored legacy session")
        |> put_req_header("last-event-id", "ignored-event")
        |> call_http(
          mount_opts(
            handler: TestServer,
            protocol_mode: :modern_only,
            sse_enabled: false
          )
        )

      assert conn.status == 200
      assert get_resp_header(conn, "mcp-session-id") == []
      assert %{"result" => %{"resultType" => "complete"}} = Jason.decode!(conn.resp_body)
      refute_received {:session_ensured, _session_id, _attrs}
    end

    test "legacy requests retain session-scoped behavior" do
      conn =
        initialize_session_conn()
        |> call_http(
          mount_opts(
            handler: TestServer,
            protocol_mode: :prefer_modern,
            sse_enabled: false
          )
        )

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      assert {:ok, %{initialized: true, metadata: %{transport: :http}}} =
               session_state(session_id)
    end

    test "rejects a duplicate request ID in the same legacy session before dispatch" do
      opts =
        mount_opts(
          handler: TestServer,
          protocol_mode: :prefer_modern,
          sse_enabled: false
        )

      initialized = initialize_session_conn(991) |> call_http(opts)
      assert initialized.status == 200
      assert [session_id] = get_resp_header(initialized, "mcp-session-id")

      request = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 991}

      duplicate =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> call_http(opts)

      assert duplicate.status == 400
      assert get_resp_header(duplicate, "mcp-session-id") == [session_id]

      assert %{
               "id" => 991,
               "error" => %{
                 "code" => -32600,
                 "data" => %{"type" => "duplicate_request_id"}
               }
             } = Jason.decode!(duplicate.resp_body)
    end

    test "rejects a second initialize for an established legacy session" do
      opts = mount_opts(handler: TestServer, sse_enabled: false)

      initialized = initialize_session_conn(1_101) |> call_http(opts)
      assert initialized.status == 200
      assert [session_id] = get_resp_header(initialized, "mcp-session-id")

      duplicate =
        initialize_session_conn(1_102)
        |> put_req_header("mcp-session-id", session_id)
        |> call_http(opts)

      assert duplicate.status == 400
      assert get_resp_header(duplicate, "mcp-session-id") == [session_id]

      assert %{
               "id" => 1_102,
               "error" => %{"data" => %{"type" => "session_already_initialized"}}
             } = Jason.decode!(duplicate.resp_body)
    end

    test "rejects requests on a legacy session whose initialization has not completed" do
      session_id = RuntimeHTTPFixture.session(runtime_for(TestServer), false)

      rejected =
        session_request_conn()
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header(
          "mcp-protocol-version",
          Arbor.MCP.Internal.VersionRegistry.latest_version()
        )
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert rejected.status == 400

      assert %{"error" => %{"data" => %{"type" => "session_not_initialized"}}} =
               Jason.decode!(rejected.resp_body)
    end

    test "terminates and does not expose a session when initialization fails" do
      handler = __MODULE__.FailedInitializeServer

      failed =
        initialize_session_conn(1_103)
        |> call_http(mount_opts(handler: handler, sse_enabled: false))

      assert failed.status == 500
      assert get_resp_header(failed, "mcp-session-id") == []
    end

    test "rejects a successful initialize response with a different supported version" do
      handler = __MODULE__.WrongVersionServer

      rejected =
        initialize_session_conn(1_104)
        |> call_http(mount_opts(handler: handler, sse_enabled: false))

      assert rejected.status == 503
      assert get_resp_header(rejected, "mcp-session-id") == []

      assert Jason.decode!(rejected.resp_body)["error"]["data"]["type"] ==
               "session_manager_unavailable"
    end

    test "fails closed with a bounded response when a legacy session reaches its ID cap" do
      Process.put(:http_session_limits, max_request_ids_per_session: 1)

      opts =
        mount_opts(
          handler: TestServer,
          protocol_mode: :prefer_modern,
          sse_enabled: false
        )

      initialized = initialize_session_conn(992) |> call_http(opts)
      assert initialized.status == 200
      assert [session_id] = get_resp_header(initialized, "mcp-session-id")

      request = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 993}

      rejected =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> call_http(opts)

      assert rejected.status == 429
      assert get_resp_header(rejected, "retry-after") == ["1"]
      assert get_resp_header(rejected, "mcp-session-id") == [session_id]

      assert %{
               "id" => 993,
               "error" => %{
                 "code" => -32600,
                 "data" => %{"type" => "request_id_capacity_exceeded"}
               }
             } = Jason.decode!(rejected.resp_body)
    end

    test "a raw manager override is rejected before runtime or request effects" do
      assert_raise ArgumentError, ~r/retired/, fn ->
        HttpPlug.init(runtime: __MODULE__.Unavailable, session_manager: SessionManager)
      end

      assert is_nil(Process.whereis(SessionManager))
    end

    test "rejects a well-formed but unknown UUID session id" do
      uuid = "123e4567-e89b-12d3-a456-426614174000"

      conn =
        initialize_session_conn()
        |> put_req_header("mcp-session-id", uuid)
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 404
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "returns a bounded overload response when session capacity is exhausted" do
      Process.put(:http_session_limits, max_sessions: 1)
      opts = mount_opts(handler: TestServer)
      assert initialize_session_conn(70_001) |> call_http(opts) |> Map.get(:status) == 200

      conn =
        initialize_session_conn()
        |> call_http(
          mount_opts(
            handler: TestServer,
            sse_enabled: false
          )
        )

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["1"]

      assert Jason.decode!(conn.resp_body)["error"]["data"]["type"] ==
               "session_capacity_exceeded"
    end

    test "requires initialization before a headerless legacy request" do
      session_count = session_count()

      conn =
        session_request_conn()
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 400
      assert get_resp_header(conn, "mcp-session-id") == []
      assert Jason.decode!(conn.resp_body)["error"]["message"] == "Session ID required"
      assert session_count() == session_count
    end

    test "does not mint a session for a headerless legacy notification" do
      session_count = session_count()

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{}
      }

      conn =
        conn(:post, "/", Jason.encode!(notification))
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 400
      assert get_resp_header(conn, "mcp-session-id") == []
      assert session_count() == session_count
    end

    test "rejects session ids longer than 128 bytes without echoing them" do
      long_id = String.duplicate("a", 129)

      conn =
        session_request_conn()
        |> put_req_header("mcp-session-id", long_id)
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 400
      assert get_resp_header(conn, "mcp-session-id") == []
      refute conn.resp_body =~ long_id

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"]["code"] == -32600
    end

    test "rejects session ids with control characters" do
      # Injected directly to bypass any header-value validation in Plug.Test.
      base = session_request_conn()
      conn = %{base | req_headers: [{"mcp-session-id", "bad\nid"} | base.req_headers]}

      conn = call_http(conn, mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 400
      assert get_resp_header(conn, "mcp-session-id") == []
      refute conn.resp_body =~ "bad\nid"
    end

    test "rejects session ids with characters outside the token charset" do
      conn =
        session_request_conn()
        |> put_req_header("mcp-session-id", "not a valid id!")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 400
      refute conn.resp_body =~ "not a valid id!"
    end

    test "validates the legacy x-session-id header on POST" do
      conn =
        session_request_conn()
        |> put_req_header("x-session-id", "bad session id")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 400
    end

    test "rejects invalid session ids on SSE connections" do
      conn =
        conn(:get, "/sse")
        |> put_req_header("mcp-session-id", "bad session id")
        |> call_http(mount_opts(sse_enabled: true))

      assert conn.status == 400
    end

    test "rejects invalid session ids on DELETE" do
      conn =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", "bad session id")
        |> call_http(mount_opts([]))

      assert conn.status == 400
    end
  end

  describe "modern-only HTTP methods" do
    test "rejects GET and DELETE on the MCP endpoint with 405" do
      opts =
        mount_opts(
          handler: TestServer,
          path: "/mcp",
          protocol_mode: :modern_only,
          sse_enabled: true
        )

      get_conn =
        conn(:get, "/mcp")
        |> put_req_header("accept", "text/event-stream")
        |> call_http(opts)

      delete_conn =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", "legacy-session")
        |> call_http(opts)

      assert get_conn.status == 405
      assert delete_conn.status == 405
      assert get_resp_header(get_conn, "allow") == ["POST"]
    end

    test "rejects GET and DELETE at the mount root behind a router forward" do
      opts = mount_opts(handler: TestServer, protocol_mode: :modern_only)

      # Phoenix `scope "/api/mcp" do forward "/", Arbor.MCP.HttpPlug` strips the
      # prefix into script_name and leaves an empty path_info.
      forwarded = fn conn ->
        %{conn | script_name: ["api", "mcp"], path_info: []}
      end

      get_conn =
        conn(:get, "/api/mcp")
        |> put_req_header("accept", "text/event-stream")
        |> forwarded.()
        |> call_http(opts)

      delete_conn =
        conn(:delete, "/api/mcp")
        |> put_req_header("mcp-session-id", "legacy-session")
        |> forwarded.()
        |> call_http(opts)

      assert get_conn.status == 405
      assert delete_conn.status == 405
      assert get_resp_header(get_conn, "allow") == ["POST"]
    end
  end

  describe "pipeline termination" do
    test "halts the conn after responding" do
      opts = mount_opts(handler: TestServer, sse_enabled: false)

      post_conn =
        conn(:post, "/", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1}))
        |> put_req_header("content-type", "application/json")
        |> call_http(opts)

      get_conn = conn(:get, "/") |> call_http(opts)

      assert post_conn.state == :sent
      assert post_conn.halted
      assert get_conn.state == :sent
      assert get_conn.halted
    end
  end

  describe "MCP POST requests" do
    test "returns HTTP 400 for invalid modern request metadata" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
          }
        },
        "id" => 101
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32602
    end

    test "stamps valid modern handler results" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        },
        "id" => 102
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(
          mount_opts(
            handler: TestServer,
            server_info: %{name: "configured-server", version: "1"},
            sse_enabled: false
          )
        )

      assert conn.status == 200
      result = Jason.decode!(conn.resp_body)["result"]
      assert result["resultType"] == "complete"

      assert result["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
               "name" => "test",
               "version" => "1.0.0"
             }
    end

    test "serves modern discovery without initialize" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "server/discover",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        },
        "id" => 103
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(
          mount_opts(
            handler: TestServer,
            server_info: %{name: "discoverable", version: "1"},
            protocol_mode: :modern_only,
            sse_enabled: false
          )
        )

      assert conn.status == 200
      result = Jason.decode!(conn.resp_body)["result"]
      assert result["resultType"] == "complete"
      assert result["supportedVersions"] == ["2026-07-28"]
      assert result["capabilities"]["tools"] == %{}
      assert result["ttlMs"] >= 0
      assert result["cacheScope"] in ["public", "private"]
    end

    test "preserves missing client capability errors from handlers" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "needs_sampling",
          "arguments" => %{},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        },
        "id" => 104
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(mount_opts(handler: CapabilityErrorServer, sse_enabled: false))

      assert conn.status == 400
      error = Jason.decode!(conn.resp_body)["error"]
      assert error["code"] == -32021
      assert error["data"]["requiredCapabilities"] == %{"sampling" => %{}}
    end

    test "rejects missing or mismatched modern request headers before dispatch" do
      request = modern_request("tools/list", %{}, 105)

      missing =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert missing.status == 400
      assert Jason.decode!(missing.resp_body)["error"]["code"] == -32020

      mismatched =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> put_req_header("mcp-method", "resources/list")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert mismatched.status == 400
      assert Jason.decode!(mismatched.resp_body)["error"]["code"] == -32020
    end

    test "rejects missing modern body metadata as invalid params" do
      for {params, field} <- [
            {%{}, "_meta"},
            {%{"_meta" => %{"io.modelcontextprotocol/clientCapabilities" => %{}}},
             "io.modelcontextprotocol/protocolVersion"}
          ] do
        request = %{
          "jsonrpc" => "2.0",
          "method" => "server/discover",
          "params" => params,
          "id" => 1051
        }

        conn =
          conn(:post, "/", Jason.encode!(request))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("mcp-protocol-version", "2026-07-28")
          |> put_req_header("mcp-method", "server/discover")
          |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

        assert conn.status == 400
        error = Jason.decode!(conn.resp_body)["error"]
        assert error["code"] == -32602
        assert error["data"]["field"] == field
      end
    end

    test "accepts an encoded Mcp-Name and rejects a name/body mismatch" do
      request =
        modern_request(
          "tools/call",
          %{"name" => "test_tool", "arguments" => %{"message" => "hi"}},
          106
        )

      accepted =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> put_req_header("mcp-name", RequestHeaders.encode_value("test_tool"))
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert accepted.status == 200, accepted.resp_body
      assert get_resp_header(accepted, "mcp-protocol-version") == ["2026-07-28"]

      rejected =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> put_req_header("mcp-name", "another_tool")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert rejected.status == 400
      assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32020
    end

    test "allows extension methods to reach the handler in modern mode" do
      request = modern_request("unknown/modern", %{}, 107)

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32601
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "streams modern subscriptions/listen over the POST response with keepalives" do
      request =
        modern_request(
          "subscriptions/listen",
          %{"notifications" => %{"toolsListChanged" => true}},
          117
        )

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(
          mount_opts(
            handler: TestServer,
            protocol_mode: :modern_only,
            subscription_keepalive_interval_ms: 5,
            subscription_max_lifetime_ms: 1000
          )
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
      assert get_resp_header(conn, "mcp-session-id") == []
      assert conn.resp_body =~ ":\r\n"

      messages =
        conn.resp_body
        |> String.split("\r\n\r\n", trim: true)
        |> Enum.flat_map(fn
          "data: " <> json -> [Jason.decode!(json)]
          _comment -> []
        end)

      assert [acknowledgment, completion] = messages

      assert acknowledgment["method"] == "notifications/subscriptions/acknowledged"
      assert get_in(acknowledgment, ["params", "notifications"]) == %{"toolsListChanged" => true}

      assert completion == %{
               "jsonrpc" => "2.0",
               "id" => 117,
               "result" => %{
                 "resultType" => "complete",
                 "_meta" => %{"io.modelcontextprotocol/subscriptionId" => 117}
               }
             }
    end

    test "rejects an invalid modern subscription filter without opening an SSE stream" do
      request =
        modern_request(
          "subscriptions/listen",
          %{"notifications" => %{"unknownEvents" => true}},
          118
        )

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(mount_opts(handler: TestServer, protocol_mode: :modern_only))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      error = Jason.decode!(conn.resp_body)["error"]
      assert error["code"] == -32602
      assert error["data"]["reason"] == "unknown_subscription_filter"
    end

    test "preserves the missing-capability error for task subscriptions" do
      request =
        modern_request(
          "subscriptions/listen",
          %{"notifications" => %{"taskIds" => ["task-1"]}},
          119
        )

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> call_http(mount_opts(handler: TestServer, protocol_mode: :modern_only))

      assert conn.status == 400
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      error = Jason.decode!(conn.resp_body)["error"]
      assert error["code"] == Arbor.MCP.Protocol.ErrorCodes.missing_required_client_capability()

      assert error["data"] == %{
               "requiredCapabilities" => Arbor.MCP.Tasks.Extension.required_capabilities()
             }
    end

    test "validates x-mcp-header values against tool arguments before dispatch" do
      request =
        modern_request(
          "tools/call",
          %{"name" => "routed_tool", "arguments" => %{"region" => "us-west1", "limit" => 42}},
          108
        )

      accepted =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> put_req_header("mcp-param-region", "us-west1")
        |> put_req_header("mcp-param-limit", "42.0")
        |> call_http(mount_opts(handler: HeaderToolServer, sse_enabled: false))

      assert accepted.status == 200, accepted.resp_body

      missing =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> put_req_header("mcp-param-region", "us-west1")
        |> call_http(mount_opts(handler: HeaderToolServer, sse_enabled: false))

      assert missing.status == 400
      assert Jason.decode!(missing.resp_body)["error"]["code"] == -32020

      mismatched =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_modern_headers(request)
        |> put_req_header("mcp-param-region", "eu-central1")
        |> put_req_header("mcp-param-limit", "42")
        |> call_http(mount_opts(handler: HeaderToolServer, sse_enabled: false))

      assert mismatched.status == 400
      assert Jason.decode!(mismatched.resp_body)["error"]["code"] == -32020
    end

    test "does not expose Mcp-Param values through server logs or telemetry" do
      secret = "header-only-routing-secret"
      handler_id = "mcp-param-confidentiality-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:arbor_mcp, :server, :http, :request],
          fn event, measurements, metadata, owner ->
            send(owner, {:http_telemetry, event, measurements, metadata})
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      request =
        modern_request(
          "tools/call",
          %{"name" => "routed_tool", "arguments" => %{"region" => "body-region", "limit" => 42}},
          109
        )

      log =
        capture_log([level: :debug], fn ->
          conn(:post, "/", Jason.encode!(request))
          |> put_req_header("content-type", "application/json")
          |> put_modern_headers(request)
          |> put_req_header("mcp-param-region", secret)
          |> put_req_header("mcp-param-limit", "42")
          |> call_http(mount_opts(handler: HeaderToolServer, sse_enabled: false))
        end)

      refute log =~ secret

      assert_receive {:http_telemetry, _event, measurements, metadata}
      refute inspect({measurements, metadata}) =~ secret
    end

    test "handles initialize request" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{name: "test-client", version: "1.0.0"}
        },
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert Map.has_key?(response["result"], "protocolVersion")
      assert Map.has_key?(response["result"], "capabilities")
    end

    test "handles a request whose body Plug.Parsers already consumed" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{name: "test-client", version: "1.0.0"}
        },
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["id"] == 1
      refute response["error"]
      assert Map.has_key?(response["result"], "protocolVersion")
    end

    test "uses Phoenix's configured JSON library for a parsed body" do
      previous = Application.fetch_env(:phoenix, :json_library)
      Application.put_env(:phoenix, :json_library, PhoenixJsonLibrary)

      on_exit(fn ->
        case previous do
          {:ok, library} -> Application.put_env(:phoenix, :json_library, library)
          :error -> Application.delete_env(:phoenix, :json_library)
        end
      end)

      request = %{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1}

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200
    end

    test "preserves a parsed JSON-RPC _json extension member" do
      request = %{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1, "_json" => true}

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200
    end

    test "an empty body is still a parse error once parsers have run" do
      conn =
        conn(:post, "/", "")
        |> put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"]["code"] == -32_700
    end

    test "handles tools/list request" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => 2
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_active_legacy_session()
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2
      assert Map.has_key?(response["result"], "tools")
      assert is_list(response["result"]["tools"])
    end

    test "handles tools/call request" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"message" => "hello"}
        },
        "id" => 3
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_active_legacy_session()
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 3
      assert Map.has_key?(response["result"], "content")
    end

    test "resolves handler_opts from the Plug connection and JSON-RPC request" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{name: "test-client", version: "1.0.0"}
        },
        "id" => 30
      }

      handler_opts = fn conn, request ->
        [
          request_path: conn.request_path,
          request_method: request["method"]
        ]
      end

      conn =
        conn(:post, "/mcp", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> call_http(
          mount_opts(
            handler: RequestAwareServer,
            handler_opts: handler_opts,
            sse_enabled: false
          )
        )

      assert conn.status == 200

      {:ok, response} = Jason.decode(conn.resp_body)

      assert response["result"]["serverInfo"] == %{
               "name" => "/mcp",
               "version" => "initialize"
             }
    end

    test "defaults missing handler_opts to empty options" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{
          "name" => "test_tool",
          "arguments" => %{"message" => "hello"}
        },
        "id" => 31
      }

      opts = %{
        handler: TestServer,
        server_info: %{name: "test", version: "1.0.0"},
        sse_enabled: false,
        cors_enabled: false,
        oauth_enabled: false,
        auth_config: %{}
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_active_legacy_session()
        |> call_http(opts)

      assert conn.status == 200

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["id"] == 31
      assert response["result"]["content"] == [%{"type" => "text", "text" => "Echo: hello"}]
    end

    test "handles invalid JSON" do
      conn =
        conn(:post, "/", "invalid json")
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer))

      assert conn.status == 400

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["code"] == -32700
      assert response["error"]["message"] == "Parse error"
    end

    test "rejects non-object JSON envelopes" do
      conn =
        conn(:post, "/", Jason.encode!("not a request"))
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer))

      assert conn.status == 400

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"]["code"] == -32600
      assert response["error"]["message"] == "Invalid Request"
    end

    test "rejects oversized request bodies" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "initialize", "id" => 1})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer, body_limit: 8))

      assert conn.status == 413
      assert conn.resp_body == "Request body too large"
    end

    test "oauth_enabled fails closed when OAuth authorization feature is disabled" do
      Application.put_env(:arbor_mcp, :oauth2_enabled, false)

      on_exit(fn ->
        Application.delete_env(:arbor_mcp, :oauth2_enabled)
      end)

      request = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => 1
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> call_http(
          mount_opts(
            handler: TestServer,
            oauth_enabled: true,
            resource: "https://mcp.test/",
            authorization_servers: ["https://auth.test"]
          )
        )

      assert conn.status == 500

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "server_error"
    end

    test "handles unknown method" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "unknown/method",
        "id" => 4
      }

      conn =
        conn(:post, "/", Jason.encode!(request))
        |> put_req_header("content-type", "application/json")
        |> put_active_legacy_session()
        |> call_http(mount_opts(handler: TestServer, sse_enabled: false))

      assert conn.status == 200

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 4
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "Method not found: unknown/method"
    end

    test "requires an explicitly configured runtime before request effects" do
      assert_raise ArgumentError, ~r/runtime/, fn -> HttpPlug.init([]) end
      assert is_nil(Process.whereis(SessionManager))
    end
  end

  describe "SSE connections" do
    test "does not enable the deprecated HTTP+SSE route by default" do
      conn =
        conn(:get, "/sse")
        |> call_http(mount_opts([]))

      assert conn.status == 404
      assert conn.resp_body == "SSE not enabled"
    end

    test "handles SSE connection request" do
      conn =
        conn(:get, "/sse")
        |> call_http(mount_opts(legacy_http_sse: true))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "connection") == ["keep-alive"]
      assert conn.resp_body =~ "event: endpoint"
      assert conn.resp_body =~ "data: http://www.example.com/message?sessionId="
      refute conn.resp_body =~ "event: connected"
    end

    test "supports configured legacy GET and POST paths" do
      conn =
        conn(:get, "/events")
        |> call_http(
          mount_opts(
            legacy_http_sse: true,
            legacy_http_sse_path: "/events",
            legacy_http_sse_post_path: "/inbox"
          )
        )

      assert conn.status == 200
      assert conn.resp_body =~ "event: endpoint"
      assert conn.resp_body =~ "data: http://www.example.com/inbox?sessionId="
    end

    test "rejects SSE when disabled" do
      conn =
        conn(:get, "/sse")
        |> call_http(mount_opts(sse_enabled: false))

      assert conn.status == 404
      assert conn.resp_body == "SSE not enabled"
    end

    @tag timeout: 1000
    test "uses provided session ID" do
      # We can't easily test the full SSE flow in sync tests
      # but we can verify the headers are processed
      opts = mount_opts(sse_enabled: true)

      first = conn(:get, "/sse") |> call_http(opts)
      session_id = alias_session_id(first)

      conn =
        conn(:get, "/sse")
        |> put_req_header("mcp-session-id", session_id)

      # Test that the plug would start SSE (indicated by chunked response)
      result_conn = call_http(conn, opts)
      assert result_conn.status == 200
      assert get_resp_header(result_conn, "content-type") == ["text/event-stream"]
    end

    test "modern-only mode rejects the deprecated GET route with its method policy" do
      conn =
        conn(:get, "/sse")
        |> call_http(mount_opts(protocol_mode: :modern_only, legacy_http_sse: true))

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
      assert Jason.decode!(conn.resp_body) == %{"error" => "Method not allowed"}
    end

    test "legacy POST persists its response in the addressed alias session" do
      opts = mount_opts(handler: TestServer, legacy_http_sse: true, sse_mode: :oneshot)
      hello = conn(:get, "/sse") |> call_http(opts)
      id = alias_session_id(hello)
      request = initialize_session_conn(77) |> Map.get(:adapter) |> elem(1) |> Map.get(:req_body)

      result =
        conn(:post, "/message?sessionId=#{id}", request)
        |> put_req_header("content-type", "application/json")
        |> call_http(opts)

      assert result.status == 202
      {:ok, service} = Runtime.service(opts.runtime, :sessions)
      {:ok, lease} = SessionManager.ensure_session(service, id, %{}, [])

      assert {:ok, %{events: [%{data: response}]}} =
               SessionManager.replay_page(service, lease, nil, [])

      assert response["id"] == 77
      assert response["result"]["protocolVersion"] == "2025-06-18"
    end

    test "legacy POST rejects an unknown SSE session" do
      conn =
        conn(
          :post,
          "/message?sessionId=missing",
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 78, "method" => "ping"})
        )
        |> put_req_header("content-type", "application/json")
        |> call_http(mount_opts(handler: TestServer, legacy_http_sse: true))

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["message"] == "Session not found"
    end
  end

  describe "404 handling" do
    test "returns 404 for unknown paths" do
      conn =
        conn(:get, "/unknown/path")
        |> call_http(mount_opts([]))

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "Not found"
    end

    test "returns 404 for unsupported methods" do
      conn =
        conn(:put, "/")
        |> call_http(mount_opts([]))

      assert conn.status == 404
    end
  end

  defmodule FailedInitializeServer do
    use Arbor.MCP.Server.Handler
    def handle_initialize(_params, state), do: {:error, :initialization_failed, state}
  end

  defmodule WrongVersionServer do
    use Arbor.MCP.Server.Handler

    def handle_initialize(_params, state),
      do:
        {:ok,
         %{
           protocolVersion: "2025-03-26",
           capabilities: %{},
           serverInfo: %{name: "wrong", version: "1"}
         }, state}
  end

  defp alias_session_id(conn) do
    [_, endpoint] = Regex.run(~r/event: endpoint\s+data: ([^\r\n]+)/, conn.resp_body)
    endpoint |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("sessionId")
  end

  defp runtime_for(handler, options \\ []) do
    options = Keyword.merge([handler_args: [], request_timeout_ms: 10_000], options)
    key = {__MODULE__, handler, options, Process.get(:http_session_limits, [])}

    case Process.get(key) do
      nil ->
        services = [sessions: [options: Process.get(:http_session_limits, [])]]
        runtime = RuntimeHTTPFixture.start(handler, Keyword.put(options, :services, services))
        Process.put(key, runtime)
        Process.put(:http_runtime, runtime)
        runtime

      runtime ->
        Process.put(:http_runtime, runtime)
        runtime
    end
  end

  defp mount_opts(options) do
    {handler, options} = Keyword.pop(options, :handler, TestServer)
    {arguments, options} = Keyword.pop(options, :handler_args, [])
    {timeout, options} = Keyword.pop(options, :request_timeout_ms, 10_000)

    {legacy, options} =
      Keyword.pop(options, :sse_enabled, Keyword.get(options, :legacy_http_sse, false))

    runtime = runtime_for(handler, handler_args: arguments, request_timeout_ms: timeout)

    options =
      options |> Keyword.put(:legacy_http_sse, legacy) |> Keyword.put_new(:sse_mode, :oneshot)

    HttpPlug.init(Keyword.put(options, :runtime, runtime))
  end

  defp call_http(conn, %{runtime: _runtime} = options) do
    conn =
      if get_req_header(conn, "x-fixture-create-session") == ["true"] do
        metadata = %{
          transport_endpoint:
            if(conn.script_name == [],
              do: options.endpoint,
              else: "/" <> Enum.join(conn.script_name, "/")
            )
        }

        id = RuntimeHTTPFixture.session(options.runtime, true, metadata)

        conn =
          delete_req_header(conn, "x-fixture-create-session")
          |> put_req_header("mcp-session-id", id)

        if get_req_header(conn, "mcp-protocol-version") == [],
          do: put_req_header(conn, "mcp-protocol-version", "2025-06-18"),
          else: conn
      else
        conn
      end

    HttpPlug.call(conn, options)
  end

  defp call_http(conn, options), do: call_http(conn, mount_opts(Map.to_list(options)))

  defp session_state(id), do: RuntimeHTTPFixture.session_state(Process.get(:http_runtime), id)

  defp session_count do
    {:ok, service} = Runtime.service(runtime_for(TestServer), :sessions)
    {:ok, stats} = SessionManager.get_stats(service, [])
    stats.sessions
  end
end
