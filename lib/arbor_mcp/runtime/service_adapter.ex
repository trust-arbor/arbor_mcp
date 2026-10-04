defmodule Arbor.MCP.Server.Runtime.ServiceAdapter do
  @moduledoc """
  Lifecycle and isolation declaration for runtime service adapters.

  An owned adapter declares `bounded_startup: 1`, implements `start_link/1`,
  calls `watch_owned/1` at the start of each owned process's initialization, and
  passes `:init_timeout_ms` to its finite OTP startup timeout. Every additional
  owned child must register with those same startup options before it can block.
  Detached or unregistered children are unsupported. The runtime runs startup
  behind an independent cohort deadline observer while preserving its OTP parent.
  An adapter that starts unregistered processes violates this contract; it
  cannot receive cleanup guarantees for
  arbitrary effects performed before registration.

  A borrowed adapter declares `namespace: 1` and applies the supplied
  `:namespace` to **every** operation. Its `:server` is a live local process
  address. The runtime monitors it but never stops it. A shared namespace must
  identify one logical server; separate logical servers require separate keys.
  Capability declarations are adapter contracts, not backend certification.
  """

  alias Arbor.MCP.Server.Runtime.{ServiceStartup, ShutdownGuard}

  @callback runtime_service_capabilities() :: %{
              optional(:bounded_startup) => 1,
              optional(:namespace) => 1
            }

  @doc "Registers the owned service process before adapter initialization can block."
  @spec watch_owned(keyword()) ::
          :ok | {:error, :runtime_stopped | :runtime_unavailable | :service_start_timeout}
  def watch_owned(opts) do
    case Keyword.get(opts, :runtime_table) do
      nil ->
        :ok

      table ->
        case {opts[:runtime_service_starter], opts[:runtime_init_deadline]} do
          {starter, deadline} when is_pid(starter) and is_integer(deadline) ->
            ServiceStartup.register(table, self(), starter, deadline)

          _normal_lifetime ->
            with :ok <- ShutdownGuard.watch(table, self()) do
              :ets.insert(table, {{:service_owner, self()}, true})
              :ok
            end
        end
    end
  end
end
