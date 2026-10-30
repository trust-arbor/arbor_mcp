defmodule Arbor.MCP.Client.HTTPStreamConnectFailureTest do
  @moduledoc """
  A modern request stream (`progress_token:`) whose connection never opens
  sent nothing, so it fails at once as not sent, with the reason a POST that
  can't connect reports, and isn't retried as a broken stream (#177). That
  covers a refused connection and an address that doesn't resolve or isn't
  permitted.
  """

  use ExUnit.Case, async: false

  # A client whose test process exits stops through terminate/2; that is not
  # under test.
  @moduletag :capture_log

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error.TransportError
  alias Arbor.MCP.Server.Runtime

  defmodule Handler do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    @impl true
    def handle_list_tools(_cursor, state),
      do: {:ok, [%{name: "echo", inputSchema: %{"type" => "object"}}], nil, state}

    @impl true
    def handle_call_tool("echo", _args, state),
      do: {:ok, %{content: [%{type: "text", text: "ran"}]}, state}
  end

  # Answers every tools/call with a Bearer challenge.
  defmodule ChallengingPlug do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{method: "POST"} = conn, inner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode(body) do
        {:ok, %{"method" => "tools/call"}} ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="mcp"))
          |> Plug.Conn.send_resp(401, "")

        _other ->
          conn |> Plug.Conn.assign(:raw_body, body) |> Arbor.MCP.HttpPlug.call(inner)
      end
    end

    def call(conn, inner), do: Arbor.MCP.HttpPlug.call(conn, inner)
  end

  # Answers a challenge with a new token once the test says so.
  defmodule StoppingProvider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    @impl true
    def init(config), do: {:ok, %{test_pid: Keyword.fetch!(config, :test_pid)}}

    @impl true
    def get_token(state), do: {:ok, "stale", state}

    @impl true
    def handle_unauthorized(_www, _scopes, state) do
      send(state.test_pid, {:challenged, self()})

      receive do
        :answer -> {:ok, "fresh", state}
      end
    end

    @impl true
    def handle_forbidden(www, scopes, state), do: handle_unauthorized(www, scopes, state)
  end

  describe "a request stream whose connection never opens" do
    setup do
      # What "localhost" resolves to, for every connection the client opens.
      addresses = start_supervised!({Agent, fn -> {:ok, [{127, 0, 0, 1}]} end})

      runtime = start_supervised!({Runtime, handler: Handler, transport: :mounted_http})
      plug = {Arbor.MCP.HttpPlug, runtime: runtime, path: "/mcp", protocol_mode: :modern_only}

      listener =
        start_supervised!(
          {Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: :listener
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

      {:ok, client} =
        Client.start_link(
          transport: :http,
          url: "http://localhost:#{port}/mcp",
          protocol_mode: :modern_only,
          use_sse: false,
          security: %{origin: nil},
          dns_resolver: fn _host, _timeout -> Agent.get(addresses, & &1) end,
          health_check_interval: nil,
          reconnect: false
        )

      on_exit(fn ->
        try do
          Client.disconnect(client)
        catch
          :exit, _reason -> :ok
        end
      end)

      # The stream opens while the server is there.
      assert {:ok, _} = Client.call_tool(client, "echo", %{}, progress_token: "warm")
      attach_stream_retry()

      %{client: client, addresses: addresses, port: port}
    end

    test "a refused connection fails as not sent, without a stream retry", %{
      client: client,
      port: port
    } do
      :ok = stop_supervised(:listener)
      assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000)

      for mode <- [:at_least_once, :safe_only] do
        result =
          Client.call_tool(client, "echo", %{},
            progress_token: "refused-#{mode}",
            http_stream_retry: mode,
            http_stream_retry_delay: 0
          )

        assert {:error, %TransportError{reason: %Mint.TransportError{reason: :econnrefused}}} =
                 result

        assert Client.delivery_outcome(result) == :not_sent
      end

      refute_received {:stream_retry, _attempt}

      # The same reason, and outcome, as an ordinary POST to the refused port.
      post = Client.call_tool(client, "echo", %{})
      assert {:error, %TransportError{reason: %Mint.TransportError{reason: :econnrefused}}} = post
      assert Client.delivery_outcome(post) == :not_sent
    end

    test "an address that doesn't resolve or isn't permitted fails as not sent", %{
      client: client,
      addresses: addresses
    } do
      for {answer, reason} <- [
            {{:error, :nxdomain}, :dns_failed},
            {{:ok, [{10, 0, 0, 1}]}, :non_loopback_address}
          ] do
        Agent.update(addresses, fn _ -> answer end)

        result =
          Client.call_tool(client, "echo", %{},
            progress_token: "unresolved-#{reason}",
            http_stream_retry_delay: 0
          )

        assert {:error, %TransportError{reason: ^reason}} = result
        assert Client.delivery_outcome(result) == :not_sent
      end

      refute_received {:stream_retry, _attempt}
    end

    # The map format keeps the error the client replied with.
    test "the map format reports the transport's reason", %{client: client, port: port} do
      :ok = stop_supervised(:listener)
      assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000)

      assert {:error,
              %{type: :transport_error, reason: %Mint.TransportError{reason: :econnrefused}} =
                error} =
               Client.call_tool(client, "echo", %{}, progress_token: "map", format: :map)

      assert Client.delivery_outcome(error) == :not_sent
    end
  end

  # A re-send after an auth challenge follows a request the server answered,
  # so its failure to connect is a broken stream like any other.
  describe "a request stream re-sent after an auth challenge" do
    setup do
      runtime = start_supervised!({Runtime, handler: Handler, transport: :mounted_http})
      inner = Arbor.MCP.HttpPlug.init(runtime: runtime, path: "/mcp", protocol_mode: :modern_only)

      listener =
        start_supervised!(
          {Bandit,
           plug: {ChallengingPlug, inner}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: :listener
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

      {:ok, client} =
        Client.start_link(
          transport: :http,
          url: "http://127.0.0.1:#{port}/mcp",
          protocol_mode: :modern_only,
          use_sse: false,
          security: %{origin: nil},
          health_check_interval: nil,
          reconnect: false,
          auth_provider: {StoppingProvider, test_pid: self()}
        )

      on_exit(fn ->
        try do
          Client.disconnect(client)
        catch
          :exit, _reason -> :ok
        end
      end)

      attach_stream_retry()
      %{client: client, port: port}
    end

    for {mode, attempts} <- [safe_only: 1, at_least_once: 2] do
      test "that can't connect has an unknown outcome under #{mode}", %{
        client: client,
        port: port
      } do
        task =
          Task.async(fn ->
            Client.call_tool(client, "echo", %{},
              progress_token: "challenged",
              http_stream_retry: unquote(mode),
              http_stream_retry_delay: 0
            )
          end)

        # The provider answers the challenge once the server is gone.
        assert_receive {:challenged, provider}, 2_000
        :ok = stop_supervised(:listener)
        assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000)
        send(provider, :answer)

        assert {:error,
                %TransportError{
                  reason: :outcome_unknown,
                  details: %{
                    attempts: unquote(attempts),
                    cause: %{
                      cause: %Mint.TransportError{reason: :econnrefused},
                      delivery: :ambiguous
                    }
                  }
                } = error} = Task.await(task)

        assert Client.delivery_outcome(error) == :unknown
      end
    end
  end

  defp attach_stream_retry do
    test_pid = self()
    handler = "stream-connect-retry-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:arbor_mcp, :client, :http, :request, :retry],
      fn _event, %{attempt: attempt}, _metadata, _config ->
        send(test_pid, {:stream_retry, attempt})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
