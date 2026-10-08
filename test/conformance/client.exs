# Arbor.MCP Conformance Test Client
#
# Minimal wrapper around Arbor.MCP.Client for the MCP conformance framework.
# All protocol logic lives in the library — this script just connects,
# exercises the API, and disconnects.
#
# Spawned by the conformance framework:
#   npx @modelcontextprotocol/conformance client \
#     --command "elixir test/conformance/client.exs" \
#     --scenario initialize
#
# The server URL is passed as the last argument.
# MCP_CONFORMANCE_SCENARIO env var indicates which scenario to run.
# MCP_CONFORMANCE_CONTEXT env var has scenario-specific data (JSON).

unless Code.ensure_loaded?(Arbor.MCP) do
  Mix.install([{:arbor_mcp, path: "."}, {:jason, "~> 1.4"}])
end

{:ok, _started} = Application.ensure_all_started(:arbor_mcp)

defmodule ConformanceClient do
  require Logger

  alias Arbor.MCP.Conformance.ClientScenarios

  def run do
    server_url = List.last(System.argv()) || raise "No server URL provided"
    scenario = System.get_env("MCP_CONFORMANCE_SCENARIO", "")

    context =
      case System.get_env("MCP_CONFORMANCE_CONTEXT") do
        nil -> %{}
        "" -> %{}
        json -> Jason.decode!(json)
      end

    Logger.info("Conformance client: scenario=#{scenario} url=#{server_url}")

    # Enable elicitation auto-accept for conformance testing
    Application.put_env(:arbor_mcp, :elicitation_auto_accept, true)

    # All scenarios follow the same pattern: connect, exercise the API, disconnect.
    # The conformance framework validates protocol behavior by observing the wire traffic.
    # Auth scenarios pass credentials via context; the transport handles 401→OAuth automatically.
    run_scenario(server_url, scenario, context)
  end

  defp run_scenario(server_url, scenario, context) do
    opts = build_connect_opts(server_url, scenario, context)

    case Arbor.MCP.Client.start_link([url: server_url] ++ opts) do
      {:ok, client} ->
        exercise_api(client, scenario, context)
        Arbor.MCP.Client.disconnect(client)

      {:error, reason} ->
        Logger.error("Connect failed: #{inspect(reason)}")
    end
  end

  # Build connection options. Auth config comes from conformance context;
  # everything else is standard.
  defp build_connect_opts(server_url, scenario, context) do
    # Per MCP Streamable HTTP spec: always POST, parse SSE responses from POST.
    # SSE GET stream opened automatically when server provides a session ID.
    # use_sse: true enables this — the transport falls back gracefully when
    # no session ID is provided (stateless servers).
    protocol_version =
      System.get_env("MCP_CONFORMANCE_PROTOCOL_VERSION", Arbor.MCP.protocol_version())

    base = [
      transport: :http,
      use_sse: true,
      protocol_mode: protocol_mode(protocol_version),
      protocol_version: protocol_version,
      client_info: %{"name" => "ex_mcp-conformance-client", "version" => "0.9.0"},
      capabilities: %{"sampling" => %{}, "elicitation" => %{}}
    ]

    case build_auth_for_scenario(server_url, scenario, context) do
      nil -> base
      auth -> Keyword.put(base, :auth, auth)
    end
  end

  defp build_auth_for_scenario(server_url, "auth/" <> _rest = scenario, context) do
    base = %{
      application_type: :native,
      redirect_port: available_redirect_port(),
      metadata_fetch: [allow_insecure_loopback: true]
    }

    base
    |> Map.merge(build_auth_from_context(context) || %{})
    |> add_conformance_registration_config(server_url, scenario)
  end

  defp build_auth_for_scenario(_server_url, _scenario, _context), do: nil

  # The upstream harness currently hard-codes its CIMD identifier instead of
  # passing it in MCP_CONFORMANCE_CONTEXT. Keep that harness detail out of the
  # production registration policy.
  defp add_conformance_registration_config(auth, _server_url, "auth/basic-cimd") do
    Map.put(auth, :client_metadata_url, "https://conformance-test.local/client-metadata.json")
  end

  # Pre-registered credentials are issuer-bound in Arbor.MCP. The harness supplies
  # the credentials but omits their issuer, so discover that missing fixture
  # value before connecting. FullOAuthFlow repeats and validates discovery.
  defp add_conformance_registration_config(auth, server_url, "auth/pre-registration") do
    case Arbor.MCP.Authorization.ProtectedResourceMetadata.discover(
           server_url,
           allow_insecure_loopback: true
         ) do
      {:ok, %{authorization_servers: [%{issuer: issuer} | _]}} ->
        Map.put(auth, :credential_issuer, issuer)

      {:error, reason} ->
        raise "could not discover conformance credential issuer: #{inspect(reason)}"
    end
  end

  defp add_conformance_registration_config(auth, _server_url, _scenario), do: auth

  defp build_auth_from_context(%{"client_id" => client_id} = ctx) do
    config = %{client_id: client_id}

    config =
      case ctx["client_secret"] do
        nil -> config
        secret -> Map.merge(config, %{client_secret: secret, auth_method: :client_secret})
      end

    # Pass private key for JWT-based auth (ext-auth client-credentials-jwt)
    config =
      case ctx["private_key_pem"] do
        nil ->
          config

        pem ->
          Map.merge(config, %{
            private_key: pem,
            signing_algorithm: ctx["signing_algorithm"] || "RS256"
          })
      end

    # Pass IdP info for cross-app access flow (ext-auth)
    config =
      case ctx["idp_id_token"] do
        nil ->
          config

        id_token ->
          Map.merge(config, %{
            idp_id_token: id_token,
            idp_issuer: ctx["idp_issuer"],
            idp_token_endpoint: ctx["idp_token_endpoint"],
            idp_client_id: ctx["idp_client_id"]
          })
      end

    config
  end

  defp build_auth_from_context(_), do: nil

  defp available_redirect_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp protocol_mode("2026-07-28"), do: :modern_only
  defp protocol_mode(_legacy_version), do: :legacy_only

  # Exercise the server API based on what the scenario tests.
  # Most scenarios just need connect + list + call tools.
  defp exercise_api(_client, "initialize", _context) do
    # Initialize already happened during connect — nothing more needed.
    Process.sleep(200)
  end

  defp exercise_api(client, scenario, context) do
    # Default: list tools and call each one. This covers tools_call, auth,
    # elicitation, and most other scenarios. The conformance framework
    # validates the protocol interactions, not our scenario routing.
    case Arbor.MCP.Client.list_tools(client, format: :map) do
      {:ok, result} ->
        tools = result["tools"] || []
        Logger.info("Listed #{length(tools)} tools")

        calls = ClientScenarios.tool_calls(tools, scenario, context)

        for {tool, args} <- calls do
          name = tool["name"]
          Logger.info("Calling tool: #{name}")

          case Arbor.MCP.Client.call_tool(client, name, args, format: :map) do
            {:ok, _} -> Logger.info("Tool #{name}: OK")
            {:error, reason} -> Logger.warning("Tool #{name} failed: #{inspect(reason)}")
          end
        end

      {:error, reason} ->
        Logger.warning("list_tools failed: #{inspect(reason)}")
    end
  end
end

unless Process.get(:ex_mcp_conformance_compile_only, false) do
  ConformanceClient.run()
end
