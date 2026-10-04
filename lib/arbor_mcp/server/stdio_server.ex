defmodule Arbor.MCP.Server.StdioServer do
  @moduledoc """
  Starts an owned runtime for a newline-delimited JSON-RPC stdio server.

  `start_link/1` accepts `:module` (or `:handler`) and returns the runtime
  supervisor. Use `Arbor.MCP.Server` helpers for custom calls and controls;
  the returned PID is no longer an inline callback GenServer in v2.

  Responses are prepared before state commits. One owned writer writes
  already encoded frames; credit settles only after IO reports completion.
  A timed-out in-flight write is uncertain, terminal and never retried.

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
  """

  alias Arbor.MCP.Server.Runtime
  alias Arbor.MCP.Server.Runtime.Initialization
  alias Arbor.MCP.Server.Stdio.{Dispatch, Supervisor}

  @timer_limit 4_294_967_295

  @spec start_link(keyword()) :: Elixir.Supervisor.on_start()
  def start_link(opts) do
    opts = Keyword.put(opts, :handler, Keyword.get(opts, :module, Keyword.get(opts, :handler)))
    opts = opts |> Keyword.put_new(:handler_args, opts) |> Keyword.put(:dispatcher, Dispatch)

    with {:ok, config, deadline} <- Initialization.configure(opts),
         {:ok, stdio_opts} <- stdio_options(opts, config) do
      Runtime.start_configured(
        Keyword.put(opts, :edge, {Supervisor, Keyword.merge(opts, stdio_opts)}),
        config,
        deadline
      )
    end
  end

  def child_spec(opts),
    do: %{Runtime.child_spec(opts) | start: {__MODULE__, :start_link, [opts]}}

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
