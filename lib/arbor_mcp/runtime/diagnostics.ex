defmodule Arbor.MCP.Server.Runtime.Diagnostics do
  @moduledoc false

  @counts [
    :work,
    :tasks,
    :entries,
    :owners,
    :writers,
    :bindings,
    :loans,
    :pending,
    :receipts,
    :monitors,
    :domains
  ]
  @safe_reasons [:normal, :shutdown, :killed, :runtime_stopped, :runtime_restarted]

  # A native supervisor prints child MFAs in status and failure reports. Capture
  # construction arguments in an opaque function rather than its printed list.
  # Applying it here preserves the actual supervisor as the child's OTP parent;
  # this creates no process, registration, alternate lifetime or start deadline.
  def child_spec(child) do
    spec = Supervisor.child_spec(child, [])
    {module, function, arguments} = spec.start

    spec
    |> Map.put_new(:modules, [module])
    |> Map.put(:start, {__MODULE__, :start_child, [fn -> apply(module, function, arguments) end]})
  end

  def start_child(constructor), do: constructor.()

  def format_status(status, component) do
    Map.new(status, fn
      {:state, state} -> {:state, summarize_state(state, component)}
      {:reason, reason} when reason in @safe_reasons -> {:reason, reason}
      {:log, _events} -> {:log, []}
      {key, _value} -> {key, :redacted}
    end)
  end

  defp summarize_state(state, component) when is_map(state) do
    Enum.reduce(@counts, %{component: component, payloads: :redacted}, fn key, summary ->
      case Map.get(state, key) do
        values when is_map(values) -> Map.put(summary, key, map_size(values))
        _other -> summary
      end
    end)
  end

  defp summarize_state(_state, component), do: %{component: component, payloads: :redacted}
end
