defmodule Arbor.MCP.HttpPlugPrincipalTest do
  @moduledoc """
  The principal an OAuth mount derives from a validated access token gates a
  separate modern cancellation, MRTR `requestState`, legacy session ownership,
  task ownership and subscription authorization. Two end users must never
  share one silently, and a client's own (machine) principal must never equal
  a user's `sub`.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Plug.Conn

  alias Arbor.MCP.HttpPlug
  alias Arbor.MCP.Server.Runtime

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler
    alias Arbor.MCP.Server.Context

    @impl true
    def init(opts), do: {:ok, %{test: opts[:test]}}

    @impl true
    def handle_call_tool("hold", _args, state) do
      send(state.test, {:hold, Context.current().principal_id, self()})
      receive do: (:finish -> :ok)
      {:ok, %{"content" => [%{"type" => "text", "text" => "held"}]}, state}
    end

    def handle_call_tool("collect", _args, state) do
      send(state.test, {:collect, Context.current().principal_id, Context.input_responses()})

      case Context.input_responses() do
        nil ->
          requests = %{
            "name" => %{
              "method" => "elicitation/create",
              "params" => %{
                "message" => "Name?",
                "requestedSchema" => %{"type" => "object", "properties" => %{}}
              }
            }
          }

          {:input_required, requests, %{"step" => "name"}, state}

        %{"name" => _response} ->
          {:ok, %{"content" => [%{"type" => "text", "text" => "resumed"}]}, state}
      end
    end
  end

  defmodule Verifier do
    @moduledoc false
    # A host token verifier may name the principal in a `principal_id` claim.
    @behaviour Arbor.MCP.Authorization.TokenVerifier

    @impl true
    def verify_access_token(token, _opts) do
      {:ok,
       %{
         "principal_id" => token,
         "client_id" => "app-client",
         "iss" => "https://issuer.example",
         "aud" => "https://mcp.example",
         "exp" => System.system_time(:second) + 60,
         "scope" => "mcp"
       }}
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_mcp, :oauth2_enabled)
    Application.put_env(:arbor_mcp, :oauth2_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_mcp, :oauth2_enabled, value)
        :error -> Application.delete_env(:arbor_mcp, :oauth2_enabled)
      end
    end)

    root =
      start_supervised!(
        {Runtime,
         handler: Handler,
         handler_args: [test: self()],
         request_timeout_ms: 5_000,
         services: [sessions: []]}
      )

    {:ok, runtime} = Runtime.ref(root)
    %{runtime: runtime}
  end

  describe "an access token without sub" do
    test "is refused, so two users of one client can't cancel or resume each other's work",
         %{runtime: runtime} do
      opts = mount(runtime)

      log =
        capture_log(fn ->
          # Ada's work never starts, so it mints no requestState and holds no
          # request id that Bob, another user of the same client, could reach.
          for request <- [collect(1), hold(7)] do
            assert %{status: 401} = conn = post(opts, request, "ada")
            assert_invalid_token(conn)
          end

          for request <- [cancellation(7), resume("any", 2)] do
            assert %{status: 401} = conn = post(opts, request, "bob")
            assert_invalid_token(conn)
          end

          # Nor is a client-credentials token, unless the host opts in.
          assert %{status: 401} = conn = post(opts, collect(3), "machine")
          assert_invalid_token(conn)
        end)

      assert log =~ "without a subject"
      refute log =~ "ada"
      refute log =~ "app-client"
      refute_received {:collect, _principal, _responses}
      refute_received {:hold, _principal, _worker}
    end

    test "with client_principals: true binds a machine token to client:<client_id>",
         %{runtime: runtime} do
      opts = mount(runtime, client_principals: true)

      assert %{status: 200} = conn = post(opts, collect(1), "machine")
      assert_receive {:collect, "client:app-client", nil}, 2_000
      state = Jason.decode!(conn.resp_body)["result"]["requestState"]
      assert is_binary(state)

      # A user whose `sub` is the client's own id is another principal.
      assert %{status: 200} = conn = post(opts, resume(state, 2), "user-named-app-client")
      assert %{"error" => %{"code" => -32602}} = Jason.decode!(conn.resp_body)
      refute_received {:collect, _principal, _responses}

      assert %{status: 200} = conn = post(opts, resume(state, 3), "machine")

      assert %{"result" => %{"content" => [%{"text" => "resumed"}]}} =
               Jason.decode!(conn.resp_body)

      assert_receive {:collect, "client:app-client", %{"name" => _response}}
    end

    test "with client_principals: true a user can't cancel the client's own work",
         %{runtime: runtime} do
      opts = mount(runtime, client_principals: true)
      held = Task.async(fn -> post(opts, hold(7), "machine") end)
      assert_receive {:hold, "client:app-client", worker}, 2_000

      assert %{status: 202} = post(opts, cancellation(7), "user-named-app-client")
      assert Process.alive?(worker)

      assert %{status: 202} = post(opts, cancellation(7), "machine")
      ref = Process.monitor(worker)
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
      assert %{status: 200} = conn = Task.await(held, 5_000)
      assert %{"error" => %{"message" => "Request cancelled"}} = Jason.decode!(conn.resp_body)
    end

    test "with client_principals: true is still refused when it names a resource owner",
         %{runtime: runtime} do
      opts = mount(runtime, client_principals: true)

      capture_log(fn ->
        for token <- ["ada", "bob"] do
          assert %{status: 401} = conn = post(opts, collect(1), token)
          assert_invalid_token(conn)
        end
      end)

      refute_received {:collect, _principal, _responses}
    end

    test "with an empty sub is refused", %{runtime: runtime} do
      opts = mount(runtime, client_principals: true)

      capture_log(fn ->
        assert %{status: 401} = conn = post(opts, collect(1), "empty-sub")
        assert_invalid_token(conn)
      end)

      refute_received {:collect, _principal, _responses}
    end
  end

  describe "with client_principals: true the client: prefix" do
    test "is refused in a user's sub, so no user shares a machine's principal",
         %{runtime: runtime} do
      opts = mount(runtime, client_principals: true)

      assert %{status: 200} = conn = post(opts, collect(1), "machine")
      assert_receive {:collect, "client:app-client", nil}, 2_000
      state = Jason.decode!(conn.resp_body)["result"]["requestState"]

      log =
        capture_log(fn ->
          for request <- [collect(2), hold(7), resume(state, 3), cancellation(7)] do
            assert %{status: 401} = conn = post(opts, request, "sub-in-client-namespace")
            assert_invalid_token(conn)
          end
        end)

      assert log =~ "reserves for client principals"
      refute log =~ "app-client"
      refute_received {:collect, _principal, _responses}
      refute_received {:hold, _principal, _worker}
    end

    test "is refused in a principal_id claim", %{runtime: runtime} do
      opts = mount(runtime, client_principals: true, verifier: true)

      capture_log(fn ->
        assert %{status: 401} = conn = post(opts, collect(1), "client:app-client")
        assert_invalid_token(conn)
      end)

      refute_received {:collect, _principal, _responses}

      assert %{status: 200} = post(opts, collect(2), "user-7")
      assert_receive {:collect, "user-7", nil}, 2_000
    end

    test "is not reserved without the option", %{runtime: runtime} do
      assert %{status: 200} = post(mount(runtime), collect(1), "sub-in-client-namespace")
      assert_receive {:collect, "client:app-client", nil}, 2_000

      assert %{status: 200} =
               post(mount(runtime, verifier: true), collect(2), "client:app-client")

      assert_receive {:collect, "client:app-client", nil}, 2_000
    end
  end

  describe "the host's :principal_id" do
    # A config value that is unexpectedly nil must not drop the token binding.
    test "is unset when it is a literal nil, so the token decides", %{runtime: runtime} do
      opts = mount(runtime, principal_id: nil)
      assert %{status: 200} = post(opts, collect(1), "with-sub")
      assert_receive {:collect, "ada-subject", nil}, 2_000

      capture_log(fn ->
        assert %{status: 401} = conn = post(opts, collect(2), "machine")
        assert_invalid_token(conn)
      end)

      opts = mount(runtime, principal_id: nil, client_principals: true)
      assert %{status: 200} = post(opts, collect(3), "machine")
      assert_receive {:collect, "client:app-client", nil}, 2_000

      capture_log(fn ->
        assert %{status: 401} = conn = post(opts, collect(4), "sub-in-client-namespace")
        assert_invalid_token(conn)
      end)

      refute_received {:collect, _principal, _responses}
    end

    test "runs without a principal when a resolver returns nil", %{runtime: runtime} do
      for client_principals <- [false, true],
          principal_id <- [
            fn _conn, _request, _claims -> nil end,
            {__MODULE__, :no_principal, []}
          ],
          token <- ["machine", "with-sub", "ada"] do
        opts = mount(runtime, principal_id: principal_id, client_principals: client_principals)
        assert %{status: 200} = post(opts, collect(1), token)
        assert_receive {:collect, nil, nil}, 2_000
      end
    end

    test "wins over the token, whatever it resolves", %{runtime: runtime} do
      for {principal_id, expected} <- [
            {"tenant-wide", "tenant-wide"},
            {&username/3, "ada"},
            {fn _conn, _request, _claims -> nil end, nil}
          ],
          client_principals <- [false, true] do
        opts = mount(runtime, principal_id: principal_id, client_principals: client_principals)
        assert %{status: 200} = post(opts, collect(1), "ada")
        assert_receive {:collect, ^expected, nil}, 2_000
        assert %{status: 200} = post(opts, collect(2), "with-sub")
        assert_receive {:collect, ^expected, nil}, 2_000
      end
    end

    test "keeps users of one client apart when it resolves each of them", %{runtime: runtime} do
      opts = mount(runtime, principal_id: &username/3)

      held = Task.async(fn -> post(opts, hold(7), "ada") end)
      assert_receive {:hold, "ada", worker}, 2_000
      assert %{status: 202} = post(opts, cancellation(7), "bob")
      assert Process.alive?(worker)

      assert %{status: 200} = conn = post(opts, collect(1), "ada")
      assert_receive {:collect, "ada", nil}, 2_000
      state = Jason.decode!(conn.resp_body)["result"]["requestState"]
      assert %{status: 200} = conn = post(opts, resume(state, 2), "bob")
      assert %{"error" => %{"code" => -32602}} = Jason.decode!(conn.resp_body)
      refute_received {:collect, _principal, _responses}

      assert %{status: 202} = post(opts, cancellation(7), "ada")
      ref = Process.monitor(worker)
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
      assert %{status: 200} = conn = Task.await(held, 5_000)
      assert %{"error" => %{"message" => "Request cancelled"}} = Jason.decode!(conn.resp_body)
    end
  end

  test "a token's sub stays the principal, unprefixed", %{runtime: runtime} do
    for client_principals <- [false, true] do
      opts = mount(runtime, client_principals: client_principals)
      assert %{status: 200} = post(opts, collect(1), "with-sub")
      assert_receive {:collect, "ada-subject", nil}, 2_000
    end
  end

  test "client_principals must be a boolean", %{runtime: runtime} do
    assert_raise ArgumentError, ~r/client_principals/, fn ->
      mount(runtime, client_principals: :yes)
    end
  end

  # Introspected claims have atom keys; a verifier's may have string keys.
  defp username(_conn, _request, claims), do: claims[:username] || claims["username"]

  @doc false
  def no_principal(_conn, _request, _claims), do: nil

  defp assert_invalid_token(conn) do
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
    assert challenge =~ "resource_metadata="

    assert %{"error" => "invalid_token", "error_description" => description} =
             Jason.decode!(conn.resp_body)

    assert description =~ "subject"
  end

  defp mount(runtime, extra \\ []) do
    observer = self()
    {verifier?, extra} = Keyword.pop(extra, :verifier, false)

    introspection = %{
      realm: "principal-test",
      introspection_endpoint: "https://issuer.example/introspect",
      client_id: "resource-server",
      client_secret: "resource-secret",
      expected_issuer: "https://issuer.example",
      expected_audience: "https://mcp.example",
      oauth_http: [
        dns_resolver: fn _host, _timeout -> {:ok, [{93, 184, 216, 34}]} end,
        request_fun: fn :post, {_url, _headers, _content_type, body}, _options, _request ->
          token = URI.decode_query(body)["token"]
          send(observer, {:introspected, token})
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(claims(token))}}
        end
      ]
    }

    auth_config =
      if verifier?,
        do: %{
          realm: "principal-test",
          token_verifier: {Verifier, []},
          expected_issuer: "https://issuer.example",
          expected_audience: "https://mcp.example"
        },
        else: introspection

    HttpPlug.init(
      [
        runtime: runtime,
        protocol_mode: :modern_only,
        endpoint: "/mcp",
        oauth_enabled: true,
        resource: "https://mcp.example",
        authorization_servers: ["https://issuer.example"],
        auth_config: auth_config,
        scope_mapper: fn _request -> ["mcp"] end,
        request_state: [
          active_key_id: "fixture",
          keys: %{"fixture" => :binary.copy(<<7>>, 32)},
          ttl_seconds: 60
        ]
      ] ++ extra
    )
  end

  # An introspection response (RFC 7662) may leave out `sub` and `username`.
  defp claims(token) do
    now = System.system_time(:second)

    base = %{
      "active" => true,
      "client_id" => "app-client",
      "iss" => "https://issuer.example",
      "aud" => "https://mcp.example",
      "exp" => now + 60,
      "scope" => "mcp"
    }

    case token do
      # Two users of one client whose authorization server hides `sub`.
      "ada" -> Map.put(base, "username", "ada")
      "bob" -> Map.put(base, "username", "bob")
      # A client-credentials token: no resource owner at all.
      "machine" -> base
      "user-named-app-client" -> Map.put(base, "sub", "app-client")
      "with-sub" -> Map.merge(base, %{"sub" => "ada-subject", "username" => "ada"})
      "empty-sub" -> Map.put(base, "sub", "")
      "sub-in-client-namespace" -> Map.put(base, "sub", "client:app-client")
    end
  end

  defp post(opts, request, token) do
    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", request["method"])

    conn =
      case request["params"]["name"] do
        nil -> conn
        name -> put_req_header(conn, "mcp-name", name)
      end

    HttpPlug.call(conn, opts)
  end

  defp meta,
    do: %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
    }

  defp tool(id, name),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}, "_meta" => meta()}
    }

  defp hold(id), do: tool(id, "hold")
  defp collect(id), do: tool(id, "collect")

  defp resume(state, id) do
    collect(id)
    |> put_in(["params", "requestState"], state)
    |> put_in(["params", "inputResponses"], %{
      "name" => %{"action" => "accept", "content" => %{"name" => "Ada"}}
    })
  end

  defp cancellation(id),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id, "_meta" => meta()}
    }
end
