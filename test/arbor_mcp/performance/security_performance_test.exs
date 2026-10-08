defmodule Arbor.MCP.Performance.SecurityPerformanceTest do
  @moduledoc """
  Performance tests for Arbor.MCP security features.

  These tests validate that security validation meets the <100μs performance target
  and doesn't introduce significant overhead to transport operations.
  """

  use ExUnit.Case, async: false

  @moduletag :performance
  @moduletag :slow

  alias Arbor.MCP.ConsentHandler.Test, as: TestConsentHandler
  alias Arbor.MCP.Internal.ConsentCache
  alias Arbor.MCP.Internal.SecurityConfig
  alias Arbor.MCP.Transport.SecurityGuard

  @performance_target_microseconds 100
  @performance_samples 20

  setup_all do
    # Start test consent handler for performance tests
    case TestConsentHandler.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      TestConsentHandler.stop()
    end)

    :ok
  end

  setup do
    # Clear consent state between tests
    TestConsentHandler.clear_all_consents()
    ConsentCache.clear()
    :ok
  end

  describe "SecurityGuard Performance" do
    test "validates request within performance target" do
      # Setup test scenario
      request = %{
        url: "https://api.example.com/data",
        headers: [{"Authorization", "Bearer token"}],
        method: "GET",
        transport: :http,
        user_id: "test_user"
      }

      config = SecurityConfig.get_transport_config(:http)

      # Warm up
      for _ <- 1..10 do
        SecurityGuard.validate_request(request, config)
      end

      # Measure the guard itself, independent of the configured Logger backend.
      # Production commonly filters debug logs, while test Logger scheduling on
      # a shared runner can otherwise dominate a sub-100us operation.
      time_microseconds =
        best_time(fn -> SecurityGuard.validate_request(request, config) end)

      assert time_microseconds < @performance_target_microseconds,
             "Security validation took #{time_microseconds}μs, exceeds target of #{@performance_target_microseconds}μs"
    end

    test "internal URL validation is fast" do
      request = %{
        url: "https://localhost:8080/api",
        headers: [{"Authorization", "Bearer token"}],
        method: "GET",
        transport: :http,
        user_id: "test_user"
      }

      config = SecurityConfig.get_transport_config(:http)

      # Warm up
      for _ <- 1..10 do
        SecurityGuard.validate_request(request, config)
      end

      best_time = best_time(fn -> SecurityGuard.validate_request(request, config) end)

      # Internal URLs should be even faster since they skip consent checks
      assert best_time < @performance_target_microseconds,
             "Internal URL validation took #{best_time}μs (best of #{@performance_samples}), should be under #{@performance_target_microseconds}μs"
    end

    test "consent cache hit performance" do
      # Pre-approve consent for fast cache hit
      TestConsentHandler.set_consent_response("test_user", "https://api.example.com", :approved)

      request = %{
        url: "https://api.example.com/data",
        headers: [],
        method: "GET",
        transport: :http,
        user_id: "test_user"
      }

      config =
        SecurityConfig.get_transport_config(:http, %{consent_handler: TestConsentHandler})

      # First request to populate cache
      assert {:ok, _request} = SecurityGuard.validate_request(request, config)

      # The cache write is asynchronous; synchronize with its server before
      # measuring the direct ETS lookup path.
      :sys.get_state(ConsentCache)

      assert {:ok, _expires_at} =
               ConsentCache.check_consent("test_user", "https://api.example.com")

      # Warm up cache thoroughly
      for _ <- 1..100 do
        SecurityGuard.validate_request(request, config)
      end

      best_time = best_time(fn -> SecurityGuard.validate_request(request, config) end)

      assert best_time < @performance_target_microseconds,
             "Consent cache hit took #{best_time}μs (best of #{@performance_samples}), exceeds target of #{@performance_target_microseconds}μs"
    end

    test "concurrent validation performance" do
      request = %{
        url: "https://localhost:8080/api",
        headers: [{"Authorization", "Bearer token"}],
        method: "GET",
        transport: :http,
        user_id: "test_user"
      }

      config = SecurityConfig.get_transport_config(:http)

      # Warm up - ensure code is loaded and JIT'd
      for i <- 1..20 do
        user_request = %{request | user_id: "warmup_#{i}"}
        SecurityGuard.validate_request(user_request, config)
      end

      # Test concurrent access doesn't cause significant slowdown
      # Note: Task spawning adds overhead beyond the validation itself,
      # so we use a higher threshold for concurrent scenarios
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            # Warm up inside the task to avoid measuring process startup
            user_request = %{request | user_id: "user_#{i}"}
            SecurityGuard.validate_request(user_request, config)

            {time_microseconds, _result} =
              :timer.tc(fn ->
                SecurityGuard.validate_request(user_request, config)
              end)

            time_microseconds
          end)
        end

      times = Task.await_many(tasks, 5000)
      avg_time = Enum.sum(times) / length(times)
      max_time = Enum.max(times)

      # Concurrent tasks have overhead from Task spawning and scheduling
      # Use 50x the base target to account for CI/concurrent test load
      concurrent_target = @performance_target_microseconds * 50

      assert avg_time < concurrent_target,
             "Average concurrent validation time #{avg_time}μs exceeds target of #{concurrent_target}μs"

      assert max_time < concurrent_target * 2,
             "Max concurrent validation time #{max_time}μs exceeds reasonable threshold of #{concurrent_target * 2}μs"
    end
  end

  describe "Transport Integration Performance" do
    test "HTTP transport security overhead is minimal" do
      # This would require actual HTTP transport integration
      # For now, we'll test the SecurityGuard component directly

      request = %{
        url: "https://api.example.com/data",
        headers: [
          {"Authorization", "Bearer token"},
          {"Content-Type", "application/json"},
          {"User-Agent", "Arbor.MCP/1.0"}
        ],
        method: "POST",
        transport: :http,
        user_id: "http_user"
      }

      config = SecurityConfig.get_transport_config(:http)

      # Warm up (100 iterations for JIT + cache warmth)
      for _ <- 1..100 do
        SecurityGuard.validate_request(request, config)
      end

      best_time = best_time(fn -> SecurityGuard.validate_request(request, config) end)

      assert best_time < @performance_target_microseconds,
             "HTTP security validation took #{best_time}μs (best of #{@performance_samples}), exceeds target"
    end

    test "stdio transport security overhead is minimal" do
      request = %{
        url: "https://external-api.com/resource",
        headers: [],
        method: "GET",
        transport: :stdio,
        user_id: "stdio_user"
      }

      config = SecurityConfig.get_transport_config(:stdio)

      # Warm up
      for _ <- 1..10 do
        SecurityGuard.validate_request(request, config)
      end

      time_microseconds =
        best_time(fn -> SecurityGuard.validate_request(request, config) end)

      assert time_microseconds < @performance_target_microseconds,
             "Stdio security validation took #{time_microseconds}μs, exceeds target"
    end

    test "BEAM transport security overhead is minimal" do
      request = %{
        url: "beam://external_service/method",
        headers: [],
        method: "call",
        transport: :beam,
        user_id: "beam_user"
      }

      config = SecurityConfig.get_transport_config(:beam)

      # Warm up
      for _ <- 1..10 do
        SecurityGuard.validate_request(request, config)
      end

      time_microseconds =
        best_time(fn -> SecurityGuard.validate_request(request, config) end)

      assert time_microseconds < @performance_target_microseconds,
             "BEAM security validation took #{time_microseconds}μs, exceeds target"
    end
  end

  describe "Performance Regression Tests" do
    test "token stripping performance scales with header count" do
      base_headers = [{"Content-Type", "application/json"}]

      # Warm up the security guard code paths
      warmup_request = %{
        url: "https://api.example.com/data",
        headers: base_headers ++ [{"X-Token-warmup", "secret"}],
        method: "GET",
        transport: :http,
        user_id: "test_user"
      }

      warmup_config = SecurityConfig.get_transport_config(:http)

      for _ <- 1..10 do
        SecurityGuard.validate_request(warmup_request, warmup_config)
      end

      # Test with increasing numbers of sensitive headers
      for header_count <- [1, 5, 10, 20] do
        sensitive_headers =
          for i <- 1..header_count do
            {"X-Token-#{i}", "secret-#{i}"}
          end

        request = %{
          url: "https://api.example.com/data",
          headers: base_headers ++ sensitive_headers,
          method: "GET",
          transport: :http,
          user_id: "test_user"
        }

        config = SecurityConfig.get_transport_config(:http)

        best_time = best_time(fn -> SecurityGuard.validate_request(request, config) end)

        # Performance should scale reasonably with header count
        max_time = @performance_target_microseconds * (1 + header_count / 10)

        assert best_time < max_time,
               "Validation with #{header_count} headers took #{best_time}μs (best of #{@performance_samples}), exceeds scaled target of #{max_time}μs"
      end
    end
  end

  defp best_time(fun, samples \\ @performance_samples) do
    previous_logger_level = Logger.get_process_level(self())
    Logger.put_process_level(self(), :none)

    try do
      1..samples
      |> Enum.map(fn _ ->
        {time_microseconds, _result} = :timer.tc(fun)
        time_microseconds
      end)
      |> Enum.min()
    after
      restore_logger_level(previous_logger_level)
    end
  end

  defp restore_logger_level(nil), do: Logger.delete_process_level(self())
  defp restore_logger_level(level), do: Logger.put_process_level(self(), level)
end
