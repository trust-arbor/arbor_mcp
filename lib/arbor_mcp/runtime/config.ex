defmodule Arbor.MCP.Server.Runtime.Config do
  @moduledoc false

  defstruct handler: nil,
            handler_args: [],
            dispatcher: Arbor.MCP.Server.Dispatch,
            cancellation_tracker: nil,
            dispatch_opts: [],
            execution: :stateful,
            max_concurrency: 1,
            max_queue: 128,
            max_request_bytes: 1_000_000,
            max_pending_bytes: 8_000_000,
            max_control_queue: 32,
            max_control_bytes: 65_536,
            request_timeout_ms: 10_000,
            cancel_grace_ms: 100,
            init_timeout_ms: 10_000,
            shutdown_timeout_ms: 5_000

  def new(opts) when is_list(opts) do
    keys = Map.keys(Map.from_struct(%__MODULE__{}))
    config = struct(__MODULE__, Keyword.take(opts, keys))

    with :ok <- validate_handler(config),
         :ok <- validate_execution(config),
         :ok <- validate_limits(config) do
      {:ok, config}
    end
  end

  defp validate_handler(%{handler: handler, dispatcher: dispatcher})
       when is_atom(handler) and not is_nil(handler) and is_atom(dispatcher),
       do: :ok

  defp validate_handler(_config), do: {:error, :handler_required}

  defp validate_execution(%{execution: :stateful, max_concurrency: 1}), do: :ok

  defp validate_execution(%{execution: :stateless, max_concurrency: count})
       when is_integer(count) and count > 0,
       do: :ok

  defp validate_execution(_config), do: {:error, :invalid_execution_configuration}

  defp validate_limits(config) do
    positive = [
      :max_request_bytes,
      :max_pending_bytes,
      :max_control_bytes,
      :request_timeout_ms,
      :init_timeout_ms,
      :shutdown_timeout_ms
    ]

    nonnegative = [:max_queue, :max_control_queue, :cancel_grace_ms]

    case Enum.find(positive, &(not positive_integer?(Map.fetch!(config, &1)))) ||
           Enum.find(nonnegative, &(not nonnegative_integer?(Map.fetch!(config, &1)))) do
      nil -> :ok
      key -> {:error, {:invalid_limit, key}}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
end
