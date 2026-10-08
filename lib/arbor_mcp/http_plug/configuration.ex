defmodule Arbor.MCP.HttpPlug.Configuration do
  @moduledoc false

  alias Arbor.MCP.Server.Runtime.Ref

  @retired [
    :handler,
    :handler_args,
    :handler_call_timeout,
    :server,
    :session_manager,
    :session_store,
    :subscription_registry,
    :replay_cache,
    :sse_enabled,
    :use_sse
  ]
  @limits [
    :subscription_max_queue,
    :subscription_max_message_bytes,
    :subscription_max_queue_bytes,
    :subscription_max_lifetime_ms
  ]

  def validate!(opts, phase \\ :configuration) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "MCP HTTP options must be a keyword list")

    case Enum.find(@retired, &Keyword.has_key?(opts, &1)) do
      nil ->
        :ok

      key ->
        raise ArgumentError,
              "MCP HTTP option #{inspect(key)} is retired; supervise a Runtime with handler/handler_args and configure its services explicitly"
    end

    validate_runtime!(Keyword.get(opts, :runtime), phase)

    case subscription_options(opts) do
      :ok ->
        :ok

      {:error, {:invalid_http_subscription_option, key}} ->
        raise ArgumentError,
              "MCP HTTP option #{inspect(key)} requires a valid authorizer or finite positive limit"
    end

    :ok
  end

  # The mount captured this opaque kind at initialization. Request-time resolution
  # remains RuntimeWriter's authority check, including retirement of old roots.
  defp validate_runtime!(%Ref{}, :request), do: :ok
  defp validate_runtime!(runtime, _phase), do: validate_runtime!(runtime)

  def validate_runtime!(%Ref{} = runtime) do
    unless Ref.valid?(runtime),
      do: raise(ArgumentError, "MCP HTTP runtime reference is unavailable")

    :ok
  end

  def validate_runtime!(runtime) when is_pid(runtime) do
    unless node(runtime) == node(), do: raise(ArgumentError, "MCP HTTP runtime must be local")
    :ok
  end

  # Named runtimes need not be running while Plug compiles its mount options.
  def validate_runtime!(name) when is_atom(name) and name not in [nil, false, true], do: :ok
  def validate_runtime!({:global, _name}), do: :ok
  def validate_runtime!({:via, module, _name}) when is_atom(module), do: :ok

  def validate_runtime!(_other),
    do:
      raise(
        ArgumentError,
        "MCP HTTP requires runtime: <named Runtime, root PID or Runtime.Ref>; handler-only mounts are retired"
      )

  def subscription_options(opts) do
    checks =
      [
        {:authorize_subscription_filter, fn value -> is_function(value, 2) end},
        {:authorize_subscription_publication, fn value -> is_function(value, 3) end}
      ] ++
        Enum.map(@limits, fn key ->
          {key, fn value -> is_integer(value) and value in 1..4_294_967_295 end}
        end)

    case Enum.find(checks, fn {key, valid?} ->
           value = Keyword.get(opts, key)
           not is_nil(value) and not valid?.(value)
         end) do
      nil -> :ok
      {key, _} -> {:error, {:invalid_http_subscription_option, key}}
    end
  end
end
