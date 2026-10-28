defmodule Arbor.MCP.Client.LegacyOnlyFallbackTest do
  @moduledoc """
  A server that answers the `server/discover` probe with an
  UnsupportedProtocolVersionError (-32022) listing only legacy revisions is a
  legacy server: an Arbor server running `protocol_mode: :legacy_only`, the
  documented rollback, answers exactly that. MCP says to continue with a
  version the server lists, so the dual-era client modes initialize with the
  best revision they share, while `:modern_only` still fails, a list naming a
  modern revision is still retried in the modern era, and a cached modern
  observation still never downgrades.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client
  alias Arbor.MCP.Client.EraCache
  alias Arbor.MCP.Server.HandlerServer
  alias Arbor.MCP.Test.RuntimeHTTPFixture

  @legacy_fixture Path.expand("../../../priv/test/legacy_stdio_server.exs", __DIR__)
  @modern_fixture Path.expand("../../../priv/test/modern_stdio_server.exs", __DIR__)
  @project_root Path.expand("../../..", __DIR__)

  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  @modes [:modern_only, :prefer_modern, :prefer_legacy, :legacy_only]

  # Answers each server/discover with the next entry of `:discover` (the last
  # one repeats): `{:unsupported, versions}` is a -32022 listing `versions`,
  # `:modern` a DiscoverResult. Answers initialize with the requested revision
  # when it is in `:accepts`, else with the first of `:accepts`, as a legacy
  # server negotiates; with `strict: true` it rejects that initialize instead.
  # Reports every request to the test as `{:scripted, method, version}`.
  defmodule ScriptedTransport do
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts) do
      {:ok, script} = Agent.start_link(fn -> Keyword.fetch!(opts, :discover) end)

      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         accepts: Keyword.get(opts, :accepts, []),
         strict: Keyword.get(opts, :strict, false),
         script: script
       }}
    end

    @impl true
    def send_message(message, state) do
      request = Jason.decode!(message)
      version = requested_version(request)
      send(state.test_pid, {:scripted, request["method"], version})

      with %{"id" => id} <- request,
           response when is_map(response) <- respond(request, version, state) do
        send(self(), {:scripted_response, Jason.encode!(Map.put(response, "id", id))})
      end

      {:ok, state}
    end

    defp requested_version(%{"method" => "initialize", "params" => params}),
      do: params["protocolVersion"]

    defp requested_version(%{"params" => %{"_meta" => meta}}),
      do: meta["io.modelcontextprotocol/protocolVersion"]

    defp requested_version(_request), do: nil

    defp respond(%{"method" => "server/discover"}, requested, state) do
      next =
        Agent.get_and_update(state.script, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      case next do
        :modern ->
          %{
            "jsonrpc" => "2.0",
            "result" => %{
              "resultType" => "complete",
              "supportedVersions" => ["2026-07-28"],
              "capabilities" => %{},
              "ttlMs" => 0,
              "cacheScope" => "private"
            }
          }

        {:unsupported, versions} ->
          %{
            "jsonrpc" => "2.0",
            "error" => %{
              "code" => -32022,
              "message" => "Unsupported protocol version",
              "data" => %{"supported" => versions, "requested" => requested}
            }
          }
      end
    end

    defp respond(%{"method" => "initialize"}, requested, state) do
      cond do
        requested in state.accepts -> initialize_result(requested)
        state.accepts != [] and not state.strict -> initialize_result(hd(state.accepts))
        true -> initialize_error(requested, state)
      end
    end

    defp respond(_notification, _requested, _state), do: nil

    defp initialize_result(version) do
      %{
        "jsonrpc" => "2.0",
        "result" => %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "serverInfo" => %{"name" => "scripted-legacy", "version" => "1"}
        }
      }
    end

    defp initialize_error(requested, state) do
      %{
        "jsonrpc" => "2.0",
        "error" => %{
          "code" => -32602,
          "message" => "Unsupported protocol version",
          "data" => %{"supported" => state.accepts, "requested" => requested}
        }
      }
    end

    @impl true
    def receive_message(state), do: receive_message(state, :infinity)

    def receive_message(state, timeout) do
      receive do
        {:scripted_response, response} -> {:ok, response, state}
      after
        timeout -> {:error, {:timeout_error, :receive_timeout}}
      end
    end

    @impl true
    def connected?(_state), do: true

    @impl true
    def close(_state), do: :ok
  end

  # Synchronous like non-SSE HTTP: rejects initialize with a 400 carrying a
  # -32022 for the request id `:rejection_id` says (`:same`, `:other` or
  # `:null`), and answers server/discover with a DiscoverResult. Reports
  # every request as `{:http400, method}`.
  defmodule HTTP400Transport do
    @behaviour Arbor.MCP.Transport

    @impl true
    def connect(opts),
      do:
        {:ok,
         %{test_pid: Keyword.fetch!(opts, :test_pid), id: Keyword.fetch!(opts, :rejection_id)}}

    @impl true
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.test_pid, {:http400, request["method"]})
      respond(request, state)
    end

    defp respond(%{"method" => "initialize", "id" => id}, state) do
      error = %{
        "code" => -32022,
        "message" => "Unsupported protocol version",
        "data" => %{"supported" => ["2026-07-28"], "requested" => "legacy"}
      }

      rejection_id =
        case state.id do
          :same -> id
          :other -> id + 1
          :null -> nil
        end

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => rejection_id, "error" => error})
      {:error, {:http_error, 400, body}}
    end

    defp respond(%{"method" => "server/discover", "id" => id}, state) do
      result = %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{},
        "ttlMs" => 0,
        "cacheScope" => "private"
      }

      {:ok, state, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
    end

    defp respond(_notification, state), do: {:ok, state}

    @impl true
    def receive_message(_state), do: receive(do: (:never -> :ok))

    @impl true
    def connected?(_state), do: true

    @impl true
    def close(_state), do: :ok
  end

  defmodule LegacyHandler do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "legacy-only-server", version: "1.0.0"

    tool "echo", "Echo text" do
      param(:text, :string, required: true)

      run(fn %{"text" => text}, state ->
        {:ok, %{content: [%{type: "text", text: text}]}, state}
      end)
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "a -32022 that lists only legacy revisions" do
    test "is legacy evidence for prefer_modern, and initialize offers the best shared one" do
      cache_key = make_ref()

      # A strict server: it rejects any initialize offering another revision.
      opts = [
        discover: [{:unsupported, ["2025-06-18", "2025-03-26"]}],
        accepts: ["2025-06-18", "2025-03-26"],
        strict: true,
        era_cache_key: cache_key
      ]

      assert {:ok, client} = start_scripted(:prefer_modern, opts)
      assert {:ok, "2025-06-18"} = Client.negotiated_version(client)

      # 2025-11-25, the preferred revision, is not on the server's list.
      assert_receive {:scripted, "server/discover", "2026-07-28"}
      assert_receive {:scripted, "initialize", "2025-06-18"}
      assert_receive {:scripted, "notifications/initialized", nil}
      refute_received {:scripted, _method, _version}

      assert {:ok, %{era: :legacy, protocol_version: "2025-06-18"}} =
               EraCache.lookup(
                 EraCache.identity(ScriptedTransport, nil, era_cache_key: cache_key)
               )

      # The observation is reused, with the revision the server took: the
      # next connections initialize at once and offer it again, in both
      # preference modes.
      Client.stop(client)

      for mode <- [:prefer_modern, :prefer_legacy] do
        assert {:ok, again} = start_scripted(mode, opts)
        assert {:ok, "2025-06-18"} = Client.negotiated_version(again)
        assert_receive {:scripted, "initialize", "2025-06-18"}
        assert_receive {:scripted, "notifications/initialized", nil}
        refute_received {:scripted, _method, _version}
        Client.stop(again)
      end
    end

    test "a per-client legacy :protocol_version on the list is offered" do
      assert {:ok, client} =
               start_scripted(:prefer_modern,
                 discover: [{:unsupported, @legacy_versions}],
                 accepts: @legacy_versions,
                 protocol_version: "2025-03-26"
               )

      assert {:ok, "2025-03-26"} = Client.negotiated_version(client)
      assert_receive {:scripted, "initialize", "2025-03-26"}
    end

    test "never downgrades modern_only" do
      assert {:error, {:transport_connect_failed, reason}} =
               start_scripted(:modern_only,
                 discover: [{:unsupported, @legacy_versions}],
                 accepts: @legacy_versions
               )

      assert reason =~ "{:era_probe_failed, {:no_mutually_supported_modern_version, "
      assert_receive {:scripted, "server/discover", "2026-07-28"}
      refute_received {:scripted, "initialize", _version}
    end

    test "lets prefer_legacy retry initialize once with a revision the server lists" do
      assert {:ok, client} =
               start_scripted(:prefer_legacy,
                 discover: [{:unsupported, ["2025-06-18"]}],
                 accepts: ["2025-06-18"],
                 strict: true
               )

      assert {:ok, "2025-06-18"} = Client.negotiated_version(client)
      assert_receive {:scripted, "initialize", "2025-11-25"}
      assert_receive {:scripted, "server/discover", "2026-07-28"}
      assert_receive {:scripted, "initialize", "2025-06-18"}
      assert_receive {:scripted, "notifications/initialized", nil}
      refute_received {:scripted, _method, _version}
    end

    test "does not make prefer_legacy repeat the initialize the server rejected" do
      assert {:error, {:transport_connect_failed, reason}} =
               start_scripted(:prefer_legacy,
                 discover: [{:unsupported, ["2025-11-25"]}],
                 accepts: []
               )

      assert reason =~ "{:initialize_and_era_probe_failed, "
      assert_receive {:scripted, "initialize", "2025-11-25"}
      assert_receive {:scripted, "server/discover", "2026-07-28"}
      refute_received {:scripted, "initialize", _version}
    end
  end

  describe "a -32022 that is not legacy evidence" do
    test "listing a modern revision the client supports is retried in the modern era" do
      assert {:ok, client} =
               start_scripted(:prefer_modern,
                 discover: [{:unsupported, ["2026-07-28" | @legacy_versions]}, :modern],
                 accepts: @legacy_versions
               )

      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      assert_receive {:scripted, "server/discover", "2026-07-28"}
      assert_receive {:scripted, "server/discover", "2026-07-28"}
      refute_received {:scripted, "initialize", _version}
    end

    test "listing a modern revision is never legacy evidence, even when it keeps failing" do
      for mode <- [:prefer_modern, :modern_only] do
        assert {:error, {:transport_connect_failed, reason}} =
                 start_scripted(mode,
                   discover: [{:unsupported, ["2026-07-28" | @legacy_versions]}],
                   accepts: @legacy_versions
                 )

        assert reason =~ "{:era_probe_failed, {:no_mutually_supported_modern_version, "
        assert_receive {:scripted, "server/discover", "2026-07-28"}
        assert_receive {:scripted, "server/discover", "2026-07-28"}
        refute_received {:scripted, "initialize", _version}
      end
    end

    for {label, versions} <- [
          {"no revision the client knows", ["1900-01-01"]},
          {"an unknown revision beside legacy ones", ["2099-01-01", "2025-11-25"]}
        ] do
      test "listing #{label} fails clearly" do
        assert {:error, {:transport_connect_failed, reason}} =
                 start_scripted(:prefer_modern,
                   discover: [{:unsupported, unquote(versions)}],
                   accepts: @legacy_versions
                 )

        assert reason =~ "{:era_probe_failed, {:no_mutually_supported_modern_version, "
        assert reason =~ inspect(unquote(versions))
        refute_received {:scripted, "initialize", _version}
      end
    end

    test "a cached modern observation still never downgrades" do
      for mode <- [:prefer_modern, :prefer_legacy] do
        cache_key = make_ref()
        identity = EraCache.identity(ScriptedTransport, nil, era_cache_key: cache_key)
        :ok = EraCache.observe(identity, :modern, "2026-07-28")

        assert {:error, {:transport_connect_failed, reason}} =
                 start_scripted(mode,
                   discover: [{:unsupported, @legacy_versions}],
                   accepts: @legacy_versions,
                   era_cache_key: cache_key
                 )

        assert reason =~ "{:pinned_modern_era_probe_failed, "
        assert_receive {:scripted, "server/discover", "2026-07-28"}
        refute_received {:scripted, "initialize", _version}
        assert {:ok, %{era: :modern}} = EraCache.lookup(identity)
      end
    end
  end

  describe "an Arbor server running protocol_mode: :legacy_only" do
    test "over the test transport" do
      for mode <- @modes do
        {:ok, server} = start_handler_server(:test, :legacy_only)
        assert_legacy_target(mode, transport: :test, server: server)
      end
    end

    test "over BEAM" do
      for mode <- @modes do
        {:ok, server} = start_handler_server(:beam, :legacy_only)
        assert_legacy_target(mode, transport: :beam, server: server)
      end
    end

    test "over HTTP" do
      url = start_http_server(:legacy_only)

      for mode <- @modes do
        assert_legacy_target(mode, transport: :http, url: url)
      end
    end

    test "over stdio" do
      mix = System.find_executable("mix") || flunk("mix executable is required")

      for mode <- @modes do
        assert_legacy_target(mode,
          transport: :stdio,
          command: [mix, "run", "--no-compile", "--no-start", @legacy_fixture],
          cd: @project_root,
          env: mix_child_env(),
          # The child is a BEAM that can take longer than the 2 s default
          # probe bound to start on a loaded host.
          era_probe_timeout: 10_000
        )
      end
    end
  end

  # The other strict direction, and the fall-forward that shares the retry
  # path above: an Arbor server running :modern_only. Every transport
  # delivers its initialize rejection the same way, HTTP as a 400 carrying
  # the JSON-RPC error.
  describe "an Arbor server running protocol_mode: :modern_only" do
    test "over the test transport and BEAM" do
      for transport <- [:test, :beam], mode <- @modes do
        {:ok, server} = start_handler_server(transport, :modern_only)
        assert_modern_target(mode, transport: transport, server: server)
        stop_quietly(server)
      end
    end

    test "over HTTP" do
      url = start_http_server(:modern_only)

      for mode <- @modes do
        # Each mode starts without the observation the one before recorded.
        assert_modern_target(mode, transport: :http, url: url, reset_era_cache: true)
      end
    end

    test "over stdio" do
      mix = System.find_executable("mix") || flunk("mix executable is required")

      for mode <- @modes do
        assert_modern_target(mode,
          transport: :stdio,
          command: [mix, "run", "--no-compile", "--no-start", @modern_fixture],
          cd: @project_root,
          env: mix_child_env(),
          era_probe_timeout: 10_000
        )
      end
    end
  end

  describe "an HTTP 400 to initialize" do
    test "is the rejection when its JSON-RPC error answers this initialize" do
      assert {:error, {:initialize_error, %{"code" => -32022}}} =
               start_client(:legacy_only, http400(:same))

      assert {:ok, client} = start_client(:prefer_legacy, http400(:same))
      assert {:ok, "2026-07-28"} = Client.negotiated_version(client)
      assert_receive {:http400, "initialize"}
      assert_receive {:http400, "server/discover"}
      Client.stop(client)
    end

    # A JSON-RPC error for another request (a stale proxy's answer, say), or
    # with the null id a server uses when it could not read the request's,
    # rejects nothing this client sent: it stays a transport error.
    for {id, label} <- [other: "another request's id", null: "a null id"] do
      test "with #{label} stays a transport error" do
        for mode <- [:legacy_only, :prefer_legacy] do
          assert {:error, {:transport_connect_failed, reason}} =
                   start_client(mode, http400(unquote(id)))

          assert reason =~ "{:http_error, 400, "
          assert_receive {:http400, "initialize"}
          refute_received {:http400, "server/discover"}
        end
      end
    end
  end

  defp http400(rejection_id) do
    [
      transport: HTTP400Transport,
      test_pid: self(),
      rejection_id: rejection_id,
      era_cache_key: make_ref()
    ]
  end

  defp assert_modern_target(mode, opts) do
    case start_client(mode, opts) do
      {:ok, client} ->
        refute mode == :legacy_only, "legacy_only connected to a modern-only server"
        assert {:ok, "2026-07-28"} = Client.negotiated_version(client), "#{mode}"
        Client.stop(client)

      {:error, reason} ->
        assert mode == :legacy_only, "#{mode}: #{inspect(reason)}"
        assert {:initialize_error, %{"code" => -32022} = error} = reason
        assert error["data"]["supported"] == ["2026-07-28"]
    end
  end

  defp assert_legacy_target(mode, opts) do
    case start_client(mode, opts) do
      {:ok, client} ->
        refute mode == :modern_only, "modern_only connected to a legacy-only server"
        assert {:ok, "2025-11-25"} = Client.negotiated_version(client), "#{mode}"
        assert {:ok, %{"name" => name}} = Client.server_info(client)
        assert name =~ "legacy"

        assert {:ok, %{"content" => [%{"text" => "hi"}]}} =
                 Client.call_tool(client, "echo", %{"text" => "hi"}, format: :map, timeout: 5_000)

        Client.stop(client)

      {:error, reason} ->
        assert mode == :modern_only, "#{mode}: #{inspect(reason)}"
        assert {:transport_connect_failed, detail} = reason
        assert detail =~ "{:era_probe_failed, {:no_mutually_supported_modern_version, "
        assert detail =~ inspect(@legacy_versions)
    end
  end

  defp start_scripted(mode, opts) do
    start_client(mode, [transport: ScriptedTransport, test_pid: self()] ++ opts)
  end

  defp start_client(mode, opts) do
    Client.start_link(opts ++ [protocol_mode: mode, health_check_interval: nil, reconnect: false])
  end

  defp start_handler_server(transport, mode) do
    {:ok, server} =
      HandlerServer.start_link(handler: LegacyHandler, transport: transport, protocol_mode: mode)

    on_exit(fn -> stop_quietly(server) end)
    {:ok, server}
  end

  # A server whose client has gone may already be stopping.
  defp stop_quietly(server) do
    GenServer.stop(server)
  catch
    :exit, _reason -> :ok
  end

  defp start_http_server(mode) do
    runtime = RuntimeHTTPFixture.start(LegacyHandler, protocol_mode: mode)
    ref = {__MODULE__, make_ref()}
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    {:ok, _listener} =
      Plug.Cowboy.http(
        Arbor.MCP.HttpPlug,
        [
          runtime: runtime,
          path: "/mcp",
          protocol_mode: mode,
          allowed_origins: ["http://127.0.0.1:#{port}"]
        ],
        ip: {127, 0, 0, 1},
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{port}/mcp"
  end

  # As in Arbor.MCP.Client.ModernStdioTest: the stdio transport isolates the
  # child's environment, so pass on the Mix paths the child BEAM needs.
  defp mix_child_env do
    [{"MIX_ENV", "test"}] ++
      for name <- [
            "MIX_HOME",
            "MIX_ARCHIVES",
            "MIX_DEPS_PATH",
            "ARBOR_RPC_PATH",
            "ARBOR_V2_DEPS",
            "ARBOR_V2_BUILD",
            "ARBOR_V2_LOCK"
          ],
          value = System.get_env(name),
          do: {name, value}
  end
end
