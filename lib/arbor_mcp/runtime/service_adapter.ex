defmodule Arbor.MCP.Server.Runtime.ServiceAdapter do
  @moduledoc """
  Lifecycle and isolation declaration for runtime service adapters.

  An owned adapter declares `bounded_startup: 1`, implements `start_link/1`,
  calls `watch_owned/1` at the start of each owned process's initialization, and
  passes `:init_timeout_ms` to its finite OTP startup timeout. Supervisor adapters
  use `start_supervisor/2`; Elixir `Supervisor.start_link/3` ignores timeout
  options. Every additional owned child must register with those same startup options before it can block.
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

  alias Arbor.MCP.Server.Runtime.{Deadline, Initialization, ServiceStartup, ShutdownGuard}

  @callback runtime_service_capabilities() :: %{
              optional(:bounded_startup) => 1,
              optional(:namespace) => 1
            }

  @doc """
  Starts an owned supervisor under its actual OTP parent with a finite cutoff.

  Pass the injected runtime options unchanged. Its `init/1` and every additional
  owned child must still call `watch_owned/1` before they can block. The ordinary
  Elixir `Supervisor.start_link/3` does not accept a startup timeout.
  Standalone adapters use `:init_timeout_ms` (default 10,000 ms).
  Custom via names declare `runtime_name_capabilities/0 => %{finite_lookup: 1}`;
  their initiating-caller `whereis_name/1` must be pure and finite. Registration
  and owner initialization use the finite constructor timeout.
  """
  @spec start_supervisor(module(), keyword()) :: Supervisor.on_start()
  def start_supervisor(module, opts) do
    timeout = Keyword.get(opts, :init_timeout_ms, 10_000)

    if is_integer(timeout) and timeout > 0 and timeout <= 4_294_967_295 do
      standalone_cutoff = Deadline.now() + timeout
      deadline = Keyword.get(opts, :runtime_init_deadline, standalone_cutoff)

      if is_integer(deadline) and Deadline.validate(deadline) == :ok do
        Initialization.start_supervisor(
          module,
          opts,
          min(deadline, standalone_cutoff),
          opts[:name]
        )
      else
        {:error, :invalid_admission_deadline}
      end
    else
      {:error, {:invalid_limit, :init_timeout_ms}}
    end
  end

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
