defmodule Arbor.MCP.I18nRoundTripTest do
  @moduledoc """
  The non-ASCII corpus through the HTTP and in-process transports.

  Neither transport touches an IO device, so no locale matrix applies here;
  these runs pin the byte-exact contract at the protocol level for the paths
  the stdio tests cannot cover.
  """

  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Arbor.MCP.{Client, HttpPlug}
  alias Arbor.MCP.Server.HandlerServer
  alias Arbor.MCP.Test.{I18nCorpus, RuntimeHTTPFixture}

  defmodule I18nServer do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL, name: "i18n", version: "1"

    alias Arbor.MCP.Test.I18nCorpus

    tool "generate", "Generates non-ASCII text of its own" do
      run(fn _args, state -> {:ok, "generated=" <> I18nCorpus.all_text(), state} end)
    end

    tool "echo", "Echoes text and reports its byte length" do
      param(:text, :string, required: true)

      run(fn args, state ->
        {:ok, "echoed=" <> args.text <> " bytes=" <> Integer.to_string(byte_size(args.text)),
         state}
      end)
    end
  end

  describe "over HTTP" do
    setup do
      runtime = RuntimeHTTPFixture.start(I18nServer)
      Process.put(:i18n_runtime, runtime)
      :ok
    end

    test "a tool's own non-ASCII output survives" do
      %{"result" => %{"content" => [%{"text" => text}]}} =
        post_call(%{"name" => "generate", "arguments" => %{}})

      assert text == "generated=" <> I18nCorpus.all_text()
    end

    test "every corpus string round-trips as a request argument" do
      for {label, value} <- I18nCorpus.strings() do
        %{"result" => %{"content" => [%{"text" => text}]}} =
          post_call(%{"name" => "echo", "arguments" => %{"text" => value}})

        assert text == "echoed=#{value} bytes=#{byte_size(value)}", label
      end
    end

    test "a surrogate-escaped astral argument decodes to the character" do
      body =
        I18nCorpus.surrogate_escaped_json(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "echo", "arguments" => %{"text" => "🪁"}}
        })

      refute body =~ "🪁"
      %{"result" => %{"content" => [%{"text" => text}]}} = post_raw(body)
      assert text == "echoed=🪁 bytes=4"
    end

    test "a body that is not valid UTF-8 is a JSON parse error, not a crash" do
      conn =
        conn(:post, "/", I18nCorpus.invalid_utf8_frame())
        |> put_req_header("content-type", "application/json")
        |> put_active_legacy_session()
        |> HttpPlug.call(RuntimeHTTPFixture.options(Process.get(:i18n_runtime)))

      assert conn.status in [200, 400]
      assert %{"error" => %{"code" => -32_700}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "in-process" do
    setup do
      {:ok, server} =
        HandlerServer.start_link(
          handler: I18nServer,
          transport: :test,
          protocol_mode: :legacy_only
        )

      {:ok, client} =
        Client.start_link(
          transport: :test,
          server: server,
          protocol_mode: :legacy_only,
          health_check_interval: nil
        )

      on_exit(fn ->
        for pid <- [client, server] do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      %{client: client}
    end

    test "a tool's own non-ASCII output survives", %{client: client} do
      assert {:ok, %{"content" => [%{"text" => text}]}} =
               Client.call_tool(client, "generate", %{}, format: :map)

      assert text == "generated=" <> I18nCorpus.all_text()
    end

    test "every corpus string round-trips as a request argument", %{client: client} do
      for {label, value} <- I18nCorpus.strings() do
        assert {:ok, %{"content" => [%{"text" => text}]}} =
                 Client.call_tool(client, "echo", %{"text" => value}, format: :map)

        assert text == "echoed=#{value} bytes=#{byte_size(value)}", label
      end
    end
  end

  defp post_call(params) do
    post_raw(
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => params
      })
    )
  end

  defp post_raw(body) do
    conn =
      conn(:post, "/", body)
      |> put_req_header("content-type", "application/json")
      |> put_active_legacy_session()
      |> HttpPlug.call(RuntimeHTTPFixture.options(Process.get(:i18n_runtime)))

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp put_active_legacy_session(conn) do
    session_id = RuntimeHTTPFixture.session(Process.get(:i18n_runtime))
    put_req_header(conn, "mcp-session-id", session_id)
  end
end
