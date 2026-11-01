defmodule Arbor.MCP.Authorization.IdJagResourcePolicyTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.{IdJag, IdJagHandler, JWT}

  setup do
    key = JWT.generate_ec_key()

    create = [
      private_key: key,
      issuer: "https://idp.example",
      subject: "user",
      audience: "https://as.example",
      client_id: "client",
      alg: "ES256",
      resource_policy: :if_present
    ]

    validate = [
      idp_keys: JWT.to_public_key(key),
      expected_audience: "https://as.example",
      expected_resource: "https://mcp.example"
    ]

    {:ok, create: create, validate: validate, key: key}
  end

  @tag assurance: ["idjag.resource.default"]
  test "resource omission is rejected by default", %{create: create, validate: validate} do
    assert {:ok, token} = IdJag.create(create)
    assert {:error, _reason} = IdJag.validate(token, validate)
  end

  @tag assurance: ["idjag.resource.optional"]
  test "explicit if_present accepts an absent claim without creating a null claim", %{
    create: create,
    validate: validate
  } do
    assert {:ok, token} = IdJag.create(create)

    assert {:ok, claims} =
             IdJag.validate(token, Keyword.put(validate, :resource_policy, :if_present))

    refute Map.has_key?(claims, "resource")
    assert claims["aud"] == "https://as.example"
  end

  @tag assurance: ["idjag.resource.optional_wrong"]
  test "if_present still rejects a present claim for another resource", %{
    create: create,
    validate: validate
  } do
    assert {:ok, token} = IdJag.create(Keyword.put(create, :resource, "https://other.example"))

    assert {:error, {:invalid_resource, _details}} =
             IdJag.validate(token, Keyword.put(validate, :resource_policy, :if_present))
  end

  @tag assurance: ["idjag.resource.null"]
  test "if_present does not accept an explicitly null claim", %{
    create: create,
    validate: validate,
    key: key
  } do
    assert {:ok, valid} = IdJag.create(create)
    assert {:ok, claims} = JWT.verify(valid, JWT.to_public_key(key))

    assert {:ok, token} =
             JWT.sign(Map.put(claims, "resource", nil), key, alg: "ES256", typ: IdJag.typ())

    assert {:error, _reason} =
             IdJag.validate(token, Keyword.put(validate, :resource_policy, :if_present))
  end

  @tag assurance: ["idjag.resource.handler"]
  test "grant handler requires explicit resource policy and preserves absent resource", %{
    create: create,
    validate: validate,
    key: key
  } do
    assert {:ok, token} = IdJag.create(create)

    options =
      validate
      |> Keyword.delete(:idp_keys)
      |> Keyword.put(:assertion, token)
      |> Keyword.put(:trusted_idps, %{"https://idp.example" => %{jwks: [JWT.to_public_key(key)]}})

    assert {:error, _reason} = IdJagHandler.handle_grant(options)

    assert {:ok, result} =
             IdJagHandler.handle_grant(Keyword.put(options, :resource_policy, :if_present))

    assert result.resource == nil
    assert result.issuer == "https://idp.example"
    assert result.subject == "user"
    refute Map.has_key?(result.claims, "resource")
  end

  @tag assurance: ["idjag.resource.config"]
  test "optional resource still needs a trusted expected resource and known policy", %{
    create: create,
    validate: validate
  } do
    assert {:ok, token} = IdJag.create(create)

    assert {:error, :invalid_expected_resource} =
             IdJag.validate(
               token,
               validate
               |> Keyword.put(:expected_resource, nil)
               |> Keyword.put(:resource_policy, :if_present)
             )

    assert {:error, :invalid_resource_policy} =
             IdJag.validate(token, Keyword.put(validate, :resource_policy, :optional))

    assert {:error, :invalid_resource_policy} =
             IdJag.create(Keyword.put(create, :resource_policy, :optional))
  end
end
