defmodule Arbor.MCP.Authorization.ProtectedResourceMetadataTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.ProtectedResourceMetadata

  @public_address {93, 184, 216, 34}

  test "discovers string and structured authorization-server entries through the safe fetcher" do
    body =
      Jason.encode!(%{
        "resource" => "https://mcp.example/api",
        "authorization_servers" => [
          "https://auth.example",
          %{
            "issuer" => "https://other.example",
            "metadata_endpoint" => "https://other.example/metadata",
            "scopes_supported" => ["tools:read"]
          }
        ]
      })

    parent = self()

    client = fn uri, address, opts ->
      send(parent, {:request, uri, address, opts[:request_headers]})
      {:ok, %{status: 200, headers: [], body: body}}
    end

    assert {:ok, %{authorization_servers: [first, second]}} =
             ProtectedResourceMetadata.discover("https://mcp.example/api",
               dns_resolver: public_dns(),
               http_client: client
             )

    assert first == %{
             issuer: "https://auth.example",
             metadata_endpoint: nil,
             scopes_supported: nil,
             audience: nil
           }

    assert second.issuer == "https://other.example"
    assert second.metadata_endpoint == "https://other.example/metadata"
    assert second.scopes_supported == ["tools:read"]

    assert_received {:request, uri, @public_address, headers}
    assert uri.path == "/.well-known/oauth-protected-resource/api"
    refute Enum.any?(headers, fn {name, _value} -> name in ["authorization", "cookie"] end)
  end

  test "falls back from path-based to root protected-resource metadata" do
    parent = self()

    client = fn uri, _address, _opts ->
      send(parent, {:request_path, uri.path})

      case uri.path do
        "/.well-known/oauth-protected-resource/api" ->
          {:ok, %{status: 404, headers: [], body: ""}}

        "/.well-known/oauth-protected-resource" ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body:
               Jason.encode!(%{
                 "resource" => "https://mcp.example",
                 "authorization_servers" => ["https://auth.example"]
               })
           }}
      end
    end

    assert {:ok, %{authorization_servers: [%{issuer: "https://auth.example"}]}} =
             ProtectedResourceMetadata.discover("https://mcp.example/api",
               dns_resolver: public_dns(),
               http_client: client
             )

    assert_received {:request_path, "/.well-known/oauth-protected-resource/api"}
    assert_received {:request_path, "/.well-known/oauth-protected-resource"}
  end

  test "rejects HTTP resources and private DNS before requesting" do
    assert {:error, :https_required} =
             ProtectedResourceMetadata.discover("http://mcp.example/api")

    dns = fn _host, _timeout -> {:ok, [{127, 0, 0, 1}]} end
    client = fn _uri, _address, _opts -> flunk("request must not be made") end

    assert {:error, {:metadata_fetch_error, :non_public_address}} =
             ProtectedResourceMetadata.discover("https://mcp.example/api",
               dns_resolver: dns,
               http_client: client
             )
  end

  test "returns an error instead of raising for malformed authorization-server entries" do
    client = fn _uri, _address, _opts ->
      {:ok,
       %{
         status: 200,
         headers: [],
         body:
           Jason.encode!(%{
             "resource" => "https://mcp.example/api",
             "authorization_servers" => [%{"not_issuer" => true}]
           })
       }}
    end

    assert {:error, {:invalid_metadata, "Invalid authorization server"}} =
             ProtectedResourceMetadata.discover("https://mcp.example/api",
               dns_resolver: public_dns(),
               http_client: client
             )
  end

  describe "RFC 9728 section 3.3 resource validation" do
    test "returns the resource and top-level scopes_supported" do
      client =
        prm_client(%{
          "/.well-known/oauth-protected-resource/api" =>
            prm(%{
              "resource" => "https://mcp.example/api",
              "authorization_servers" => ["https://auth.example"],
              "scopes_supported" => ["tools:read", "tools:write"]
            })
        })

      assert {:ok, metadata} = discover("https://mcp.example/api", client)
      assert metadata.resource == "https://mcp.example/api"
      assert metadata.scopes_supported == ["tools:read", "tools:write"]
      assert [%{issuer: "https://auth.example"}] = metadata.authorization_servers
    end

    test "never returns a document that names another resource" do
      client =
        prm_client(%{
          "/.well-known/oauth-protected-resource/api" =>
            prm(%{
              "resource" => "https://victim.example/api",
              "authorization_servers" => ["https://attacker-as.example"]
            }),
          "/.well-known/oauth-protected-resource" => {:ok, %{status: 404, headers: [], body: ""}}
        })

      assert {:error,
              {:resource_mismatch,
               expected: "https://mcp.example/api", actual: "https://victim.example/api"}} =
               discover("https://mcp.example/api", client)
    end

    test "skips a mismatched path document and uses a root document naming the origin" do
      client =
        prm_client(%{
          "/.well-known/oauth-protected-resource/api" =>
            prm(%{
              "resource" => "https://mcp.example/other",
              "authorization_servers" => ["https://attacker-as.example"]
            }),
          "/.well-known/oauth-protected-resource" =>
            prm(%{
              "resource" => "https://mcp.example",
              "authorization_servers" => ["https://auth.example"]
            })
        })

      assert {:ok, %{resource: "https://mcp.example", authorization_servers: [server]}} =
               discover("https://mcp.example/api", client)

      assert server.issuer == "https://auth.example"
    end

    test "accepts a root document naming the full endpoint URL" do
      client =
        prm_client(%{
          "/.well-known/oauth-protected-resource/api" =>
            {:ok, %{status: 404, headers: [], body: ""}},
          "/.well-known/oauth-protected-resource" =>
            prm(%{
              "resource" => "https://mcp.example/api",
              "authorization_servers" => ["https://auth.example"]
            })
        })

      assert {:ok, %{resource: "https://mcp.example/api"}} =
               discover("https://mcp.example/api", client)
    end

    test "a path-specific document may not claim the whole origin" do
      client =
        prm_client(%{
          "/.well-known/oauth-protected-resource/api" =>
            prm(%{
              "resource" => "https://mcp.example",
              "authorization_servers" => ["https://auth.example"]
            }),
          "/.well-known/oauth-protected-resource" => {:ok, %{status: 404, headers: [], body: ""}}
        })

      assert {:error, {:resource_mismatch, expected: "https://mcp.example/api", actual: _}} =
               discover("https://mcp.example/api", client)
    end

    test "compares scheme and host case-insensitively, the default port, and a trailing slash" do
      client =
        prm_client(%{
          "/.well-known/oauth-protected-resource/api" =>
            prm(%{
              "resource" => "HTTPS://MCP.example:443/api/",
              "authorization_servers" => ["https://auth.example"]
            })
        })

      assert {:ok, %{resource: "HTTPS://MCP.example:443/api/"}} =
               discover("https://mcp.example/api", client)
    end

    test "a different port, path or query is a different resource" do
      for resource <- [
            "https://mcp.example:8443/api",
            "https://mcp.example/api/v2",
            "https://mcp.example/api?tenant=other",
            "https://mcp.example/api#fragment",
            "http://mcp.example/api"
          ] do
        client =
          prm_client(%{
            "/.well-known/oauth-protected-resource/api" =>
              prm(%{"resource" => resource, "authorization_servers" => ["https://a.example"]}),
            "/.well-known/oauth-protected-resource" =>
              {:ok, %{status: 404, headers: [], body: ""}}
          })

        assert {:error, {:resource_mismatch, _}} = discover("https://mcp.example/api", client),
               "expected #{resource} to be rejected"
      end
    end

    test "a document without resource is skipped" do
      client =
        prm_client(%{
          "/.well-known/oauth-protected-resource/api" =>
            prm(%{"authorization_servers" => ["https://attacker-as.example"]}),
          "/.well-known/oauth-protected-resource" => {:ok, %{status: 404, headers: [], body: ""}}
        })

      assert {:error, {:invalid_metadata, "Missing resource"}} =
               discover("https://mcp.example/api", client)
    end

    test "rejects scopes_supported that is not a list of scope strings" do
      for scopes <- ["tools:read", [1], [""], %{}] do
        client =
          prm_client(%{
            "/.well-known/oauth-protected-resource/api" =>
              prm(%{
                "resource" => "https://mcp.example/api",
                "authorization_servers" => ["https://auth.example"],
                "scopes_supported" => scopes
              })
          })

        assert {:error, {:invalid_metadata, "Invalid scopes_supported"}} =
                 discover("https://mcp.example/api", client)
      end
    end
  end

  defp prm(document), do: {:ok, %{status: 200, headers: [], body: Jason.encode!(document)}}

  defp prm_client(responses_by_path) do
    fn uri, _address, _opts ->
      Map.get(responses_by_path, uri.path) || flunk("unexpected request for #{uri.path}")
    end
  end

  defp discover(resource_url, client) do
    ProtectedResourceMetadata.discover(resource_url,
      dns_resolver: public_dns(),
      http_client: client
    )
  end

  defp public_dns do
    fn _host, _timeout -> {:ok, [@public_address]} end
  end
end
