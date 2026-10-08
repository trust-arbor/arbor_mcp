defmodule Arbor.MCP.Authorization.OAuthTransactionStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{OAuthFlow, OAuthTransactionStore}

  setup do
    store =
      start_supervised!({OAuthTransactionStore, name: nil, ttl_ms: 60_000, max_entries: 100})

    %{store: store}
  end

  test "a matching state is single-use under concurrent callbacks", %{store: store} do
    {:ok, transaction_id} = register(store)
    callback = callback()

    results =
      1..16
      |> Task.async_stream(
        fn _attempt ->
          OAuthTransactionStore.validate_callback(transaction_id, callback, server: store)
        end,
        ordered: false,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, "code-1"}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, :authorization_transaction_replayed}, &1)
           ) == 15
  end

  test "the public OAuth flow admits exactly one concurrent callback" do
    assert {:ok, _auth_url, transaction} = OAuthFlow.start_authorization_flow(flow_params())

    callback = %{
      "state" => transaction.state_param,
      "code" => "public-code",
      "iss" => transaction.issuer
    }

    results =
      1..16
      |> Task.async_stream(
        fn _attempt -> OAuthFlow.validate_authorization_response(callback, transaction) end,
        ordered: false,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == {:ok, "public-code"})) == 1

    assert Enum.count(
             results,
             &(&1 == {:error, :authorization_transaction_replayed})
           ) == 15
  end

  test "an invalid state does not consume the real callback", %{store: store} do
    {:ok, transaction_id} = register(store)

    assert {:error, :state_mismatch} =
             OAuthTransactionStore.validate_callback(
               transaction_id,
               %{callback() | "state" => "attacker-state"},
               server: store
             )

    assert {:ok, "code-1"} =
             OAuthTransactionStore.validate_callback(transaction_id, callback(), server: store)
  end

  test "the store retains digests instead of raw state or code", %{store: store} do
    {:ok, transaction_id} = register(store)

    refute inspect(:sys.get_state(store)) =~ "state-1"

    assert {:ok, "code-1"} =
             OAuthTransactionStore.validate_callback(transaction_id, callback(), server: store)

    retained_state = inspect(:sys.get_state(store))
    refute retained_state =~ "state-1"
    refute retained_state =~ "code-1"
  end

  test "callbacks accept the fixed atom-key representation", %{store: store} do
    {:ok, transaction_id} = register(store)

    assert {:ok, "code-1"} =
             OAuthTransactionStore.validate_callback(
               transaction_id,
               %{state: "state-1", code: "code-1", iss: "https://auth.example"},
               server: store
             )
  end

  test "a callback that knows state but fails issuer validation consumes the transaction", %{
    store: store
  } do
    {:ok, transaction_id} = register(store)

    assert {:error,
            {:issuer_mismatch, expected: "https://auth.example", actual: "https://other.example"}} =
             OAuthTransactionStore.validate_callback(
               transaction_id,
               %{callback() | "iss" => "https://other.example"},
               server: store
             )

    assert {:error, :authorization_transaction_replayed} =
             OAuthTransactionStore.validate_callback(transaction_id, callback(), server: store)
  end

  test "a callback missing an advertised required issuer consumes the transaction", %{
    store: store
  } do
    {:ok, transaction_id} =
      OAuthTransactionStore.register(
        "state-1",
        "https://auth.example",
        "http://127.0.0.1:8080/callback",
        server: store,
        require_issuer: true
      )

    assert {:error, :missing_callback_issuer} =
             OAuthTransactionStore.validate_callback(
               transaction_id,
               Map.delete(callback(), "iss"),
               server: store
             )

    assert {:error, :authorization_transaction_replayed} =
             OAuthTransactionStore.validate_callback(transaction_id, callback(), server: store)
  end

  test "authorization-code redemption is atomic and single-use", %{store: store} do
    {:ok, transaction_id} = register(store)

    assert {:ok, "code-1"} =
             OAuthTransactionStore.validate_callback(transaction_id, callback(), server: store)

    results =
      1..12
      |> Task.async_stream(
        fn _attempt ->
          OAuthTransactionStore.redeem_code(
            transaction_id,
            "code-1",
            "http://127.0.0.1:8080/callback",
            server: store
          )
        end,
        ordered: false,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :authorization_code_replayed})) == 11
  end

  test "redemption requires the callback transaction's exact code and redirect URI", %{
    store: store
  } do
    {:ok, transaction_id} = register(store)

    assert {:ok, "code-1"} =
             OAuthTransactionStore.validate_callback(transaction_id, callback(), server: store)

    assert {:error, :authorization_code_mismatch} =
             OAuthTransactionStore.redeem_code(
               transaction_id,
               "code-2",
               "http://127.0.0.1:8080/callback",
               server: store
             )

    assert {:error, :redirect_uri_mismatch} =
             OAuthTransactionStore.redeem_code(
               transaction_id,
               "code-1",
               "http://127.0.0.1:8080/callback/",
               server: store
             )

    assert :ok =
             OAuthTransactionStore.redeem_code(
               transaction_id,
               "code-1",
               "http://127.0.0.1:8080/callback",
               server: store
             )
  end

  test "authorization flows generate unique high-entropy state and reject reserved overrides" do
    states =
      for _attempt <- 1..32 do
        assert {:ok, auth_url, transaction} = OAuthFlow.start_authorization_flow(flow_params())
        query = auth_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

        assert query["state"] == transaction.state_param
        assert byte_size(transaction.state_param) == 43
        assert is_binary(transaction.transaction_id)
        assert :ok = OAuthTransactionStore.abort(transaction.transaction_id)

        transaction.state_param
      end

    assert length(Enum.uniq(states)) == 32

    assert {:error, :custom_oauth_state_not_allowed} =
             flow_params()
             |> Map.put(:state, "caller-controlled")
             |> OAuthFlow.start_authorization_flow()

    for key <- [:state, "redirect_uri", :code_challenge, "scope", :resource] do
      assert {:error, {:reserved_authorization_parameter, _name}} =
               flow_params()
               |> Map.put(:additional_params, %{key => "override"})
               |> OAuthFlow.start_authorization_flow()
    end
  end

  test "OAuthFlow exchanges a validated code only once" do
    bypass = Bypass.open()
    token_endpoint = "http://localhost:#{bypass.port}/token"

    assert {:ok, _auth_url, transaction} = OAuthFlow.start_authorization_flow(flow_params())

    assert {:ok, "code-1"} =
             OAuthFlow.validate_authorization_response(
               %{
                 "state" => transaction.state_param,
                 "code" => "code-1",
                 "iss" => "https://auth.example"
               },
               transaction
             )

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"access_token" => "access-1", "token_type" => "Bearer"})
      )
    end)

    params = %{
      transaction_id: transaction.transaction_id,
      code: "code-1",
      code_verifier: transaction.code_verifier,
      client_id: "client-1",
      redirect_uri: transaction.redirect_uri,
      token_endpoint: token_endpoint
    }

    assert {:ok, %{access_token: "access-1"}} = OAuthFlow.exchange_code_for_token(params)

    assert {:error, :authorization_code_replayed} =
             OAuthFlow.exchange_code_for_token(params)
  end

  defp register(store) do
    OAuthTransactionStore.register(
      "state-1",
      "https://auth.example",
      "http://127.0.0.1:8080/callback",
      server: store
    )
  end

  defp callback do
    %{
      "state" => "state-1",
      "code" => "code-1",
      "iss" => "https://auth.example"
    }
  end

  defp flow_params do
    %{
      client_id: "client-1",
      redirect_uri: "http://127.0.0.1:8080/callback",
      authorization_endpoint: "https://auth.example/authorize",
      issuer: "https://auth.example",
      scopes: ["tools:read"]
    }
  end
end
