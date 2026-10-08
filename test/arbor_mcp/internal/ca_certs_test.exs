defmodule Arbor.MCP.Internal.CACertsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.MCP.Internal.CACerts
  alias Arbor.MCP.Internal.CACerts.UnavailableError

  @os_certs [<<1, 2, 3>>]

  # Stands in for `/usr/bin/security` stalling on the keychain.
  @stall &__MODULE__.stall/0
  def stall, do: Process.sleep(:infinity)

  setup do
    key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(key) end)

    # Telemetry handlers are global; only forward events for this test's
    # cache, identified by the process that triggered them.
    test_pid = self()
    handler = {__MODULE__, key}

    :telemetry.attach_many(
      handler,
      [[:arbor_mcp, :cacerts, :os_load, :failed], [:arbor_mcp, :cacerts, :os_load, :recovered]],
      fn event, _measurements, metadata, _config ->
        if self() == test_pid or Process.get(:"$callers", []) |> Enum.member?(test_pid),
          do: send(test_pid, {:telemetry, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{key: key}
  end

  defp opts(key, extra), do: Keyword.merge([cache_key: key, os_timeout_ms: 200], extra)

  defp counting(result) do
    parent = self()

    fn ->
      send(parent, :os_load_attempted)
      result
    end
  end

  test "uses the OS store and caches it", %{key: key} do
    loader = counting(@os_certs)

    assert CACerts.get(opts(key, loader: loader)) == @os_certs
    assert CACerts.get(opts(key, loader: loader)) == @os_certs
    assert_received :os_load_attempted
    refute_received :os_load_attempted
  end

  describe "default (fallback: :none)" do
    test "fails closed when the OS load stalls past the deadline", %{key: key} do
      log =
        capture_log(fn ->
          error =
            assert_raise UnavailableError, fn ->
              CACerts.get(opts(key, loader: @stall, os_timeout_ms: 50))
            end

          assert Exception.message(error) =~ "timed out after 50ms"
          assert Exception.message(error) =~ "fallback: :castore"
        end)

      assert log =~ "outbound HTTPS requests will fail"

      assert_received {:telemetry, [:arbor_mcp, :cacerts, :os_load, :failed],
                       %{reason: :timeout, fallback: :none}}
    end

    test "fails closed when the OS load raises or finds nothing", %{key: key} do
      for {loader, tag} <- [
            {fn -> raise "keychain unavailable" end, :error},
            {fn -> [] end, :no_certificates}
          ] do
        :persistent_term.erase(key)

        capture_log(fn ->
          assert_raise UnavailableError, fn -> CACerts.get(opts(key, loader: loader)) end
        end)

        assert_received {:telemetry, [:arbor_mcp, :cacerts, :os_load, :failed], %{reason: ^tag}}
      end
    end

    test "caches a failure so later callers fail fast without retrying", %{key: key} do
      capture_log(fn ->
        assert_raise UnavailableError, fn -> CACerts.get(opts(key, loader: fn -> [] end)) end

        # Within failure_ttl_ms the OS load is not attempted again.
        assert_raise UnavailableError, fn ->
          CACerts.get(opts(key, loader: counting(@os_certs)))
        end
      end)

      refute_received :os_load_attempted
    end

    test "retries after the failure TTL and recovers", %{key: key} do
      capture_log(fn ->
        assert_raise UnavailableError, fn ->
          CACerts.get(opts(key, loader: fn -> [] end, failure_ttl_ms: 0))
        end

        assert CACerts.get(opts(key, loader: fn -> @os_certs end)) == @os_certs
      end)

      assert_received {:telemetry, [:arbor_mcp, :cacerts, :os_load, :recovered],
                       %{previous: :failed}}
    end
  end

  describe "fallback: :castore" do
    test "uses the CAStore bundle when the OS load stalls", %{key: key} do
      log =
        capture_log(fn ->
          assert CACerts.get(opts(key, loader: @stall, os_timeout_ms: 50, fallback: :castore)) ==
                   CACerts.castore_certs()
        end)

      assert log =~ "timed out after 50ms"
      assert log =~ "fallback: :castore is configured"

      assert_received {:telemetry, [:arbor_mcp, :cacerts, :os_load, :failed],
                       %{fallback: :castore}}
    end

    test "is replaced by the OS store once a background retry succeeds", %{key: key} do
      capture_log(fn ->
        CACerts.get(opts(key, loader: fn -> [] end, fallback: :castore, refresh_interval_ms: 0))

        # The retry is due immediately; this call still returns the fallback
        # without waiting and starts the retry in the background.
        assert CACerts.get(opts(key, loader: fn -> @os_certs end, fallback: :castore)) ==
                 CACerts.castore_certs()

        assert Arbor.MCP.TestHelpers.wait_until(fn ->
                 CACerts.get(opts(key, loader: fn -> @os_certs end, fallback: :castore)) ==
                   @os_certs
               end) == :ok
      end)
    end
  end

  describe "claim_refresh/2" do
    # A caller that read an expired fallback may reach the claim after a
    # background refresh has already stored the OS store.
    test "never overwrites a recovered OS store", %{key: key} do
      :persistent_term.put(key, {:os, @os_certs})

      refute CACerts.claim_refresh(key, opts(key, loader: fn -> @os_certs end))
      assert :persistent_term.get(key) == {:os, @os_certs}
    end

    test "claims a due refresh once, and not one that is not yet due", %{key: key} do
      certs = CACerts.castore_certs()
      :persistent_term.put(key, {:fallback, certs, System.monotonic_time(:millisecond) - 1})
      claim_opts = opts(key, loader: fn -> [] end, refresh_interval_ms: 60_000)

      assert CACerts.claim_refresh(key, claim_opts)
      assert {:fallback, ^certs, refresh_at} = :persistent_term.get(key)
      assert refresh_at > System.monotonic_time(:millisecond)

      # A second caller holding the same stale read finds it already claimed.
      refute CACerts.claim_refresh(key, claim_opts)
    end
  end

  test "the CAStore bundle parses to DER certificates" do
    certs = CACerts.castore_certs()

    assert length(certs) > 100
    assert Enum.all?(certs, &is_binary/1)
    assert {:OTPCertificate, _, _, _} = :public_key.pkix_decode_cert(hd(certs), :otp)
  end
end
