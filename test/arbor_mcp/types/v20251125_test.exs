defmodule Arbor.MCP.Types.V20251125Test do
  @moduledoc """
  Tests for Arbor.MCP.Types.V20251125 type definition module.

  Verifies the module exists, exports the correct protocol version,
  and defines the expected types for the 2025-11-25 MCP specification.
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.Types.V20251125

  describe "module existence" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(V20251125)
    end
  end

  describe "protocol_version/0" do
    test "returns the correct protocol version string" do
      assert V20251125.protocol_version() == "2025-11-25"
    end

    test "protocol version is a valid date string" do
      version = V20251125.protocol_version()
      assert is_binary(version)
      assert String.match?(version, ~r/^\d{4}-\d{2}-\d{2}$/)
    end
  end

  describe "type definitions" do
    test "module exports expected type metadata" do
      # Verify the module has type information by checking beam attributes
      {:ok, types} = Code.Typespec.fetch_types(V20251125)
      type_names = Enum.map(types, fn {_kind, {name, _def, _args}} -> name end)

      # Core types re-exported from Arbor.MCP.Types
      assert :json_value in type_names
      assert :json_schema in type_names
      assert :request_id in type_names
      assert :cursor in type_names
      assert :progress_token in type_names
      assert :log_level in type_names
      assert :meta in type_names

      # New in 2025-11-25: Icons
      assert :icon in type_names

      # Implementation with title/description
      assert :implementation in type_names

      # Capabilities
      assert :client_capabilities in type_names
      assert :server_capabilities in type_names

      # Tool types
      assert :tool_annotations in type_names
      assert :task_support in type_names
      assert :tool in type_names

      # Resource types
      assert :resource in type_names
      assert :resource_annotations in type_names

      # Prompt types
      assert :prompt in type_names

      # Tool result
      assert :call_tool_result in type_names

      # Task types (new in 2025-11-25)
      assert :task_state in type_names
      assert :task in type_names
      assert :create_task_result in type_names

      # URL elicitation (new in 2025-11-25)
      assert :url_elicit_request in type_names

      # Tool calling in sampling
      assert :tool_choice in type_names
      assert :tool_use_content in type_names
      assert :tool_result_content in type_names

      # Elicitation result
      assert :elicit_result in type_names
    end
  end

  describe "spec field name conformance" do
    # These tests verify that the type definitions use the field names
    # prescribed by the 2025-11-25 MCP specification. Since Elixir @type
    # definitions are checked at compile time via Dialyzer, we inspect the
    # BEAM type metadata at runtime to confirm the map keys match the spec.

    setup do
      {:ok, types} = Code.Typespec.fetch_types(V20251125)

      type_map =
        types
        |> Enum.map(fn {_kind, {name, definition, _args}} -> {name, definition} end)
        |> Map.new()

      {:ok, types: type_map}
    end

    # Helper to extract map keys from a type definition AST.
    # Handles both required() and optional() wrappers, and
    # extracts the atom or string literal used as the key.
    defp extract_map_keys(type_ast) do
      extract_map_keys_recursive(type_ast, [])
      |> List.flatten()
      |> Enum.uniq()
    end

    defp extract_map_keys_recursive({:type, _, :map, fields}, acc) when is_list(fields) do
      keys =
        Enum.flat_map(fields, fn
          {:type, _, :map_field_exact, [{:atom, _, key} | _]} ->
            [key]

          {:type, _, :map_field_assoc, [{:atom, _, key} | _]} ->
            [key]

          {:type, _, :map_field_exact, [{:remote_type, _, _} | _]} ->
            []

          {:type, _, :map_field_assoc, [{:remote_type, _, _} | _]} ->
            []

          _ ->
            []
        end)

      [keys | acc]
    end

    defp extract_map_keys_recursive({:type, _, _name, args}, acc) when is_list(args) do
      Enum.reduce(args, acc, fn arg, inner_acc ->
        extract_map_keys_recursive(arg, inner_acc)
      end)
    end

    defp extract_map_keys_recursive(_other, acc), do: acc

    test "icon type should use :src, not :type/:uri", %{types: types} do
      # Spec: Icon { src: string, mimeType?: string, sizes?: string, theme?: string }
      icon_def = Map.fetch!(types, :icon)
      keys = extract_map_keys(icon_def)

      # Spec-required field
      assert :src in keys,
             "Icon type must have :src field per spec, but found keys: #{inspect(keys)}"

      # Spec-optional fields that should be present
      assert :mimeType in keys,
             "Icon type should have optional :mimeType field per spec"

      # Fields that should NOT be present (they are not in the spec)
      refute :type in keys,
             "Icon type must not use :type -- spec uses :src instead"

      refute :uri in keys,
             "Icon type must not use :uri -- spec uses :src instead"

      refute :mediaType in keys,
             "Icon type must not use :mediaType -- spec uses :mimeType instead"
    end

    test "implementation type should include websiteUrl and icons", %{types: types} do
      # Spec: Implementation { name: string, title?: string, version: string,
      #        description?: string, websiteUrl?: string, icons?: Icon[] }
      impl_def = Map.fetch!(types, :implementation)
      keys = extract_map_keys(impl_def)

      # Required fields
      assert :name in keys, "Implementation must have :name"
      assert :version in keys, "Implementation must have :version"

      # Optional fields from spec
      assert :title in keys, "Implementation should have optional :title"
      assert :description in keys, "Implementation should have optional :description"

      assert :websiteUrl in keys,
             "Implementation must have optional :websiteUrl per spec, but found keys: #{inspect(keys)}"

      assert :icons in keys,
             "Implementation must have optional :icons per spec, but found keys: #{inspect(keys)}"
    end

    test "task type wire format should use taskId, status, statusMessage, lastUpdatedAt, pollInterval",
         %{types: types} do
      # Spec: Task { taskId: string, status: TaskState, statusMessage?: string,
      #        createdAt: string, lastUpdatedAt: string, ttl: number, pollInterval?: number }
      task_def = Map.fetch!(types, :task)
      keys = extract_map_keys(task_def)

      # Spec-required fields
      assert :taskId in keys,
             "Task type must use :taskId per spec, but found keys: #{inspect(keys)}"

      assert :status in keys,
             "Task type must use :status per spec, but found keys: #{inspect(keys)}"

      assert :createdAt in keys, "Task type must have :createdAt"
      assert :lastUpdatedAt in keys, "Task type must have :lastUpdatedAt per spec"
      assert :ttl in keys, "Task type must have :ttl"

      # Spec-optional fields
      assert :statusMessage in keys,
             "Task type must have optional :statusMessage per spec"

      assert :pollInterval in keys,
             "Task type must have optional :pollInterval per spec"

      # Fields that should NOT be present (non-spec field names)
      refute :id in keys,
             "Task type must not use :id -- spec uses :taskId instead"

      refute :state in keys,
             "Task type must not use :state -- spec uses :status instead"

      refute :toolName in keys,
             "Task type must not have :toolName -- not in spec wire format"

      refute :arguments in keys,
             "Task type must not have :arguments -- not in spec wire format"

      refute :metadata in keys,
             "Task type must not have :metadata -- not in spec wire format"
    end

    test "tool_choice should use :mode, not :type", %{types: types} do
      # Spec: ToolChoice { mode?: string }
      tc_def = Map.fetch!(types, :tool_choice)
      keys = extract_map_keys(tc_def)

      assert :mode in keys,
             "ToolChoice must use :mode per spec, but found keys: #{inspect(keys)}"

      refute :type in keys,
             "ToolChoice must not use :type -- spec uses :mode instead"
    end

    test "tool_result_content should use :toolUseId, not :tool_use_id", %{types: types} do
      # Spec: ToolResultContent { type: string, toolUseId: string, content: Content[], isError?: boolean }
      trc_def = Map.fetch!(types, :tool_result_content)
      keys = extract_map_keys(trc_def)

      assert :toolUseId in keys,
             "ToolResultContent must use :toolUseId per spec, but found keys: #{inspect(keys)}"

      refute :tool_use_id in keys,
             "ToolResultContent must not use :tool_use_id -- spec uses camelCase :toolUseId"

      # Other required fields
      assert :type in keys, "ToolResultContent must have :type"
      assert :content in keys, "ToolResultContent must have :content"
    end

    test "call_tool_result should use :structuredContent, not :structuredOutput", %{types: types} do
      # Spec: CallToolResult { content?: Content[], structuredContent?: any,
      #        resourceLinks?: ResourceLink[], isError?: boolean }
      ctr_def = Map.fetch!(types, :call_tool_result)
      keys = extract_map_keys(ctr_def)

      assert :structuredContent in keys,
             "CallToolResult must use :structuredContent per spec, but found keys: #{inspect(keys)}"

      refute :structuredOutput in keys,
             "CallToolResult must not use :structuredOutput -- spec uses :structuredContent"
    end

    test "url_elicit_request should include :mode and :elicitationId", %{types: types} do
      # Spec: UrlElicitRequest { message: string, url: string, mode: string,
      #        elicitationId: string, _meta?: Meta }
      uer_def = Map.fetch!(types, :url_elicit_request)
      keys = extract_map_keys(uer_def)

      assert :message in keys, "UrlElicitRequest must have :message"
      assert :url in keys, "UrlElicitRequest must have :url"

      assert :mode in keys,
             "UrlElicitRequest must have :mode per spec, but found keys: #{inspect(keys)}"

      assert :elicitationId in keys,
             "UrlElicitRequest must have :elicitationId per spec, but found keys: #{inspect(keys)}"
    end

    test "server_capabilities logging should be empty object, completions should use plural",
         %{types: types} do
      # Spec: ServerCapabilities { ..., logging?: {}, completions?: {} }
      sc_def = Map.fetch!(types, :server_capabilities)
      keys = extract_map_keys(sc_def)

      # Should use plural "completions", not singular "completion"
      assert :completions in keys,
             "ServerCapabilities must use :completions (plural) per spec"

      refute :completion in keys,
             "ServerCapabilities must not use :completion (singular) -- spec uses :completions"

      # logging should be present
      assert :logging in keys,
             "ServerCapabilities must have :logging"

      # logging should be an empty object (no sub-fields like :setLevel)
      # We verify this by inspecting the type AST for the logging field.
      # The logging value type should be an empty map %{}.
      logging_value_type = extract_field_value_type(sc_def, :logging)

      refute logging_value_type == :has_fields,
             "ServerCapabilities.logging should be an empty object %{} per spec, not a map with fields like :setLevel"
    end
  end

  # Extracts the value type for a specific field key in a map type AST.
  # Returns :empty_map if the field maps to %{}, :has_fields if the map has fields,
  # or :other for non-map types.
  defp extract_field_value_type({:type, _, :map, fields}, key) when is_list(fields) do
    Enum.find_value(fields, :not_found, fn
      {:type, _, field_kind, [{:atom, _, ^key}, value_type]}
      when field_kind in [:map_field_exact, :map_field_assoc] ->
        case value_type do
          {:type, _, :map, :any} ->
            :empty_map

          {:type, _, :map, []} ->
            :empty_map

          {:type, _, :map, inner_fields}
          when is_list(inner_fields) and length(inner_fields) > 0 ->
            :has_fields

          _ ->
            :other
        end

      _ ->
        nil
    end)
  end

  defp extract_field_value_type(_, _), do: :not_found
end
