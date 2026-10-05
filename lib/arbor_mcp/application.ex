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
        # Optional node-local single-use enforcement for resumed MRTR requests
        Arbor.MCP.Server.ReplayCache.ETS,
        # Atomically retains modern task handles across client connections
        {Arbor.MCP.Tasks.Store.ETS,
         Application.get_env(:arbor_mcp, Arbor.MCP.Tasks.Store.ETS, [])},
        # Coordinates bounded MCP 2026-07-28 subscription listeners
        {Arbor.MCP.Server.Subscriptions,
         Application.get_env(:arbor_mcp, Arbor.MCP.Server.Subscriptions, [])},
        # Owns the ETS table mapping SSE session ids to handler pids for
        # Arbor.MCP.HttpPlug (must outlive individual HTTP request processes)
        Arbor.MCP.HttpPlug.SessionRegistry,
        # Owns the ETS table of cancelled request ids so handlers can call
        # Context.cancelled?/0 without waiting on the server GenServer
        Arbor.MCP.Server.Cancellation,
        # Owns the ETS indexes for streamable-HTTP resource subscriptions
        Arbor.MCP.SubscriptionRegistry,
        # Start the Session Manager for streamable HTTP sessions
        Arbor.MCP.SessionManager,
        # Start the Progress Tracker for 2025-06-18 progress notifications
        Arbor.MCP.ProgressTracker,
        # Start the Reliability Supervisor for circuit breakers and health checks
        {Arbor.MCP.Reliability.Supervisor, name: Arbor.MCP.Reliability.Supervisor}
      ]

    opts = [strategy: :one_for_one, name: Arbor.MCP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
