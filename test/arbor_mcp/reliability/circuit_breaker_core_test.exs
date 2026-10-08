defmodule Arbor.MCP.Reliability.CircuitBreaker.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Reliability.CircuitBreaker.Core

  @t0 1_000_000

  defp new_cb(config \\ %{}, now_ms \\ @t0) do
    Core.new(config, now_ms)
  end

  describe "new/2" do
    test "records the injected clock as created_at instead of wall time" do
      cb = new_cb(%{}, 42)
      stats = Core.get_stats(cb)

      assert stats.created_at == 42
      assert stats.state == :closed
      assert System.system_time(:millisecond) > 1_000
    end
  end

  describe "record_success/2 and record_failure/2" do
    test "store the injected now_ms on last_* timestamps" do
      cb =
        new_cb(%{failure_threshold: 5})
        |> Core.record_success(@t0 + 10)
        |> Core.record_failure(@t0 + 20)

      assert cb.last_success_time == @t0 + 10
      assert cb.last_failure_time == @t0 + 20
      assert Core.get_stats(cb).last_success_time == @t0 + 10
      assert Core.get_stats(cb).last_failure_time == @t0 + 20
    end

    test "opens at the injected now_ms when the failure threshold is reached" do
      cb =
        new_cb(%{failure_threshold: 2, reset_timeout: 5_000})
        |> Core.record_failure(@t0)
        |> Core.record_failure(@t0 + 3)

      assert cb.state == :open
      assert cb.opened_at == @t0 + 3
      assert Core.get_stats(cb).opened_at == @t0 + 3
    end
  end

  describe "open to half-open elapsed duration" do
    test "stays open until reset_timeout elapses on the injected clock" do
      cb =
        new_cb(%{failure_threshold: 1, reset_timeout: 5_000})
        |> Core.record_failure(@t0)

      assert Core.get_state(cb, @t0) == :open
      assert Core.get_state(cb, @t0 + 4_999) == :open
      refute Core.allow_request?(cb, @t0 + 4_999)

      assert Core.get_state(cb, @t0 + 5_000) == :half_open
      assert Core.allow_request?(cb, @t0 + 5_000)

      {allowed, updated} = Core.allow_request_with_state?(cb, @t0 + 5_000)
      assert allowed
      assert updated.state == :half_open
      assert updated.stats.automatic_half_opens == 1
    end

    test "a backwards clock does not produce a negative duration or half-open early" do
      cb =
        new_cb(%{failure_threshold: 1, reset_timeout: 5_000})
        |> Core.record_failure(@t0)

      assert Core.get_state(cb, @t0 - 10_000) == :open
      refute Core.allow_request?(cb, @t0 - 10_000)

      {allowed, updated} = Core.allow_request_with_state?(cb, @t0 - 1)
      refute allowed
      assert updated.state == :open
      assert updated.stats.automatic_half_opens == 0
    end
  end

  describe "half-open idle close" do
    test "closes after reset_timeout since last_success_time" do
      cb =
        new_cb(%{failure_threshold: 1, success_threshold: 3, reset_timeout: 1_000})
        |> Core.force_state(:half_open, @t0)
        |> Core.record_success(@t0)

      assert cb.state == :half_open
      assert Core.get_state(cb, @t0 + 999) == :half_open
      assert Core.get_state(cb, @t0 + 1_000) == :closed
    end

    test "a backwards clock does not close half-open early" do
      cb =
        new_cb(%{failure_threshold: 1, success_threshold: 3, reset_timeout: 1_000})
        |> Core.force_state(:half_open, @t0)
        |> Core.record_success(@t0)

      assert Core.get_state(cb, @t0 - 5_000) == :half_open
    end
  end

  describe "force_state/3" do
    test "manual open records injected opened_at" do
      cb = new_cb() |> Core.force_state(:open, @t0 + 7)
      assert cb.state == :open
      assert cb.opened_at == @t0 + 7
    end
  end

  describe "public stats shape" do
    test "preserves the documented keys" do
      cb = new_cb() |> Core.record_success(@t0) |> Core.record_failure(@t0 + 1)
      stats = Core.get_stats(cb)

      assert stats.total_calls == 2
      assert stats.successful_calls == 1
      assert stats.failed_calls == 1
      assert stats.rejected_calls == 0
      assert stats.state == :closed
      assert stats.current_state == :closed
    end
  end
end
