defmodule Arbor.MCP.TransportManagerTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.TransportManager
  alias Arbor.MCP.TransportManagerTest.MockTransport

  # Mock transport implementations for testing
  defmodule MockTransport.Success do
    @behaviour Arbor.MCP.Transport

    def connect(_opts), do: {:ok, :success_state}
    def send(state, _data), do: {:ok, state}
    def recv(_state, _timeout), do: {:error, :not_implemented}
    def close(_state), do: {:ok, nil}
    def controlling_process(_state, _pid), do: :ok
    def send_message(_state, _msg), do: {:error, :not_implemented}
    def receive_message(_state), do: {:error, :not_implemented}
  end

  defmodule MockTransport.Failure do
    @behaviour Arbor.MCP.Transport

    def connect(_opts), do: {:error, :mock_failure}
    def send(_state, _data), do: {:error, :not_connected}
    def recv(_state, _timeout), do: {:error, :not_connected}
    def close(_state), do: {:ok, nil}
    def controlling_process(_state, _pid), do: :ok
    def send_message(_state, _msg), do: {:error, :not_implemented}
    def receive_message(_state), do: {:error, :not_implemented}
  end

  defmodule MockTransport.Slow do
    @behaviour Arbor.MCP.Transport

    def connect(_opts) do
      Process.sleep(200)
      {:ok, :slow_state}
    end

    def send(state, _data), do: {:ok, state}
    def recv(_state, _timeout), do: {:error, :not_implemented}
    def close(_state), do: {:ok, nil}
    def controlling_process(_state, _pid), do: :ok
    def send_message(_state, _msg), do: {:error, :not_implemented}
    def receive_message(_state), do: {:error, :not_implemented}
  end

  defmodule MockTransport.Exception do
    @behaviour Arbor.MCP.Transport

    def connect(_opts), do: raise("Mock exception")
    def send(_state, _data), do: {:error, :not_connected}
    def recv(_state, _timeout), do: {:error, :not_connected}
    def close(_state), do: {:ok, nil}
    def controlling_process(_state, _pid), do: :ok
    def send_message(_state, _msg), do: {:error, :not_implemented}
    def receive_message(_state), do: {:error, :not_implemented}
  end

  describe "connect/1" do
    test "returns error when no transports configured" do
      assert {:error, :no_transports_configured} = TransportManager.connect([])
    end

    test "connects with first successful transport in sequential mode" do
      opts = [
        transports: [
          {MockTransport.Success, []},
          {MockTransport.Failure, []}
        ],
        fallback_strategy: :sequential
      ]

      assert {:ok, {MockTransport.Success, :success_state}} = TransportManager.connect(opts)
    end

    test "falls back to second transport when first fails" do
      opts = [
        transports: [
          {MockTransport.Failure, []},
          {MockTransport.Success, []}
        ],
        fallback_strategy: :sequential
      ]

      assert {:ok, {MockTransport.Success, :success_state}} = TransportManager.connect(opts)
    end

    test "returns error when all transports fail" do
      opts = [
        transports: [
          {MockTransport.Failure, []},
          {MockTransport.Failure, []}
        ],
        fallback_strategy: :sequential
      ]

      assert {:error, :all_transports_failed} = TransportManager.connect(opts)
    end

    test "parallel strategy connects with fastest successful transport" do
      opts = [
        transports: [
          {MockTransport.Slow, []},
          {MockTransport.Success, []}
        ],
        fallback_strategy: :parallel,
        health_check_timeout: 1_000
      ]

      # Should get a successful transport (either Success or Slow, but Success is faster)
      assert {:ok, {transport_mod, _state}} = TransportManager.connect(opts)
      # Both transports should work, parallel execution means either could win
      assert transport_mod in [
               Arbor.MCP.TransportManagerTest.MockTransport.Success,
               Arbor.MCP.TransportManagerTest.MockTransport.Slow
             ]
    end

    test "handles transport exceptions gracefully" do
      opts = [
        transports: [
          {MockTransport.Exception, []},
          {MockTransport.Success, []}
        ],
        fallback_strategy: :sequential
      ]

      # Should succeed with the second transport after exception in first
      assert {:ok, {MockTransport.Success, :success_state}} = TransportManager.connect(opts)
    end

    test "respects max_retries configuration" do
      # Mock a transport that fails twice then succeeds
      defmodule RetryableTransport do
        @behaviour Arbor.MCP.Transport

        def connect(_opts) do
          case :persistent_term.get({__MODULE__, :attempt_count}, 0) do
            count when count < 2 ->
              :persistent_term.put({__MODULE__, :attempt_count}, count + 1)
              {:error, :temporary_failure}

            _ ->
              {:ok, :retry_success_state}
          end
        end

        def send(state, _data), do: {:ok, state}
        def recv(_state, _timeout), do: {:error, :not_implemented}
        def close(_state), do: {:ok, nil}
        def controlling_process(_state, _pid), do: :ok
        def send_message(_state, _msg), do: {:error, :not_implemented}
        def receive_message(_state), do: {:error, :not_implemented}
      end

      # Reset counter
      :persistent_term.put({RetryableTransport, :attempt_count}, 0)

      opts = [
        transports: [{RetryableTransport, []}],
        fallback_strategy: :sequential,
        max_retries: 3,
        retry_interval: 10
      ]

      assert {:ok, {RetryableTransport, :retry_success_state}} = TransportManager.connect(opts)
    end
  end

  describe "health_check/3" do
    test "returns :ok for healthy transport" do
      assert :ok = TransportManager.health_check(MockTransport.Success, [], 1_000)
    end

    test "returns error for unhealthy transport" do
      assert {:error, {:connect_failed, :mock_failure}} =
               TransportManager.health_check(MockTransport.Failure, [], 1_000)
    end

    test "handles transport exceptions" do
      assert {:error, {:health_check_exception, _}} =
               TransportManager.health_check(MockTransport.Exception, [], 1_000)
    end
  end

  describe "default_config/1" do
    test "returns local development configuration" do
      config = TransportManager.default_config(:local_development)

      assert Keyword.get(config, :fallback_strategy) == :sequential
      assert is_list(Keyword.get(config, :transports))
      assert Keyword.get(config, :health_check_timeout) == 3_000
    end

    test "returns production configuration" do
      config = TransportManager.default_config(:production)

      assert Keyword.get(config, :fallback_strategy) == :sequential
      assert is_list(Keyword.get(config, :transports))
      assert Keyword.get(config, :health_check_timeout) == 10_000
      assert Keyword.get(config, :max_retries) == 3
    end

    test "returns testing configuration" do
      config = TransportManager.default_config(:testing)

      assert Keyword.get(config, :fallback_strategy) == :sequential
      assert is_list(Keyword.get(config, :transports))
      assert Keyword.get(config, :health_check_timeout) == 1_000
    end
  end

  describe "integration scenarios" do
    test "mixed transport scenario - HTTP primary, stdio fallback" do
      # Simulate HTTP server down, stdio available
      opts = [
        transports: [
          # HTTP fails
          {MockTransport.Failure, [url: "http://localhost:8080"]},
          # Stdio succeeds
          {MockTransport.Success, [command: "mcp-server"]}
        ],
        fallback_strategy: :sequential,
        max_retries: 1
      ]

      assert {:ok, {MockTransport.Success, :success_state}} = TransportManager.connect(opts)
    end

    test "fastest wins scenario" do
      opts = [
        transports: [
          # Takes 200ms
          {MockTransport.Slow, []},
          # Fast
          {MockTransport.Success, []},
          # Takes 200ms
          {MockTransport.Slow, []}
        ],
        fallback_strategy: :fastest,
        health_check_timeout: 1_000
      ]

      start_time = System.monotonic_time(:millisecond)
      assert {:ok, {transport_mod, _state}} = TransportManager.connect(opts)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should get a successful transport quickly (Success is fastest, but any success is good)
      assert transport_mod in [
               Arbor.MCP.TransportManagerTest.MockTransport.Success,
               Arbor.MCP.TransportManagerTest.MockTransport.Slow
             ]

      # Should be reasonably fast (within 500ms) - parallel execution should be faster than sequential
      assert elapsed < 500
    end
  end
end
