defmodule Arbor.MCP.Transport.HTTP.TargetPolicyTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Transport.HTTP.TargetPolicy

  test "pins a public address only after validating the complete DNS answer" do
    resolver = fn "mcp.example", 500 -> {:ok, [{8, 8, 4, 4}, {8, 8, 8, 8}]} end

    assert {:ok, %URI{host: "mcp.example"}, {8, 8, 4, 4}} =
             TargetPolicy.resolve("https://mcp.example/rpc",
               dns_timeout_ms: 500,
               dns_resolver: resolver
             )
  end

  test "rejects a mixed public and private DNS answer" do
    resolver = fn _host, _timeout -> {:ok, [{8, 8, 8, 8}, {10, 0, 0, 7}]} end

    assert {:error, :non_public_address} =
             TargetPolicy.resolve("https://mcp.example/rpc", dns_resolver: resolver)
  end

  test "requires localhost names to resolve exclusively to loopback" do
    resolver = fn _host, _timeout -> {:ok, [{127, 0, 0, 1}, {8, 8, 8, 8}]} end

    assert {:error, :non_loopback_address} =
             TargetPolicy.resolve("http://localhost:4000/mcp", dns_resolver: resolver)
  end

  test "private destinations require an exact hostname allowlist entry" do
    resolver = fn _host, _timeout -> {:ok, [{10, 0, 0, 7}]} end

    assert {:error, :non_public_address} =
             TargetPolicy.resolve("https://internal.example/mcp", dns_resolver: resolver)

    assert {:ok, %URI{}, {10, 0, 0, 7}} =
             TargetPolicy.resolve("https://internal.example/mcp",
               dns_resolver: resolver,
               allowed_private_hosts: ["internal.example"]
             )
  end

  test "an allowlisted hostname still cannot resolve to link-local metadata services" do
    resolver = fn _host, _timeout -> {:ok, [{169, 254, 169, 254}]} end

    assert {:error, :non_public_address} =
             TargetPolicy.resolve("https://internal.example/mcp",
               dns_resolver: resolver,
               allowed_private_hosts: ["internal.example"]
             )
  end

  test "rejects wildcard and URL-shaped private-host exceptions" do
    assert {:error, :invalid_network_policy} =
             TargetPolicy.validate_options(allowed_private_hosts: ["*.example.com"])

    assert {:error, :invalid_network_policy} =
             TargetPolicy.validate_options(allowed_private_hosts: ["https://example.com"])
  end
end
