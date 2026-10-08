defmodule Arbor.MCP.Transport.SecurityIntegrationTest do
  use ExUnit.Case, async: false

  # These tests rely on several helper modules:
  #
  # - `Arbor.MCP.Transport.SecurityGuard`: The security middleware being tested.
  #
  # - `Arbor.MCP.Test.Support.Transports` (test/support/transports.ex): A helper
  #   module with functions to start and interact with test versions of each
  #   transport (HTTP, Stdio, BEAM).
  #   - Each transport helper returns `{:ok, response, received_command}` on
  #     success, where `received_command` is the command as seen by the final
  #     handler (after middleware processing).
  #
  # - `Arbor.MCP.ConsentHandler.Test`: A test consent handler that allows setting
  #   consent status for specific tokens during tests.

  alias Arbor.MCP.ConsentHandler.Test, as: ConsentHandler
  alias Arbor.MCP.Internal.ConsentCache
  alias Arbor.MCP.Test.Support.Transports
  alias Arbor.MCP.Transport.SecurityGuard

  @command %{
    jsonrpc: "2.0",
    method: "resources/read",
    params: %{uri: "https://api.example.com/data"},
    id: 1
  }
  @token "secret-test-token-for-integration"

  # Reset consent state before each test to ensure isolation.
  setup do
    # Ensure ConsentHandler.Test and ConsentCache are running.
    # Other tests may stop the Arbor.MCP application, killing these processes.
    unless Process.whereis(Arbor.MCP.ConsentHandler.Test) do
      Arbor.MCP.ConsentHandler.Test.start_link()
    end

    unless Process.whereis(Arbor.MCP.Internal.ConsentCache) do
      Arbor.MCP.Internal.ConsentCache.start_link([])
    end

    # Clear both the agent state AND the ETS cache for test isolation
    ConsentHandler.clear_all_consents()
    ConsentCache.clear()
    :ok
  end

  # Security tests are implemented individually in each transport describe block below

  describe "HTTP Transport Integration" do
    setup do
      # Assumes a helper that starts a test endpoint with the SecurityGuard.
      {:ok, endpoint} = Transports.Http.start_test_endpoint(security_guard: SecurityGuard)

      # The client function abstracts away the transport details (e.g., headers).
      client = fn command ->
        token = get_in(command, [:meta, :token])
        headers = if token, do: [{"authorization", "Bearer " <> token}], else: []
        # The SecurityGuard is expected to handle the token from the header.
        # The command sent over HTTP should not contain the meta field.
        command_to_send = Map.delete(command, :meta)
        Transports.Http.request(endpoint, command_to_send, headers)
      end

      %{client: client}
    end

    test "allows requests with granted consent", %{client: client} do
      # Pre-grant consent for this test - user derived from token, origin from URL
      ConsentHandler.set_consent_response("integration", "https://api.example.com", :approved)

      request_with_token = Map.put(@command, :meta, %{token: @token})

      assert {:ok, response, received_command} = client.(request_with_token)
      assert response["jsonrpc"] == "2.0"
      # Verify the command was processed and token was handled by SecurityGuard
      assert received_command.method == @command.method
      assert received_command.params == @command.params
    end

    test "blocks requests without consent", %{client: client} do
      request_with_token = Map.put(@command, :meta, %{token: @token})

      # Should be blocked because consent was not granted
      result = client.(request_with_token)
      assert {:error, error_type} = result
      assert error_type in [:consent_required, :consent_denied]
    end
  end

  describe "Stdio Transport Integration" do
    setup do
      {:ok, pid} = Transports.Stdio.start_test_process(security_guard: SecurityGuard)
      client = &Transports.Stdio.request(pid, &1)
      %{client: client}
    end

    test "allows requests with granted consent", %{client: client} do
      # Pre-grant consent for this test - user derived from token, origin from URL
      ConsentHandler.set_consent_response("integration", "https://api.example.com", :approved)

      request_with_token = Map.put(@command, :meta, %{token: @token})

      assert {:ok, response, received_command} = client.(request_with_token)
      assert response["jsonrpc"] == "2.0"
      # Verify the command was processed and token was handled by SecurityGuard
      assert received_command.method == @command.method
      assert received_command.params == @command.params
    end

    test "blocks requests without consent", %{client: client} do
      request_with_token = Map.put(@command, :meta, %{token: @token})

      # Should be blocked because consent was not granted
      result = client.(request_with_token)
      assert {:error, error_type} = result
      assert error_type in [:consent_required, :consent_denied]
    end
  end

  describe "BEAM Transport Integration" do
    setup do
      {:ok, pid} = Transports.Beam.start_test_server(security_guard: SecurityGuard)
      client = &Transports.Beam.request(pid, &1)
      %{client: client}
    end

    test "allows requests with granted consent", %{client: client} do
      # Pre-grant consent for this test - user derived from token, origin from URL
      ConsentHandler.set_consent_response("integration", "https://api.example.com", :approved)

      request_with_token = Map.put(@command, :meta, %{token: @token})

      assert {:ok, response, received_command} = client.(request_with_token)
      assert response["jsonrpc"] == "2.0"
      # Verify the command was processed and token was handled by SecurityGuard
      assert received_command.method == @command.method
      assert received_command.params == @command.params
    end

    test "blocks requests without consent", %{client: client} do
      request_with_token = Map.put(@command, :meta, %{token: @token})

      # Should be blocked because consent was not granted
      result = client.(request_with_token)
      assert {:error, error_type} = result
      assert error_type in [:consent_required, :consent_denied]
    end
  end

  describe "Performance Benchmarks" do
    setup do
      # Use the BEAM transport for benchmarking as it has the lowest overhead.
      {:ok, pid} = Transports.Beam.start_test_server(security_guard: SecurityGuard)
      client = &Transports.Beam.request(pid, &1)
      # Pre-grant consent so we measure the "happy path" performance.
      ConsentHandler.set_consent_response("test_user", "test_origin", :approved)
      %{client: client}
    end

    @tag :benchmark
    test "SecurityGuard overhead is within target (<100ms)", %{client: client} do
      request_with_token = Map.put(@command, :meta, %{token: @token})

      # Benchee provides statistically sound measurements.
      # This test will only run if `mix test --include benchmark` is used.
      result =
        Benchee.run(
          %{"security_guard_check" => fn -> client.(request_with_token) end},
          time: 1,
          # Don't print results to console during the test run.
          formatters: []
        )

      scenario = Enum.find(result.scenarios, &(&1.name == "security_guard_check"))
      avg_time = scenario.run_time_data.statistics.average
      # Ensure the average execution time is less than 100 milliseconds.
      # Convert nanoseconds to milliseconds (avg_time is in nanoseconds)
      avg_time_ms = avg_time / 1_000_000
      assert avg_time_ms < 100.0, "Expected average time < 100ms, but got #{avg_time_ms}ms"
    end
  end
end
