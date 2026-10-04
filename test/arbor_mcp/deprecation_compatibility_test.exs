defmodule Arbor.MCP.DeprecationCompatibilityTest do
  use ExUnit.Case, async: true

  @retained_tools_modules [
    Arbor.MCP.Server.Tools,
    Arbor.MCP.Server.Tools.Simplified,
    Arbor.MCP.Server.Tools.Builder,
    Arbor.MCP.Server.Tools.Helpers,
    Arbor.MCP.Server.Tools.Registry,
    Arbor.MCP.Server.Tools.ResponseNormalizer,
    Arbor.MCP.Server.Tools.ASTValidator
  ]

  @deprecated_metadata_modules [Arbor.MCP.Server.Tools]

  @retained_protocol_functions [
    {Arbor.MCP.Server, :send_log_message, 4},
    {Arbor.MCP.Server, :list_roots, 2},
    {Arbor.MCP.Server, :notify_roots_changed, 1},
    {Arbor.MCP.Server, :create_message, 2},
    {Arbor.MCP.Server.Context, :send_log_message, 3},
    {Arbor.MCP.Client, :list_roots, 2},
    {Arbor.MCP.Client, :set_log_level, 2},
    {Arbor.MCP.Client, :log_message, 3},
    {Arbor.MCP.Client, :log_message, 4}
  ]

  @retained_protocol_callbacks [
    {Arbor.MCP.Client.Handler, :handle_list_roots, 1},
    {Arbor.MCP.Client.Handler, :handle_create_message, 2},
    {Arbor.MCP.Server.Handler, :handle_list_roots, 1},
    {Arbor.MCP.Server.Handler, :handle_create_message, 2},
    {Arbor.MCP.Server.Handler, :handle_set_log_level, 2}
  ]

  test "deprecated Server.Tools modules remain public throughout 1.x" do
    for module <- @retained_tools_modules do
      assert Code.ensure_loaded?(module)
      assert {:docs_v1, _, _, _, %{"en" => module_doc}, _, _} = Code.fetch_docs(module)
      assert module_doc =~ "2.0.0"
      refute module_doc =~ "1.1.0"
    end
  end

  test "remaining compiled deprecation metadata schedules Tools removal for 2.0" do
    for module <- @deprecated_metadata_modules do
      assert {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

      messages =
        for {_identifier, _line, _signatures, _doc, metadata} <- docs,
            message = metadata[:deprecated],
            is_binary(message),
            do: message

      assert messages != []
      assert Enum.all?(messages, &String.contains?(&1, "2.0.0"))
      refute Enum.any?(messages, &String.contains?(&1, "1.1.0"))
    end
  end

  test "protocol-deprecated Roots, Sampling, and Logging APIs remain public in 1.x" do
    for {module, name, arity} <- @retained_protocol_functions do
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, name, arity)
    end

    for {module, name, arity} <- @retained_protocol_callbacks do
      assert {name, arity} in module.behaviour_info(:callbacks)
    end
  end

  test "protocol deprecation docs provide migrations without scheduling a 1.x removal" do
    documented = @retained_protocol_functions ++ @retained_protocol_callbacks

    for {module, name, arity} <- documented do
      {doc, metadata} = compiled_doc(module, name, arity)
      normalized_doc = normalize_whitespace(doc)
      assert normalized_doc =~ "deprecated as of 2026-07-28"
      assert normalized_doc =~ "throughout Arbor.MCP 1.x"
      refute metadata[:deprecated]
    end

    {roots_doc, _metadata} = compiled_doc(Arbor.MCP.Server, :list_roots, 2)
    roots_doc = normalize_whitespace(roots_doc)
    assert roots_doc =~ "tool parameters"
    assert roots_doc =~ "resource URIs"
    assert roots_doc =~ "server configuration"

    {sampling_doc, _metadata} = compiled_doc(Arbor.MCP.Server, :create_message, 2)
    sampling_doc = normalize_whitespace(sampling_doc)
    assert sampling_doc =~ "LLM provider API"

    {logging_doc, _metadata} = compiled_doc(Arbor.MCP.Server, :send_log_message, 4)
    logging_doc = normalize_whitespace(logging_doc)
    assert logging_doc =~ "stderr"
    assert logging_doc =~ "OpenTelemetry"
  end

  defp compiled_doc(module, name, arity) do
    assert {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    case Enum.find(docs, fn {{kind, entry_name, entry_arity}, _, _, _, _} ->
           kind in [:function, :callback] and entry_name == name and entry_arity == arity
         end) do
      {{_kind, ^name, ^arity}, _line, _signatures, %{"en" => doc}, metadata} ->
        {doc, metadata}

      nil ->
        flunk("missing compiled documentation for #{inspect(module)}.#{name}/#{arity}")
    end
  end

  defp normalize_whitespace(doc), do: String.replace(doc, ~r/\s+/, " ")
end
