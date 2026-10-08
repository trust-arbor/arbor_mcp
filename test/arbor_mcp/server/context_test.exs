defmodule Arbor.MCP.Server.ContextTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Server.Cancellation
  alias Arbor.MCP.Server.Context
  alias Arbor.MCP.Server.RequestContext

  setup do
    start_supervised!(Cancellation)
    :ok
  end

  defp context(request_id) do
    %RequestContext{
      method: "tools/call",
      request_id: request_id,
      request?: true,
      era: :legacy
    }
  end

  describe "cancelled?/0" do
    test "is false when there is no request context" do
      refute Context.cancelled?()
    end

    test "is false when the current request has not been cancelled" do
      request_id = "ctx-not-cancelled-#{System.unique_integer([:positive])}"

      Context.with_context(context(request_id), fn ->
        refute Context.cancelled?()
      end)
    end

    test "is true after a cancel is recorded for the current request id" do
      request_id = "ctx-cancelled-#{System.unique_integer([:positive])}"

      Context.with_context(context(request_id), fn ->
        refute Context.cancelled?()
        :ok = Cancellation.mark_cancelled(request_id)
        assert Context.cancelled?()
      end)
    end

    test "is false for a different request id than the one that was cancelled" do
      current_id = "ctx-current-#{System.unique_integer([:positive])}"
      other_id = "ctx-other-#{System.unique_integer([:positive])}"

      Context.with_context(context(current_id), fn ->
        :ok = Cancellation.mark_cancelled(other_id)
        refute Context.cancelled?()
      end)
    end

    test "becomes true when another process records the cancel" do
      request_id = "ctx-oob-#{System.unique_integer([:positive])}"
      parent = self()

      Context.with_context(context(request_id), fn ->
        refute Context.cancelled?()

        spawn(fn ->
          :ok = Cancellation.mark_cancelled(request_id)
          send(parent, :marked)
        end)

        assert_receive :marked, 1_000
        assert Context.cancelled?()
      end)
    end
  end

  test "scope is absent outside runtime work, including legacy request context" do
    assert Context.scope() == nil

    Context.with_context(context("legacy"), fn ->
      assert Context.scope() == nil
    end)
  end
end
