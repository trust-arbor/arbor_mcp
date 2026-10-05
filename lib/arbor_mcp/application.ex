defmodule Arbor.MCP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Holds exclusive durable paths until actual DETS cleanup completes
        {Arbor.MCP.Internal.SessionStore.DETS.PathClaims,
         Application.get_env(:arbor_mcp, Arbor.MCP.Internal.SessionStore.DETS.PathClaims, [])},
        # Dynamic supervisor for runtime components
        {DynamicSupervisor, strategy: :one_for_one, name: Arbor.MCP.DynamicSupervisor},
        # Start the Consent Cache for security features
        Arbor.MCP.Internal.ConsentCache,
        # Remembers protocol-era observations across individual client processes
        Arbor.MCP.Client.EraCache,
        # Atomically consumes OAuth state and authorization codes
        {Arbor.MCP.Authorization.OAuthTransactionStore,
         Application.get_env(:arbor_mcp, Arbor.MCP.Authorization.OAuthTransactionStore, [])},
        # Start the Reliability Supervisor for circuit breakers and health checks
        {Arbor.MCP.Reliability.Supervisor, name: Arbor.MCP.Reliability.Supervisor}
      ]

    opts = [strategy: :one_for_one, name: Arbor.MCP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
