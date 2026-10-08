defmodule Arbor.MCP.Types.V20260728Test do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Types.V20260728

  @expected_types [
    :request_meta_object,
    :notification_meta_object,
    :result_meta_object,
    :result_type,
    :cacheable_result,
    :discover_result,
    :input_request,
    :input_response,
    :input_requests,
    :input_responses,
    :task_status,
    :task,
    :create_task_result,
    :detailed_task,
    :get_task_result,
    :get_task_request_params,
    :update_task_request_params,
    :cancel_task_request_params,
    :input_required_result,
    :input_response_request_params,
    :subscription_filter,
    :subscriptions_listen_request,
    :subscriptions_listen_result,
    :header_mismatch_error,
    :unsupported_protocol_version_error,
    :missing_required_client_capability_error
  ]

  test "describes the opt-in protocol version" do
    assert V20260728.protocol_version() == "2026-07-28"
  end

  test "exports the Phase 1 modern type surface" do
    types = type_map(V20260728)

    for type <- @expected_types do
      assert Map.has_key?(types, type), "missing #{type}/0"
    end
  end

  test "request metadata contains the required stateless protocol fields" do
    fields = root_fields(type_map(V20260728).request_meta_object)

    assert fields[:"io.modelcontextprotocol/protocolVersion"] == :required
    assert fields[:"io.modelcontextprotocol/clientCapabilities"] == :required
    assert fields[:"io.modelcontextprotocol/clientInfo"] == :optional
    assert fields[:"io.modelcontextprotocol/logLevel"] == :optional
    assert fields[:progressToken] == :optional
  end

  test "result and cacheable result fields match the modern envelope" do
    types = type_map(V20260728)
    result_fields = root_fields(types.result)
    cache_fields = root_fields(types.cacheable_result)

    assert result_fields.resultType == :required
    assert result_fields._meta == :optional

    assert cache_fields.resultType == :required
    assert cache_fields.ttlMs == :required
    assert cache_fields.cacheScope == :required
  end

  test "discover result carries versions, capabilities, instructions, and caching hints" do
    fields = root_fields(type_map(V20260728).discover_result)

    for field <- [:resultType, :ttlMs, :cacheScope, :supportedVersions, :capabilities] do
      assert fields[field] == :required
    end

    assert fields.instructions == :optional
    assert fields._meta == :optional
  end

  test "MRTR types preserve opaque request state and keyed request/response maps" do
    types = type_map(V20260728)
    fields = root_fields(types.input_required_result)

    assert fields.resultType == :required
    assert fields.inputRequests == :optional
    assert fields.requestState == :optional
    assert Map.has_key?(types, :input_requests)
    assert Map.has_key?(types, :input_responses)
  end

  test "task extension types use the redesigned modern fields" do
    types = type_map(V20260728)
    task_fields = root_fields(types.task)
    create_fields = root_fields(types.create_task_result)
    detailed_fields = root_fields(types.detailed_task)
    get_fields = root_fields(types.get_task_result)
    update_fields = root_fields(types.update_task_request_params)

    for field <- [:taskId, :status, :createdAt, :lastUpdatedAt, :ttlMs] do
      assert task_fields[field] == :required
      assert create_fields[field] == :required
    end

    assert task_fields.pollIntervalMs == :optional
    assert create_fields.resultType == :required
    assert get_fields.resultType == :required
    assert get_fields.taskId == :required
    assert detailed_fields.inputRequests == :optional
    assert detailed_fields.result == :optional
    assert detailed_fields.error == :optional
    assert update_fields.inputResponses == :required
  end

  test "subscription types include every standard filter and stream correlation metadata" do
    types = type_map(V20260728)
    filter_fields = root_fields(types.subscription_filter)
    result_fields = root_fields(types.subscriptions_listen_result)
    meta_fields = root_fields(types.subscriptions_listen_result_meta_object)

    for field <- [
          :toolsListChanged,
          :promptsListChanged,
          :resourcesListChanged,
          :resourceSubscriptions,
          :taskIds
        ] do
      assert filter_fields[field] == :optional
    end

    assert result_fields.resultType == :required
    assert result_fields._meta == :required
    assert meta_fields[:"io.modelcontextprotocol/subscriptionId"] == :required
  end

  test "modern protocol errors pin their assigned codes and required data" do
    types = type_map(V20260728)

    assert contains_integer_literal?(types.header_mismatch_error, -32020)
    assert contains_integer_literal?(types.unsupported_protocol_version_error, -32022)
    assert contains_integer_literal?(types.missing_required_client_capability_error, -32021)

    unsupported_keys = all_atom_keys(types.unsupported_protocol_version_error)
    missing_capability_keys = all_atom_keys(types.missing_required_client_capability_error)

    assert :supported in unsupported_keys
    assert :requested in unsupported_keys
    assert :requiredCapabilities in missing_capability_keys

    for error_type <- [
          types.header_mismatch_error,
          types.unsupported_protocol_version_error,
          types.missing_required_client_capability_error
        ] do
      assert root_fields(error_type).id == :optional
      assert root_fields(error_type).error == :required
    end
  end

  test "capability types expose the extensions namespace" do
    modern_types = type_map(V20260728)
    shared_types = type_map(Arbor.MCP.Types)

    assert root_fields(modern_types.client_capabilities).extensions == :optional
    assert root_fields(modern_types.server_capabilities).extensions == :optional
    assert root_fields(shared_types.client_capabilities).extensions == :optional
    assert root_fields(shared_types.server_capabilities).extensions == :optional
  end

  test "tool schemas are unrestricted and structured content accepts any JSON value" do
    types = type_map(V20260728)
    shared_types = type_map(Arbor.MCP.Types)

    assert map_type?(types.json_schema)
    assert map_type?(shared_types.json_schema)
    assert root_fields(types.tool).outputSchema == :optional
    assert root_fields(types.call_tool_result).structuredContent == :optional
    assert root_fields(shared_types.tool_result).structuredContent == :optional
  end

  test "numeric elicitation constraints and defaults use number types" do
    fields = root_field_values(type_map(V20260728).number_schema)

    for field <- [:minimum, :maximum, :default] do
      assert number_type?(fields[field]), "expected #{field} to use number()"
    end
  end

  defp type_map(module) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    Map.new(types, fn {_kind, {name, definition, _args}} -> {name, definition} end)
  end

  defp root_fields(type_ast) do
    Map.new(root_field_entries(type_ast), fn {kind, key, _value} -> {key, kind} end)
  end

  defp root_field_values(type_ast) do
    Map.new(root_field_entries(type_ast), fn {_kind, key, value} -> {key, value} end)
  end

  defp root_field_entries({:type, _, :map, fields}) when is_list(fields) do
    Enum.flat_map(fields, fn
      {:type, _, :map_field_exact, [{:atom, _, key}, value]} ->
        [{:required, key, value}]

      {:type, _, :map_field_assoc, [{:atom, _, key}, value]} ->
        [{:optional, key, value}]

      _other ->
        []
    end)
  end

  defp root_field_entries(_type_ast), do: []

  defp all_atom_keys(type_ast), do: type_ast |> collect_atom_keys([]) |> Enum.uniq()

  defp collect_atom_keys({:type, _, :map, fields}, acc) when is_list(fields) do
    Enum.reduce(fields, acc, fn
      {:type, _, field_kind, [{:atom, _, key}, value]}, inner_acc
      when field_kind in [:map_field_exact, :map_field_assoc] ->
        collect_atom_keys(value, [key | inner_acc])

      field, inner_acc ->
        collect_atom_keys(field, inner_acc)
    end)
  end

  defp collect_atom_keys({_kind, _, _name, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &collect_atom_keys/2)
  end

  defp collect_atom_keys(_type_ast, acc), do: acc

  defp contains_integer_literal?({:integer, _, expected}, expected), do: true

  defp contains_integer_literal?({:op, _, :-, {:integer, _, value}}, expected),
    do: -value == expected

  defp contains_integer_literal?(term, expected) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&contains_integer_literal?(&1, expected))
  end

  defp contains_integer_literal?(terms, expected) when is_list(terms) do
    Enum.any?(terms, &contains_integer_literal?(&1, expected))
  end

  defp contains_integer_literal?(_term, _expected), do: false

  defp map_type?({:type, _, :map, _fields}), do: true
  defp map_type?(_type), do: false

  defp number_type?({:type, _, :number, []}), do: true
  defp number_type?(_type), do: false
end
