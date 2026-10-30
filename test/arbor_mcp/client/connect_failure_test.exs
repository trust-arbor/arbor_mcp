defmodule Arbor.MCP.Client.ConnectFailureTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Arbor.MCP.Client

  defmodule RefusingTransport do
    @behaviour Arbor.MCP.Transport
    def connect(opts), do: {:error, Keyword.fetch!(opts, :failure)}
    def send_message(_message, state), do: {:ok, state}
    def receive_message(_state), do: {:error, :closed}
    def connected?(_state), do: false
    def close(_state), do: :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:arbor_mcp, :client, :connect, :failed],
        fn _, values, metadata, _ ->
          send(owner, {:connect_failed, values, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "custom failures retain atoms, tuples, maps and explicit binary errors" do
    for reason <- [:denied, {:endpoint_unavailable, 503}, %{code: :unavailable}, "explicit error"] do
      assert {:error, {:transport_connect_failed, ^reason}} =
               Client.start_link(transport: RefusingTransport, failure: reason, reconnect: false)
    end
  end

  for mode <- [:modern_only, :legacy_only] do
    test "HTTP 503 retains the structured reason under #{mode}" do
      bypass = Bypass.open()
      Bypass.stub(bypass, "POST", "/mcp", &Plug.Conn.resp(&1, 503, "controlled-body"))

      result =
        Client.start_link(
          transport: :http,
          url: "http://127.0.0.1:#{bypass.port}/mcp",
          protocol_mode: unquote(mode),
          reconnect: false,
          health_check_interval: nil
        )

      expected =
        if unquote(mode) == :modern_only,
          do: {:era_probe_failed, {:transport_error, {:http_error, 503, "controlled-body"}}},
          else: {:http_error, 503, "controlled-body"}

      assert result == {:error, {:transport_connect_failed, expected}}
    end
  end

  test "failed connects emit redacted telemetry without an error log" do
    secret = "private-response-payload"

    log =
      capture_log([level: :debug], fn ->
        assert {:error, {:transport_connect_failed, {:service_failed, ^secret}}} =
                 Client.start_link(
                   transport: RefusingTransport,
                   failure: {:service_failed, secret},
                   reconnect: false
                 )
      end)

    assert_receive {:connect_failed, %{count: 1}, metadata}
    refute inspect(metadata) =~ secret
    refute log =~ secret
    refute log =~ "[error]"
  end

  test "connection diagnostics are available when debug logging is enabled" do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        capture_log([level: :debug], fn ->
          assert {:error, {:transport_connect_failed, :denied}} =
                   Client.start_link(
                     transport: RefusingTransport,
                     failure: :denied,
                     reconnect: false
                   )
        end)

      assert log =~ "MCP client connection failed"
      refute log =~ "[error]"
    after
      Logger.configure(level: previous)
    end
  end
end
