# Runnable: mix run examples/dynamic_tools.exs --demo
# Application-owned catalog; these modules are example application code.
defmodule Arbor.MCP.Examples.DynamicTools.Actions do
  alias Arbor.MCP.Server.{Context, Result}

  def echo(arguments, state) do
    if state.test_pid, do: send(state.test_pid, {:dynamic_invoked, self(), arguments})
    {:ok, Result.structured("accepted", arguments), %{state | count: state.count + 1}}
  end

  def value(arguments, state),
    do: {:ok, Result.structured("value", arguments["value"]), state}

  def hold(_arguments, state) do
    send(state.test_pid, {:dynamic_holding, self(), Context.scope()})

    receive do
      {:arbor_mcp_cancelled, _token, _reason} ->
        send(state.test_pid, {:dynamic_cancelled, Context.cancelled?()})
        {:ok, Result.structured("late", %{count: 999}), %{state | count: 999}}
    end
  end
end

defmodule Arbor.MCP.Examples.DynamicTools do
  @moduledoc """
  Example application Handler with a bounded, explicitly mutable tool catalog.

  All catalog changes and tool calls use the same Runtime scheduler/state.
  Register MFA pairs, not closures capturing arbitrary retained state.
  """
  use Arbor.MCP.Server.Handler
  defoverridable handle_call: 3

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{Context, Result}

  @max_tools 32
  @max_descriptor_bytes 16_384
  @transport_argument_keys ["_meta", "_request_id"]
  @schema_options [max_schema_bytes: 16_384, resolve_timeout_ms: 100, validation_timeout_ms: 100]

  @impl true
  def init(opts) do
    {:ok,
     %{
       tools: %{},
       dispatch: %{},
       compiled: %{},
       defaults: %{},
       count: 0,
       compile_count: 0,
       test_pid: opts[:test_pid],
       cancelled_requests: MapSet.new()
     }}
  end

  @impl true
  def handle_initialize(_params, state) do
    {:ok,
     %{
       protocolVersion: "2025-03-26",
       serverInfo: %{name: "dynamic-example", version: "2"},
       capabilities: %{tools: %{listChanged: true}}
     }, state}
  end

  @impl true
  def handle_list_tools(nil, state), do: {:ok, definitions(state), nil, state}
  def handle_list_tools(_cursor, state), do: {:error, input_error("Invalid tool cursor"), state}

  @impl true
  def handle_call_tool(name, arguments, state) do
    case Map.fetch(state.dispatch, name) do
      {:ok, {module, function}} -> invoke(name, arguments, {module, function}, state)
      :error -> {:error, input_error("Unknown dynamic tool"), state}
    end
  end

  @impl true
  def handle_call({:register, entries, policy}, _from, state) do
    case register(entries, policy, state) do
      {:ok, next} -> {:reply, {:ok, notify_changed()}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove, name}, _from, state) do
    if Map.has_key?(state.tools, name) do
      next = %{
        state
        | tools: Map.delete(state.tools, name),
          dispatch: Map.delete(state.dispatch, name),
          compiled: Map.delete(state.compiled, name),
          defaults: Map.delete(state.defaults, name)
      }

      {:reply, {:ok, notify_changed()}, next}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get, name}, _from, state), do: {:reply, Map.fetch(state.tools, name), state}
  def handle_call(:list, _from, state), do: {:reply, definitions(state), state}

  def handle_call(:stats, _from, state),
    do:
      {:reply,
       %{count: state.count, tools: map_size(state.tools), compile_count: state.compile_count},
       state}

  defp definitions(state), do: state.tools |> Map.values() |> Enum.sort_by(& &1["name"])

  defp register(entries, policy, state) when is_list(entries) and policy in [:reject, :replace] do
    if entries == [] or length(entries) > @max_tools do
      {:error, :invalid_registration}
    else
      with :ok <- unique_names(entries) do
        Enum.reduce_while(entries, {:ok, state}, fn entry, {:ok, next} ->
          case register_entry(entry, policy, next) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp register(_entries, _policy, _state), do: {:error, :invalid_registration}

  defp unique_names(entries) do
    names =
      Enum.map(entries, fn
        {%{"name" => name}, {_module, _function}, _defaults} -> name
        _other -> nil
      end)

    if length(Enum.uniq(names)) == length(names), do: :ok, else: {:error, :duplicate_tool}
  end

  defp register_entry({definition, {module, function}, defaults}, policy, state) do
    with :ok <- validate_entry(definition, {module, function}, defaults),
         :ok <- available_name(definition["name"], policy, state),
         false <- Context.cancelled?(),
         {:ok, input} <- SchemaPolicy.compile(definition["inputSchema"], @schema_options),
         {:ok, output} <-
           SchemaPolicy.compile_optional(definition["outputSchema"], @schema_options) do
      name = definition["name"]

      {:ok,
       %{
         state
         | tools: Map.put(state.tools, name, definition),
           dispatch: Map.put(state.dispatch, name, {module, function}),
           defaults: Map.put(state.defaults, name, defaults),
           compiled: Map.put(state.compiled, name, {input, output}),
           compile_count: state.compile_count + 1 + if(is_nil(output), do: 0, else: 1)
       }}
    else
      true -> {:error, :request_cancelled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_entry(_entry, _policy, _state), do: {:error, :invalid_registration}

  defp validate_entry(definition, dispatch, defaults) do
    with :ok <- validate_definition(definition),
         :ok <- validate_defaults(defaults) do
      validate_dispatch(dispatch)
    end
  end

  defp validate_definition(definition) do
    cond do
      not is_map(definition) or is_struct(definition) ->
        {:error, :invalid_definition}

      not is_binary(definition["name"]) or definition["name"] == "" ->
        {:error, :invalid_name}

      not Map.has_key?(definition, "inputSchema") ->
        {:error, :missing_input_schema}

      not descriptor_schemas?(definition) ->
        {:error, :invalid_descriptor_schema}

      not bounded_json?(definition) ->
        {:error, :invalid_definition}

      true ->
        :ok
    end
  end

  defp validate_defaults(defaults) do
    cond do
      not is_map(defaults) or not bounded_json?(defaults) ->
        {:error, :invalid_definition}

      Enum.any?(@transport_argument_keys, &Map.has_key?(defaults, &1)) ->
        {:error, :reserved_default}

      true ->
        :ok
    end
  end

  defp validate_dispatch({module, function}) do
    if is_atom(module) and is_atom(function) and Code.ensure_loaded?(module) and
         function_exported?(module, function, 2),
       do: :ok,
       else: {:error, :invalid_dispatch}
  end

  defp descriptor_schemas?(definition) do
    input = definition["inputSchema"]
    valid_input = is_map(input) and not is_struct(input) and input["type"] == "object"

    valid_output =
      case Map.fetch(definition, "outputSchema") do
        :error -> true
        {:ok, schema} -> is_map(schema) and not is_struct(schema)
      end

    valid_input and valid_output
  end

  defp available_name(name, :reject, state) do
    if Map.has_key?(state.tools, name), do: {:error, :duplicate_tool}, else: capacity(name, state)
  end

  defp available_name(name, :replace, state), do: capacity(name, state)

  defp capacity(name, state) do
    if Map.has_key?(state.tools, name) or map_size(state.tools) < @max_tools,
      do: :ok,
      else: {:error, :catalog_full}
  end

  defp invoke(name, arguments, {module, function}, state) do
    {input, output} = state.compiled[name]

    if is_map(arguments) and not is_struct(arguments) and bounded_json?(arguments) do
      # Request identity and progress metadata live in Context, not tool data.
      arguments = Map.merge(state.defaults[name], Map.drop(arguments, @transport_argument_keys))

      case SchemaPolicy.validate(arguments, input, @schema_options) do
        :ok ->
          # Application actions return complete results built with the public
          # constructors; they do not call framework normalization internals.
          {:ok, result, next} = normalize_action(apply(module, function, [arguments, state]), state)

          validate_result(result, output, next)

        {:error, _reason} ->
          {:error, input_error("Invalid dynamic tool arguments"), state}
      end
    else
      {:error, input_error("Invalid dynamic tool arguments"), state}
    end
  end

  defp normalize_action({:ok, result}, state), do: normalize_action({:ok, result, state}, state)

  defp normalize_action({:ok, result, next}, _state) when is_map(result) and not is_struct(result),
    do: {:ok, result, next}

  defp normalize_action({:error, reason}, state), do: {:ok, Result.error(reason), state}
  defp normalize_action({:error, reason, next}, _state), do: {:ok, Result.error(reason), next}

  defp normalize_action(_result, _state),
    do: raise(ArgumentError, "Dynamic tool actions must return a complete Result map")

  defp validate_result(result, nil, state), do: {:ok, result, state}

  defp validate_result(result, output, state) do
    case Map.fetch(result, :structuredContent) do
      {:ok, data} ->
        validate_output(data, result, output, state)

      :error ->
        case Map.fetch(result, "structuredContent") do
          {:ok, data} -> validate_output(data, result, output, state)
          :error -> {:ok, result, state}
        end
    end
  end

  defp validate_output(data, result, output, state) do
    case SchemaPolicy.validate(data, output, @schema_options) do
      :ok -> {:ok, result, state}
      {:error, _reason} -> {:ok, Result.error("Output validation failed"), state}
    end
  end

  # Runtime enforces the original invocation deadline and suppresses cancelled
  # state commits. Notification admission is reported separately from catalog mutation.
  defp notify_changed, do: Server.notify_tools_changed(self())
  defp input_error(message), do: Arbor.MCP.Error.protocol_error(-32602, message)

  defp bounded_json?(term),
    do: :erlang.external_size(term) <= @max_descriptor_bytes and json?(term, 0)

  defp json?(_term, depth) when depth > 16, do: false
  defp json?(term, _depth) when is_binary(term), do: String.valid?(term)
  defp json?(term, _depth) when is_number(term) or term in [true, false, nil], do: true
  defp json?(term, depth) when is_list(term), do: Enum.all?(term, &json?(&1, depth + 1))

  defp json?(term, depth) when is_map(term) and not is_struct(term),
    do:
      Enum.all?(term, fn {key, value} ->
        is_binary(key) and String.valid?(key) and json?(value, depth + 1)
      end)

  defp json?(_term, _depth), do: false
end

defmodule Arbor.MCP.Examples.DynamicTools.Demo do
  @moduledoc false
  alias Arbor.MCP.Examples.DynamicTools
  alias Arbor.MCP.Examples.DynamicTools.Actions
  alias Arbor.MCP.Server
  alias Arbor.MCP.Server.{HandlerServer, Runtime}
  alias Arbor.MCP.Transport.Test

  def run do
    {:ok, root} = HandlerServer.start_link(handler: DynamicTools, transport: :test)

    try do
      {:ok, transport} = Test.connect(server: root)

      definition = %{
        "name" => "echo",
        "inputSchema" => %{"type" => "object"},
        "description" => "Dynamic echo"
      }

      {:ok, notification_status} =
        Server.call(root, {:register, [{definition, {Actions, :echo}, %{}}], :reject})

      IO.puts("list_changed admission: #{inspect(notification_status)}")
      IO.puts("catalog: #{Jason.encode!(Server.call(root, :list))}")

      {:ok, _transport} =
        Test.send_message(
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}}
          },
          transport
        )

      response = await_response(System.monotonic_time(:millisecond) + 1_000)
      IO.puts("MCP tool response: #{Jason.encode!(response)}")
    after
      :ok = Runtime.stop(root)
    end
  end

  defp await_response(deadline) do
    receive do
      {:transport_message, encoded} ->
        message = if is_binary(encoded), do: Jason.decode!(encoded), else: encoded
        if message["id"] == 1, do: message, else: await_response(deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        raise "Example did not receive its MCP tool response"
    end
  end
end

if "--demo" in System.argv(), do: Arbor.MCP.Examples.DynamicTools.Demo.run()
