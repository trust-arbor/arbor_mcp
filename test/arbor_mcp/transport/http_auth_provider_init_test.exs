defmodule Arbor.MCP.Transport.HTTPAuthProviderInitTest do
  @moduledoc """
  An HTTP auth provider whose `init/1` fails must fail the connection. The
  transport used to drop it and go on, so every request went out without the
  credentials the application configured.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Arbor.MCP.Client
  alias Arbor.MCP.Transport.HTTP

  @secret "sk-live-provider-secret"

  defmodule Provider do
    @moduledoc false
    @behaviour Arbor.MCP.Authorization.Provider

    # The config carries a secret; `:init` says how init/1 goes.
    @impl true
    def init(config) do
      case Keyword.fetch!(config, :init) do
        :ok -> {:ok, %{token: Keyword.fetch!(config, :api_key)}}
        {:error, reason} -> {:error, reason}
        :raise -> raise ArgumentError, "bad api key " <> Keyword.fetch!(config, :api_key)
        :exit -> exit({:bad_key, Keyword.fetch!(config, :api_key)})
        :invalid -> {:started, Keyword.fetch!(config, :api_key)}
      end
    end

    @impl true
    def get_token(state), do: {:ok, state.token, state}

    @impl true
    def handle_unauthorized(_www_auth, _scopes, state), do: {:error, :unauthorized, state}

    @impl true
    def handle_forbidden(_www_auth, _scopes, state), do: {:error, :forbidden, state}
  end

  describe "connect/1 with a provider whose init/1 fails" do
    test "returns the provider and its atom reason" do
      log =
        capture_log(fn ->
          assert {:error, {:auth_provider_init_failed, Provider, :no_credentials}} =
                   connect(init: {:error, :no_credentials})
        end)

      assert log =~ "failed to initialize"
      assert log =~ inspect(Provider)
      refute log =~ @secret
    end

    test "leaves out any other reason, which may carry the provider's config" do
      for {init, expected} <- [
            {{:error, {:bad_key, @secret}}, :redacted},
            {:raise, {:raised, ArgumentError}},
            {:exit, :exit},
            {:invalid, :invalid_init_result}
          ] do
        log =
          capture_log(fn ->
            assert {:error, {:auth_provider_init_failed, Provider, ^expected}} =
                     connect(init: init)
          end)

        assert log =~ "failed to initialize"
        refute log =~ @secret
      end
    end
  end

  test "Client.start_link/1 fails before any request goes out" do
    Process.flag(:trap_exit, true)
    # Bypass fails the test if any request reaches it.
    bypass = Bypass.open()

    log =
      capture_log(fn ->
        assert {:error,
                {:transport_connect_failed,
                 {:auth_provider_init_failed, Provider, :no_credentials}}} =
                 Client.start_link(
                   transport: :http,
                   url: "http://127.0.0.1:#{bypass.port}/mcp",
                   use_sse: false,
                   protocol_mode: :legacy_only,
                   health_check_interval: nil,
                   reconnect: false,
                   auth_provider: {Provider, init: {:error, :no_credentials}, api_key: @secret}
                 )
      end)

    refute log =~ @secret
  end

  test "a provider that starts, or none, still connects" do
    assert {:ok, %HTTP{auth_provider: Provider, auth_provider_state: %{token: @secret}}} =
             connect(init: :ok)

    assert {:ok, %HTTP{auth_provider: nil, auth_provider_state: nil}} =
             HTTP.connect(url: "http://127.0.0.1:1/mcp", use_sse: false)
  end

  defp connect(provider_config) do
    HTTP.connect(
      url: "http://127.0.0.1:1/mcp",
      use_sse: false,
      auth_provider: {Provider, Keyword.put(provider_config, :api_key, @secret)}
    )
  end
end
