defmodule Arbor.MCP.Server.StdioServer do
  @moduledoc """
  Starts an owned runtime for a newline-delimited JSON-RPC stdio server.

  `start_link/1` accepts `:module` (or `:handler`) and returns the runtime
  supervisor. Use `Arbor.MCP.Server` helpers for custom calls and controls;
  the returned PID is no longer an inline callback GenServer in v2.

  Responses are prepared before state commits. Startup acquires an exclusive
  lease for the borrowed output device under the original initialization
  deadline. A second live endpoint returns `:stdio_output_in_use`; a retired
  endpoint with unresolved IO waits only until that cutoff.

  The owned runtime Writer proxies an endpoint-owned physical sender. A held
  write remains charged across runtime replacement until IO reports completion
  and that sender exits. Writer or runtime death alone cannot release it. A
  timed-out in-flight write is uncertain, terminal and never retried; sender,
  device, or authority loss without completion fails closed. The persistent
  authority admits at most 64 output devices and does not restart empty after
  failure.

  EOF fences new input, drains accepted work under its original deadlines
  and `:stdio_eof_timeout_ms`, then stops the owned runtime. The default EOF
  budget is request timeout plus output timeout, capped at the largest finite
  OTP timer. The cutoff is established once and never renewed.

  The reader retains at most one `:max_request_bytes` frame outside admission,
  reading bounded units before a newline arrives. OS and borrowed IO-device
  buffers are outside this bound. Configure the host's Logger to stderr before
  application startup; this module never changes VM-global Logger settings.
  Handler diagnostic IO must also go to stderr.

  Options include `:stdio_input` and `:stdio_output` (borrowed devices, default
  the starting caller's group leader), and `:stdio_startup_delay` (default the
  application setting, or 100 ms). Only the first input line may have a UTF-8
  BOM. Blank/non-JSON startup lines are ignored. A valid final frame without
  a newline is processed before EOF.

  Output devices must be local live PIDs, local registered atoms, or
  `:stdio`/`:standard_io`. Custom `:via` output addresses are unsupported.
  """

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.Initialization
  alias Arbor.MCP.Server.Stdio.{Dispatch, OutputAuthority, OutputLease, Supervisor}

  @timer_limit 4_294_967_295

  @doc """
  Starts an owned stdio Runtime and returns its native supervisor PID.

  Options select `:module` or `:handler` and the borrowed input/output devices.
  Startup uses one initialization cutoff and acquires the output-device lease
  before returning. Use `Arbor.MCP.Server` helpers for calls and controls; this
  PID is a Runtime root, rather than an inline handler GenServer.
  """
  @spec start_link(keyword()) :: Elixir.Supervisor.on_start()
  def start_link(opts) do
    opts = Keyword.put(opts, :handler, Keyword.get(opts, :module, Keyword.get(opts, :handler)))
    opts = opts |> Keyword.put_new(:handler_args, opts) |> Keyword.put(:dispatcher, Dispatch)

    with {:ok, config, deadline} <- Initialization.configure(opts),
         {:ok, stdio_opts} <- stdio_options(opts, config),
         {:ok, authority} <- output_authority(opts, deadline),
         {:ok, lease} <-
           OutputAuthority.acquire(authority, stdio_opts[:stdio_output], config, deadline) do
      stdio_opts =
        stdio_opts
        |> Keyword.put(:stdio_output, OutputLease.device(lease))
        |> Keyword.put(:stdio_output_lease, lease)

      result =
        Initialization.start_configured(
          Keyword.put(opts, :edge, {Supervisor, Keyword.merge(opts, stdio_opts)}),
          config,
          deadline
        )

      if not match?({:ok, _}, result), do: OutputAuthority.release(lease, deadline)
      result
    end
  end

  @doc """
  Returns the supervisor child specification for the owned stdio Runtime.

  The specification starts `start_link/1` and preserves Runtime supervision
  and diagnostic argument protection. It does not take ownership of borrowed
  host IO devices.
  """
  def child_spec(opts),
    do:
      Arbor.MCP.Server.Runtime.Diagnostics.child_spec(%{
        Runtime.child_spec(opts)
        | start: {__MODULE__, :start_link, [opts]},
          modules: [__MODULE__]
      })

  defp output_authority(opts, deadline) do
    case Keyword.fetch(opts, :_stdio_output_authority) do
      {:ok, ref} -> Arbor.MCP.Server.Stdio.OutputAuthority.Ref.validate(ref)
      :error -> OutputAuthority.default(deadline)
    end
  end

  defp stdio_options(opts, config) do
    delay =
      Keyword.get(
        opts,
        :stdio_startup_delay,
        Application.get_env(:arbor_mcp, :stdio_startup_delay, 100)
      )

    eof_timeout =
      Keyword.get(
        opts,
        :stdio_eof_timeout_ms,
        min(@timer_limit, config.request_timeout_ms + config.output_timeout_ms)
      )

    cond do
      not is_integer(delay) or delay < 0 or delay > @timer_limit ->
        {:error, {:invalid_limit, :stdio_startup_delay}}

      not is_integer(eof_timeout) or eof_timeout <= 0 or eof_timeout > @timer_limit ->
        {:error, {:invalid_limit, :stdio_eof_timeout_ms}}

      true ->
        {:ok,
         [
           stdio_config: config,
           stdio_input: Keyword.get(opts, :stdio_input, Process.group_leader()),
           stdio_output: Keyword.get(opts, :stdio_output, Process.group_leader()),
           stdio_startup_delay: delay,
           stdio_eof_timeout_ms: eof_timeout,
           endpoint: Keyword.get(opts, :endpoint, "stdio"),
           transport: :stdio
         ]}
    end
  end
end
