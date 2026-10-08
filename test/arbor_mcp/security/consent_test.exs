defmodule Arbor.MCP.Security.ConsentTest do
  @moduledoc """
  Tests the consent expiry contract.

  A consent handler reports when a grant expires. Historically a bare integer
  was read as a `System.monotonic_time(:second)` value, so a handler returning
  the obvious thing — Unix epoch seconds — produced a monotonic value decades
  in the future and consent that never expired. These tests pin down every
  supported expiry form and prove the ambiguous ones fail closed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.MCP.Internal.ConsentCache
  alias Arbor.MCP.Security.Consent

  @origin "https://consent-test.example.com"
  @url @origin <> "/resource"

  defmodule ScriptedHandler do
    @moduledoc false
    @behaviour Arbor.MCP.ConsentHandler

    @impl Arbor.MCP.ConsentHandler
    def request_consent(_user_id, _origin, context) do
      case Map.get(context, :test_pid) do
        nil -> :ok
        pid -> send(pid, :consent_requested)
      end

      Map.fetch!(context, :reply).(context)
    end

    @impl Arbor.MCP.ConsentHandler
    def check_existing_consent(_user_id, _origin), do: {:not_found}

    @impl Arbor.MCP.ConsentHandler
    def revoke_consent(_user_id, _origin), do: :ok
  end

  setup do
    ConsentCache.clear()
    %{user_id: "consent-test-#{System.unique_integer([:positive])}"}
  end

  defp ensure(user_id, reply_fun) do
    config = %{
      trusted_origins: [],
      consent_handler_opts: [test_pid: self(), reply: reply_fun]
    }

    Consent.ensure_user_consent(user_id, @url, :http, ScriptedHandler, config)
  end

  # store_consent/3 is a cast; flush the ConsentCache mailbox before reading.
  defp sync_cache do
    :sys.get_state(ConsentCache)
    :ok
  end

  describe "expiry forms that grant consent" do
    test "{:ttl, seconds}", %{user_id: user_id} do
      assert :ok = ensure(user_id, fn _ctx -> {:ok, {:ttl, 3600}} end)
      assert_received :consent_requested

      sync_cache()
      assert {:ok, expires_at} = ConsentCache.check_consent(user_id, @origin)
      ttl = expires_at - System.monotonic_time(:second)
      assert ttl > 3500 and ttl <= 3600
    end

    test "a DateTime", %{user_id: user_id} do
      expires_at = DateTime.add(DateTime.utc_now(), 1800, :second)
      assert :ok = ensure(user_id, fn _ctx -> {:ok, expires_at} end)

      sync_cache()
      assert {:ok, monotonic} = ConsentCache.check_consent(user_id, @origin)
      ttl = monotonic - System.monotonic_time(:second)
      assert ttl > 1700 and ttl <= 1800
    end

    test "{:unix, seconds}", %{user_id: user_id} do
      unix = System.os_time(:second) + 600
      assert :ok = ensure(user_id, fn _ctx -> {:ok, {:unix, unix}} end)

      sync_cache()
      assert {:ok, monotonic} = ConsentCache.check_consent(user_id, @origin)
      ttl = monotonic - System.monotonic_time(:second)
      assert ttl > 500 and ttl <= 600
    end

    test "{:monotonic, seconds}", %{user_id: user_id} do
      monotonic = System.monotonic_time(:second) + 900
      assert :ok = ensure(user_id, fn _ctx -> {:ok, {:monotonic, monotonic}} end)

      sync_cache()
      assert {:ok, ^monotonic} = ConsentCache.check_consent(user_id, @origin)
    end

    test "a bare integer that is a plausible monotonic value", %{user_id: user_id} do
      monotonic = System.monotonic_time(:second) + 300
      assert :ok = ensure(user_id, fn _ctx -> {:ok, monotonic} end)

      sync_cache()
      assert {:ok, ^monotonic} = ConsentCache.check_consent(user_id, @origin)
    end

    test "{:approved, expires_at: ...}", %{user_id: user_id} do
      reply = fn _ctx -> {:approved, expires_at: {:ttl, 120}} end
      assert :ok = ensure(user_id, reply)

      sync_cache()
      assert {:ok, _expires_at} = ConsentCache.check_consent(user_id, @origin)
    end

    test "{:approved, []} falls back to the configured TTL", %{user_id: user_id} do
      assert :ok = ensure(user_id, fn _ctx -> {:approved, []} end)

      sync_cache()
      assert {:ok, expires_at} = ConsentCache.check_consent(user_id, @origin)
      ttl = expires_at - System.monotonic_time(:second)
      # Default context TTL is one hour.
      assert ttl > 3500 and ttl <= 3600
    end
  end

  describe "implausible or uninterpretable expiries fail closed" do
    test "Unix epoch seconds returned as a bare integer are rejected", %{user_id: user_id} do
      # The classic handler bug: this would previously be stored verbatim as a
      # monotonic value, granting consent for roughly 54 years.
      unix = System.os_time(:second) + 3600

      log =
        capture_log(fn ->
          assert {:error, :consent_error} = ensure(user_id, fn _ctx -> {:ok, unix} end)
        end)

      assert log =~ "Rejecting consent grant"
      assert log =~ "{:unix, seconds}"

      sync_cache()
      assert {:not_found} = ConsentCache.check_consent(user_id, @origin)
    end

    test "an expiry in the past is rejected", %{user_id: user_id} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      log =
        capture_log(fn ->
          assert {:error, :consent_error} = ensure(user_id, fn _ctx -> {:ok, past} end)
        end)

      assert log =~ "already in the past"

      sync_cache()
      assert {:not_found} = ConsentCache.check_consent(user_id, @origin)
    end

    test "an expiry beyond the maximum consent lifetime is rejected", %{user_id: user_id} do
      log =
        capture_log(fn ->
          assert {:error, :consent_error} =
                   ensure(user_id, fn _ctx -> {:ok, {:ttl, 400 * 24 * 3600}} end)
        end)

      assert log =~ "days away"

      sync_cache()
      assert {:not_found} = ConsentCache.check_consent(user_id, @origin)
    end

    test "an unsupported expiry shape is rejected", %{user_id: user_id} do
      log =
        capture_log(fn ->
          assert {:error, :consent_error} = ensure(user_id, fn _ctx -> {:ok, "tomorrow"} end)
        end)

      assert log =~ "unsupported expiry"

      sync_cache()
      assert {:not_found} = ConsentCache.check_consent(user_id, @origin)
    end

    test "a rejected grant is re-requested rather than cached", %{user_id: user_id} do
      unix = System.os_time(:second) + 3600
      reply = fn _ctx -> {:ok, unix} end

      capture_log(fn ->
        assert {:error, :consent_error} = ensure(user_id, reply)
        assert {:error, :consent_error} = ensure(user_id, reply)
      end)

      assert_received :consent_requested
      assert_received :consent_requested
    end
  end

  describe "handler context" do
    test "consent_ttl reaches the handler in seconds", %{user_id: user_id} do
      reply = fn ctx ->
        send(self(), {:ttl_seen, ctx.consent_ttl})
        {:ok, {:ttl, 60}}
      end

      config = %{
        trusted_origins: [],
        # The security setting is milliseconds.
        consent_ttl: :timer.hours(24),
        consent_handler_opts: [reply: reply]
      }

      assert :ok = Consent.ensure_user_consent(user_id, @url, :http, ScriptedHandler, config)
      assert_received {:ttl_seen, 86_400}
    end
  end

  describe "trusted origins" do
    test "a trusted origin never reaches the consent handler", %{user_id: user_id} do
      config = %{
        trusted_origins: [@origin],
        consent_handler_opts: [test_pid: self(), reply: fn _ctx -> {:error, :denied} end]
      }

      assert :ok = Consent.ensure_user_consent(user_id, @url, :http, ScriptedHandler, config)
      refute_received :consent_requested
    end
  end
end
