defmodule Arbor.MCP.Client.RedactionTest do
  @moduledoc """
  A client keeps its connection's credentials in process state: headers (an
  Authorization bearer, an API-key header of any name), OAuth tokens and
  client secrets, the stdio server's environment. None of it may be printed
  when that state is inspected, shown by `:sys.get_status/1`, or written to a
  crash report, whether the report is formatted by Elixir or by Erlang.
  """

  # Not async: the crash-report test adds and removes a global :logger
  # handler, and OTP's logger can lose track of a handler when handlers are
  # added or removed concurrently (remove_handler writes back a handler list
  # it read before its asynchronous removal callback ran). A handler id left
  # without a config breaks every other test's capture_log.
  use ExUnit.Case, async: false

  alias Arbor.MCP.Client
  alias Arbor.MCP.Transport.HTTP
  alias Arbor.MCP.Transport.HTTP.LegacySSE

  @secrets ~w(SECRET-BEARER SECRET-APIKEY SECRET-TOKEN SECRET-SESSION SECRET-CLIENT
              SECRET-ENV SECRET-SECURITY SECRET-QUERY SECRET-PROVIDER)

  test "the HTTP transport state inspects without credentials" do
    printed = inspect(http_state(), limit: :infinity, printable_limit: :infinity)

    refute_secrets(printed)
    # Which headers are set is still visible, only their values are not.
    assert printed =~ "authorization"
    assert printed =~ "x-service-key"
  end

  test "the client state inspects without credentials" do
    client = %Client{
      transport_mod: HTTP,
      transport_state: http_state(),
      transport_opts: client_opts()
    }

    printed = inspect(client, limit: :infinity, printable_limit: :infinity)

    refute_secrets(printed)
    assert printed =~ "https://mcp.example.com/mcp"
    assert printed =~ ":prefer_modern"
  end

  test "the legacy SSE transport state inspects without credentials" do
    state = %LegacySSE{
      base_url: "https://mcp.example.com",
      post_url: "https://mcp.example.com/message?sessionId=SECRET-SESSION",
      session_id: "SECRET-SESSION",
      headers: [{"authorization", "Bearer SECRET-BEARER"}]
    }

    refute_secrets(inspect(state, limit: :infinity, printable_limit: :infinity))
  end

  test ":sys.get_status/1 carries no credentials, however it is formatted" do
    {:ok, client} = Client.start_link([_skip_connect: true] ++ client_opts())
    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)

    :sys.replace_state(client, fn state ->
      %{state | transport_mod: HTTP, transport_state: http_state()}
    end)

    status = :sys.get_status(client)

    # Erlang's own formatting (logger_formatter, ~p) does not use Inspect.
    refute_secrets(IO.iodata_to_binary(:io_lib.format(~c"~p", [status])))
    refute_secrets(inspect(status, limit: :infinity, printable_limit: :infinity))
  end

  test "a crash report carries no credentials" do
    Process.flag(:trap_exit, true)
    {:ok, client} = Client.start_link([_skip_connect: true] ++ client_opts())

    :sys.replace_state(client, fn state ->
      %{state | transport_mod: HTTP, transport_state: http_state()}
    end)

    # The raw report is what every formatter, Elixir's or Erlang's, is given.
    handler = :"redaction_test_#{System.unique_integer([:positive])}"
    config = %{config: %{test_pid: self(), client: client}, level: :all}
    :ok = :logger.add_handler(handler, __MODULE__.ReportCapture, config)
    on_exit(fn -> :logger.remove_handler(handler) end)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(client, :crash_for_test)
      assert_receive {:EXIT, ^client, :crash_for_test}, 5_000
      assert_receive {:crash_report, msg}, 2_000

      case msg do
        {:report, report} ->
          assert %{state: %{component: Client, payloads: :redacted}} = report
          refute_secrets(IO.iodata_to_binary(:io_lib.format(~c"~p", [report])))

        # On OTP 27 Elixir's translator turns the report into text before any
        # handler sees it; the text must be clean as well.
        {:string, text} ->
          refute_secrets(IO.chardata_to_string(text))
      end
    end)
  end

  defmodule ReportCapture do
    @moduledoc false
    def log(%{msg: msg, meta: meta}, %{config: %{test_pid: test_pid, client: client}}) do
      if meta[:pid] == client and crash_report?(msg), do: send(test_pid, {:crash_report, msg})
      :ok
    end

    defp crash_report?({:report, %{label: {:gen_server, :terminate}}}), do: true
    defp crash_report?({:string, text}), do: IO.chardata_to_string(text) =~ "terminating"
    defp crash_report?(_msg), do: false
  end

  defp http_state do
    {:ok, state} =
      HTTP.connect(
        url: "https://mcp.example.com/mcp",
        use_sse: false,
        headers: [
          {"authorization", "Bearer SECRET-BEARER"},
          {"x-service-key", "SECRET-APIKEY"}
        ],
        security: %{auth: {:bearer, "SECRET-SECURITY"}, trusted_origins: []}
      )

    %{
      state
      | access_token: "SECRET-TOKEN",
        session_id: "SECRET-SESSION",
        auth_config: %{client_id: "id", client_secret: "SECRET-CLIENT"},
        auth_provider_state: %{token: "SECRET-PROVIDER"}
    }
  end

  defp client_opts do
    [
      transport: :http,
      url: "https://mcp.example.com/mcp?api_key=SECRET-QUERY",
      protocol_mode: :prefer_modern,
      headers: [{"x-service-key", "SECRET-APIKEY"}],
      security: %{auth: {:bearer, "SECRET-SECURITY"}},
      auth: %{client_id: "id", client_secret: "SECRET-CLIENT"},
      auth_provider: {SomeProvider, token: "SECRET-PROVIDER"},
      env: [{"SERVICE_TOKEN", "SECRET-ENV"}],
      health_check_interval: nil,
      reconnect: false
    ]
  end

  defp refute_secrets(printed) do
    for secret <- @secrets do
      refute printed =~ secret, "#{secret} was printed:\n#{printed}"
    end
  end
end
