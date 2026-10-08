defmodule Arbor.MCP.TelemetryPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Telemetry
  alias Arbor.MCP.Transport.Stdio
  alias Arbor.RPC.LogSummary

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    Telemetry.detach_default_logger()
    :ok = Telemetry.attach_default_logger()

    on_exit(fn ->
      Telemetry.detach_default_logger()
      Logger.configure(level: previous_level)
    end)
  end

  test "default logger does not render tool or resource metadata values" do
    secret = "telemetry-secret-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute([:arbor_mcp, :tool, :start], %{}, %{arguments: secret})
        :telemetry.execute([:arbor_mcp, :resource, :read, :start], %{}, %{uri: secret})
      end)

    refute log =~ secret
    assert log =~ "Tool event"
    assert log =~ "Resource event"
  end

  test "default logger summarizes exception values" do
    secret = "exception-secret-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:arbor_mcp, :request, :exception],
          %{duration: 1},
          %{
            request_id: secret,
            method: "tools/call",
            error: RuntimeError.exception(secret)
          }
        )
      end)

    refute log =~ secret
    assert log =~ "Request failed"
  end

  test "stdio connection telemetry exposes only a command basename and fingerprint" do
    shell = System.find_executable("sh") || flunk("sh executable is required")
    secret_argument = "stdio-secret-#{System.unique_integer([:positive])}"
    handler_id = "stdio-open-privacy-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor_mcp, :transport, :connection, :opened],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:stdio_opened, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, state} =
             Stdio.connect(command: [shell, "-c", "exit 0", secret_argument])

    assert_receive {:stdio_opened, [:arbor_mcp, :transport, :connection, :opened], %{}, metadata}
    assert metadata.transport == :stdio
    assert metadata.command_basename == Path.basename(shell)
    assert metadata.command_hash == LogSummary.fingerprint(shell)
    refute Map.has_key?(metadata, :command)
    refute inspect(metadata) =~ secret_argument
    refute inspect(metadata) =~ Path.dirname(shell) <> "/"

    assert :ok = Stdio.close(state)
  end
end
