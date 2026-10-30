defmodule Arbor.MCP.Client.RequestDeliveryTest do
  @moduledoc """
  The HTTP client POSTs each request from its own task, so a request does not
  wait behind a slow one. A request that does wait in the client's mailbox
  must not be sent once its caller has given up (the caller's deadline passed,
  or the caller exited), and a failed send must keep the transport's reason as
  a term so `Arbor.MCP.Client.delivery_outcome/1` can tell "not sent" from
  "unknown".
  """

  use ExUnit.Case, async: false

  import Arbor.MCP.TestHelpers, only: [wait_until: 2]

  alias Arbor.MCP.Client
  alias Arbor.MCP.Error

  setup do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      respond(conn, Jason.decode!(body), test_pid)
    end)

    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{bypass.port}/mcp",
        use_sse: false,
        protocol_mode: :legacy_only,
        health_check_interval: nil,
        reconnect: false
      )

    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    %{bypass: bypass, client: client}
  end

  test "a request does not wait behind a slow one", %{client: client} do
    slow = Task.async(fn -> Client.call_tool(client, "slow", %{}, timeout: 10_000) end)
    assert_receive {:tool_call_started, "slow", handler}, 2_000

    assert {:ok, _result} = Client.call_tool(client, "quick", %{}, timeout: 2_000)

    send(handler, :release)
    assert {:ok, _result} = Task.await(slow)
  end

  describe "a request queued in a busy client" do
    test "is not sent once its caller's deadline has passed", %{client: client} do
      :ok = :sys.suspend(client)
      late = Task.async(fn -> Client.call_tool(client, "late", %{}, timeout: 100) end)
      wait_until(fn -> queued_request?(client, late.pid) end, timeout: 2_000)
      # Genuinely about timing: the deadline passes while the request waits.
      Process.sleep(150)
      :ok = :sys.resume(client)
      assert {:error, _timeout} = Task.await(late)

      # The client has dequeued (and dropped) the late request by now.
      _ = :sys.get_state(client)
      refute_received {:tool_call_started, "late", _handler}
    end

    test "is not sent once its caller has exited", %{client: client} do
      :ok = :sys.suspend(client)
      {caller, monitor} = spawn_monitor(fn -> Client.call_tool(client, "orphan", %{}) end)

      # Kill the caller only once its request is queued in the busy client.
      wait_until(fn -> queued_request?(client, caller) end, timeout: 2_000)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 2_000
      :ok = :sys.resume(client)

      _ = :sys.get_state(client)
      refute_received {:tool_call_started, "orphan", _handler}
    end
  end

  describe "a failed send" do
    test "keeps the transport's reason as a term", %{bypass: bypass, client: client} do
      Bypass.down(bypass)

      assert {:error, %{type: :transport_error, reason: %Mint.TransportError{}} = error} =
               Client.call_tool(client, "any", %{}, format: :map)

      assert error.message =~ "Failed to send request"
      assert Client.delivery_outcome(error) == :not_sent
    end

    test "is a TransportError carrying the reason in the struct format", %{
      bypass: bypass,
      client: client
    } do
      Bypass.down(bypass)

      assert {:error, %Error.TransportError{transport: :http, reason: %Mint.TransportError{}}} =
               result = Client.call_tool(client, "any", %{})

      assert Client.delivery_outcome(result) == :not_sent
    end
  end

  describe "delivery_outcome/1" do
    test "is :not_sent only when the request provably never left" do
      not_sent = [
        :not_connected,
        {:error, :not_connected},
        Error.validation_error(:arguments, 1, "tool arguments must be a map"),
        Error.transport_error(:http, :not_sent, %{cause: :deadline_expired}),
        %{type: :transport_error, reason: :dns_failed},
        %{type: :transport_error, reason: :deadline_expired},
        %{type: :transport_error, reason: {:security_violation, :blocked}},
        %{type: :transport_error, reason: :frame_too_large},
        %{type: :transport_error, reason: {:transport_error, {:send_failed, :badarg}}},
        %{type: :transport_error, reason: {:validation_error, {:invalid_json, "x"}}},
        {:transport_error, :deadline_expired},
        %{type: :invalid_request_meta, message: "bad"},
        # Refused by the HTTP transport before it wrote anything.
        Error.transport_error(:http, {:auth_provider_token_failed, Provider, :expired}),
        %{type: :transport_error, reason: {:auth_provider_token_failed, Provider, :redacted}},
        %{type: :transport_error, reason: {:authentication_failed, :rejected_credential}},
        {:transport_error, {:auth_refused, {:auth_provider_token_failed, Provider, :throw}}},
        {:transport_error, {:auth_refused, {:authentication_failed, :rejected_credential}}}
      ]

      for reason <- not_sent do
        assert Client.delivery_outcome(reason) == :not_sent, inspect(reason)
      end

      unknown = [
        :timeout,
        {:error, :timeout},
        %Error.ProtocolError{code: -32603, message: "Request timeout"},
        %{"code" => -32601, "message" => "Method not found"},
        %{"code" => -32602, "message" => "Invalid params"},
        Error.transport_error(:http, :outcome_unknown, %{}),
        %{type: :transport_error, reason: {:http_receive_failed, :timeout}},
        %{type: :transport_error, reason: {:http_error, 500, ""}},
        {:transport_error, {:http_receive_failed, :closed}},
        # Refused once the server had answered.
        %{type: :transport_error, reason: {:authentication_failed, :unauthorized}},
        {:transport_error, {:auth_refused, {:authentication_failed, :unauthorized}}},
        {:transport_error, {:auth_refused, :timeout}},
        :something_else
      ]

      for reason <- unknown do
        assert Client.delivery_outcome(reason) == :unknown, inspect(reason)
      end
    end
  end

  defp queued_request?(client, caller) do
    {:messages, messages} = Process.info(client, :messages)

    Enum.any?(messages, fn
      {:"$gen_call", {^caller, _tag}, {:request, "tools/call", _params, _meta}} -> true
      _other -> false
    end)
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _test_pid) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "delivery", "version" => "1"}
      }
    })
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, test_pid) do
    name = params["name"]
    send(test_pid, {:tool_call_started, name, self()})

    if name in ["slow", "hang"] do
      receive do
        :release -> :ok
      after
        10_000 -> :ok
      end
    end

    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"content" => [%{"type" => "text", "text" => name}]}
    })
  end

  defp respond(conn, _notification, _test_pid), do: Plug.Conn.resp(conn, 202, "")

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
