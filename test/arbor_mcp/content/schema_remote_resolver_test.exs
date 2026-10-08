defmodule Arbor.MCP.Content.SchemaRemoteResolverTest do
  use ExUnit.Case, async: false

  alias Arbor.MCP.Content.{SchemaPolicy, SchemaRemoteResolver}

  @moduletag capture_log: true
  @public_ipv4 {93, 184, 216, 34}

  describe "opt-in resolution" do
    test "fetches allowlisted documents, resolves relative refs, and pins an approved IP" do
      routes = %{
        "https://schemas.example.com/a.json" =>
          response(
            ~s({"type":"object","properties":{"value":{"$ref":"b.json"}},"required":["value"]})
          ),
        "https://schemas.example.com/b.json" => response(~s({"type":"string"}))
      }

      {opts, agent} = resolver_options(routes)
      previous = Application.get_env(:ex_json_schema, :remote_schema_resolver)
      caller = self()

      Application.put_env(:ex_json_schema, :remote_schema_resolver, fn uri ->
        send(caller, {:global_resolver_called, uri})
        %{}
      end)

      on_exit(fn -> restore_env(:ex_json_schema, :remote_schema_resolver, previous) end)

      assert {:ok, resolved} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)

      assert :ok = SchemaPolicy.validate(%{"value" => "safe"}, resolved)
      assert {:error, _errors} = SchemaPolicy.validate(%{"value" => 123}, resolved)
      refute_receive {:global_resolver_called, _uri}

      assert [
               {"https://schemas.example.com/a.json", @public_ipv4},
               {"https://schemas.example.com/b.json", @public_ipv4}
             ] = fetch_calls(agent)
    end

    test "uses an absolute root id as the base for a relative reference" do
      routes = %{
        "https://schemas.example.com/child.json" => response(~s({"type":"integer"}))
      }

      {opts, _agent} = resolver_options(routes)

      schema = %{
        "$id" => "https://schemas.example.com/root.json",
        "$ref" => "child.json"
      }

      assert {:ok, resolved} = SchemaPolicy.compile(schema, opts)
      assert :ok = SchemaPolicy.validate(42, resolved)
      assert {:error, _errors} = SchemaPolicy.validate("42", resolved)
    end

    test "keeps the requested URI as an alias after an allowlisted redirect" do
      routes = %{
        "https://schemas.example.com/old.json" =>
          response("", 302, [{"location", "https://cdn.example.com/current.json"}]),
        "https://cdn.example.com/current.json" => response(~s({"type":"string"}))
      }

      {opts, _agent} =
        resolver_options(routes,
          allowed_hosts: ["schemas.example.com", "cdn.example.com"]
        )

      assert {:ok, resolved} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/old.json"}, opts)

      assert :ok = SchemaPolicy.validate("value", resolved)
      assert {:error, _errors} = SchemaPolicy.validate(10, resolved)
    end

    test "supports boolean root and remote schemas" do
      routes = %{
        "https://schemas.example.com/false.json" => response("false")
      }

      {opts, _agent} = resolver_options(routes)

      assert {:ok, true_root} = SchemaPolicy.compile(true, opts)
      assert :ok = SchemaPolicy.validate(%{"anything" => true}, true_root)

      assert {:ok, false_root} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://schemas.example.com/false.json"},
                 opts
               )

      assert {:error, _errors} = SchemaPolicy.validate("anything", false_root)
    end
  end

  describe "target and redirect validation" do
    test "revalidates DNS after every redirect and rejects mixed or private answers" do
      routes = %{
        "https://schemas.example.com/start.json" =>
          response("", 302, [{"location", "https://internal.example.com/schema.json"}]),
        "https://internal.example.com/schema.json" => response(~s({"type":"string"}))
      }

      dns = %{
        "schemas.example.com" => [@public_ipv4],
        "internal.example.com" => [@public_ipv4, {127, 0, 0, 1}]
      }

      {opts, agent} =
        resolver_options(routes,
          allowed_hosts: ["schemas.example.com", "internal.example.com"],
          dns: dns
        )

      assert {:error, {:network_schema_error, :non_public_address}} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://schemas.example.com/start.json"},
                 opts
               )

      assert [{"https://schemas.example.com/start.json", @public_ipv4}] = fetch_calls(agent)
    end

    test "rechecks the host allowlist before resolving a redirect target" do
      routes = %{
        "https://schemas.example.com/start.json" =>
          response("", 302, [{"location", "https://evil.example.net/schema.json"}])
      }

      {opts, agent} = resolver_options(routes)

      assert {:error, {:network_schema_error, :host_not_allowed}} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://schemas.example.com/start.json"},
                 opts
               )

      assert [{"https://schemas.example.com/start.json", @public_ipv4}] = fetch_calls(agent)
      assert ["schemas.example.com"] = dns_calls(agent)
    end

    test "rejects redirect cycles" do
      routes = %{
        "https://schemas.example.com/a.json" => response("", 302, [{"location", "b.json"}]),
        "https://schemas.example.com/b.json" => response("", 302, [{"location", "a.json"}])
      }

      {opts, _agent} = resolver_options(routes)

      assert {:error, {:network_schema_error, :redirect_cycle}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)
    end

    test "rejects HTTPS-to-HTTP redirect downgrades even when HTTP is enabled" do
      routes = %{
        "https://schemas.example.com/a.json" =>
          response("", 302, [{"location", "http://schemas.example.com/b.json"}]),
        "http://schemas.example.com/b.json" => response(~s({"type":"string"}))
      }

      {opts, agent} = resolver_options(routes, allow_http: true)

      assert {:error, {:network_schema_error, :redirect_downgrade}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)

      assert [{"https://schemas.example.com/a.json", @public_ipv4}] = fetch_calls(agent)
    end

    test "bounds redirects" do
      routes = %{
        "https://schemas.example.com/a.json" => response("", 302, [{"location", "b.json"}]),
        "https://schemas.example.com/b.json" => response("", 302, [{"location", "c.json"}]),
        "https://schemas.example.com/c.json" => response(~s({"type":"string"}))
      }

      {opts, agent} = resolver_options(routes, max_redirects: 1)

      assert {:error, {:network_schema_error, :redirect_limit}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)

      assert length(fetch_calls(agent)) == 2
    end

    test "rejects HTTP unless it is separately opted in" do
      routes = %{"http://schemas.example.com/a.json" => response(~s({"type":"string"}))}
      {opts, _agent} = resolver_options(routes)

      assert {:error, {:network_schema_error, :scheme_not_allowed}} =
               SchemaPolicy.compile(%{"$ref" => "http://schemas.example.com/a.json"}, opts)

      {http_opts, _agent} = resolver_options(routes, allow_http: true)

      assert {:ok, _resolved} =
               SchemaPolicy.compile(
                 %{"$ref" => "http://schemas.example.com/a.json"},
                 http_opts
               )
    end

    test "rejects URI userinfo and non-allowlisted wildcard roots" do
      {opts, _agent} = resolver_options(%{}, allowed_hosts: ["*.example.com"])

      assert {:error, {:network_schema_error, :userinfo_forbidden}} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://user:secret@api.example.com/schema.json"},
                 opts
               )

      assert {:error, {:network_schema_error, :host_not_allowed}} =
               SchemaPolicy.compile(%{"$ref" => "https://example.com/schema.json"}, opts)
    end
  end

  describe "fetch and graph limits" do
    test "rejects compressed responses" do
      routes = %{
        "https://schemas.example.com/a.json" =>
          response(~s({"type":"string"}), 200, [{"content-encoding", "gzip"}])
      }

      {opts, _agent} = resolver_options(routes)

      assert {:error, {:network_schema_error, :compressed_response}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)
    end

    test "bounds each response" do
      routes = %{
        "https://schemas.example.com/a.json" => response(~s({"type":"string"}))
      }

      {opts, _agent} = resolver_options(routes, max_response_bytes: 5)

      assert {:error, {:network_schema_error, :response_too_large}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)
    end

    test "bounds aggregate response bytes" do
      root_body = ~s({"allOf":[{"$ref":"b.json"},{"$ref":"c.json"}]})
      child_body = ~s({"type":"string"})

      routes = %{
        "https://schemas.example.com/a.json" => response(root_body),
        "https://schemas.example.com/b.json" => response(child_body),
        "https://schemas.example.com/c.json" => response(child_body)
      }

      aggregate_limit = byte_size(root_body) + byte_size(child_body)
      {opts, _agent} = resolver_options(routes, max_aggregate_bytes: aggregate_limit)

      assert {:error, {:network_schema_error, :aggregate_response_too_large}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)
    end

    test "bounds fetched document count and reference depth" do
      routes = %{
        "https://schemas.example.com/a.json" => response(~s({"$ref":"b.json"})),
        "https://schemas.example.com/b.json" => response(~s({"type":"string"}))
      }

      {document_opts, _agent} = resolver_options(routes, max_documents: 1)

      assert {:error, {:network_schema_error, :document_limit}} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://schemas.example.com/a.json"},
                 document_opts
               )

      {depth_opts, _agent} = resolver_options(routes, max_reference_depth: 0)

      assert {:error, {:network_schema_error, :reference_depth}} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://schemas.example.com/a.json"},
                 depth_opts
               )
    end

    test "rejects cross-document reference cycles" do
      routes = %{
        "https://schemas.example.com/a.json" => response(~s({"$ref":"b.json"})),
        "https://schemas.example.com/b.json" => response(~s({"$ref":"a.json"}))
      }

      {opts, _agent} = resolver_options(routes)

      assert {:error, {:network_schema_error, :reference_cycle}} =
               SchemaPolicy.compile(%{"$ref" => "https://schemas.example.com/a.json"}, opts)
    end

    test "rejects invalid remote JSON and schema complexity" do
      routes = %{
        "https://schemas.example.com/invalid.json" => response("not-json"),
        "https://schemas.example.com/deep.json" =>
          response(~s({"properties":{"a":{"properties":{"b":{}}}}}))
      }

      {opts, _agent} = resolver_options(routes)

      assert {:error, {:network_schema_error, :invalid_json_schema}} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://schemas.example.com/invalid.json"},
                 opts
               )

      {depth_opts, _agent} = resolver_options(routes, policy: [max_schema_depth: 2])

      assert {:error, {:schema_limit_exceeded, :max_schema_depth, _observed}} =
               SchemaPolicy.compile(
                 %{"$ref" => "https://schemas.example.com/deep.json"},
                 depth_opts
               )
    end
  end

  describe "configuration and address policy" do
    test "fails closed for malformed or incomplete network configuration" do
      assert {:error, {:invalid_schema_policy_option, :network_refs}} =
               SchemaPolicy.preflight(%{}, network_refs: :invalid)

      assert {:error, {:invalid_schema_policy_option, :allowed_hosts}} =
               SchemaPolicy.preflight(%{}, network_refs: [enabled: true])

      assert {:error, {:invalid_schema_policy_option, :proxy}} =
               SchemaPolicy.preflight(%{},
                 network_refs: [
                   enabled: true,
                   allowed_hosts: ["schemas.example.com"],
                   proxy: {:https, "proxy.example.com", 443}
                 ]
               )
    end

    test "classifies public and non-public IPv4 addresses" do
      assert SchemaRemoteResolver.public_address?({8, 8, 8, 8})
      assert SchemaRemoteResolver.public_address?(@public_ipv4)

      refute SchemaRemoteResolver.public_address?({0, 0, 0, 0})
      refute SchemaRemoteResolver.public_address?({10, 0, 0, 1})
      refute SchemaRemoteResolver.public_address?({100, 64, 0, 1})
      refute SchemaRemoteResolver.public_address?({127, 0, 0, 1})
      refute SchemaRemoteResolver.public_address?({169, 254, 1, 1})
      refute SchemaRemoteResolver.public_address?({172, 16, 0, 1})
      refute SchemaRemoteResolver.public_address?({192, 168, 0, 1})
      refute SchemaRemoteResolver.public_address?({198, 51, 100, 1})
      refute SchemaRemoteResolver.public_address?({224, 0, 0, 1})
    end

    test "classifies public and non-public IPv6 addresses" do
      assert SchemaRemoteResolver.public_address?({0x2607, 0xF8B0, 0, 0, 0, 0, 0, 0x200E})

      refute SchemaRemoteResolver.public_address?({0, 0, 0, 0, 0, 0, 0, 1})
      refute SchemaRemoteResolver.public_address?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      refute SchemaRemoteResolver.public_address?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      refute SchemaRemoteResolver.public_address?({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      refute SchemaRemoteResolver.public_address?({0, 0, 0, 0, 0, 65_535, 0x7F00, 1})
    end
  end

  defp resolver_options(routes, overrides \\ []) do
    dns = Keyword.get(overrides, :dns, %{})
    policy_overrides = Keyword.get(overrides, :policy, [])
    network_overrides = Keyword.drop(overrides, [:dns, :policy])

    # Supervised by ExUnit so teardown is deterministic. A linked agent plus an
    # on_exit stop raced: the agent could die with the test process between the
    # alive check and Agent.stop/1, failing the test in teardown (seen in CI).
    agent =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{routes: routes, dns: dns, fetches: [], lookups: []} end},
          id: {:resolver_agent, make_ref()}
        )
      )

    dns_resolver = fn host, _timeout ->
      Agent.get_and_update(agent, fn state ->
        addresses = Map.get(state.dns, host, [@public_ipv4])
        {{:ok, addresses}, %{state | lookups: [host | state.lookups]}}
      end)
    end

    http_client = fn uri, address, _network_opts ->
      Agent.get_and_update(agent, fn state ->
        key = to_string(uri)
        result = Map.fetch(state.routes, key)

        reply =
          case result do
            {:ok, response} -> {:ok, response}
            :error -> {:error, :fetch_failed}
          end

        {reply, %{state | fetches: [{key, address} | state.fetches]}}
      end)
    end

    network_opts =
      [
        enabled: true,
        allowed_hosts: ["schemas.example.com"],
        dns_resolver: dns_resolver,
        http_client: http_client,
        trust_partition: "test-tenant"
      ]
      |> Keyword.merge(network_overrides)

    opts =
      [resolve_timeout_ms: 5_000, network_refs: network_opts]
      |> Keyword.merge(policy_overrides)

    {opts, agent}
  end

  defp response(body, status \\ 200, headers \\ []) do
    %{status: status, headers: headers, body: body}
  end

  defp fetch_calls(agent), do: Agent.get(agent, &Enum.reverse(&1.fetches))
  defp dns_calls(agent), do: Agent.get(agent, &Enum.reverse(&1.lookups))

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
