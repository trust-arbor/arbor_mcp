defmodule Arbor.MCP.Server.DSL do
  @moduledoc """
  Modern DSL for defining MCP server primitives next to their handlers.

  Use this module with `Arbor.MCP.Server.Handler`:

      defmodule MyServer do
        use Arbor.MCP.Server.Handler
        use Arbor.MCP.Server.DSL, name: "my-server", version: "1.0.0"

        tool "echo", "Echo back the input" do
          param :message, :string, required: true
          param :tags, {:array, :string}, default: []

          run fn %{message: message}, state ->
            {:ok, message, state}
          end
        end
      end

  Param types include `:string`, `:integer`, `:number`, `:boolean`,
  `:object`/`:map`, and `{:array, item_type}`. Bare `:array` is rejected at
  compile time.

  Invalid declarations fail at compile time with file/line and fix hints
  (missing handlers, duplicate names, wrong instructions per kind, etc.).

  Inside DSL modules, `ToolResult` is an alias for `Arbor.MCP.Server.DSL.Result`.
  See the project DSL guide for full details.
  """

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.DSL.Builder

  # DSL schemas are trusted application declarations compiled while the module
  # is loading. Give their worker enough scheduler headroom during parallel
  # builds without relaxing the tighter runtime policy default.
  @compile_time_schema_timeout_ms 5_000

  defmacro __using__(opts) do
    quote do
      import Arbor.MCP.Server.DSL
      alias Arbor.MCP.Server.DSL.Result, as: ToolResult

      @ex_mcp_dsl_opts unquote(Macro.escape(opts))
      Module.register_attribute(__MODULE__, :ex_mcp_dsl_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :ex_mcp_dsl_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :ex_mcp_dsl_resource_templates, accumulate: true)
      Module.register_attribute(__MODULE__, :ex_mcp_dsl_prompts, accumulate: true)

      @doc false
      def child_spec(opts) do
        %{
          id: Keyword.get(opts, :id, __MODULE__),
          start: {__MODULE__, :start_link, [opts]},
          type:
            if(Keyword.get(opts, :transport, :beam) in [:test, :beam],
              do: :supervisor,
              else: :worker
            ),
          restart: :permanent,
          shutdown: Keyword.get(opts, :shutdown_timeout_ms, 5_000)
        }
      end

      defoverridable child_spec: 1

      @before_compile Arbor.MCP.Server.DSL
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :ex_mcp_dsl_opts, [])
    tools = env.module |> Module.get_attribute(:ex_mcp_dsl_tools, []) |> Enum.reverse()
    resources = env.module |> Module.get_attribute(:ex_mcp_dsl_resources, []) |> Enum.reverse()

    resource_templates =
      env.module
      |> Module.get_attribute(:ex_mcp_dsl_resource_templates, [])
      |> Enum.reverse()

    prompts = env.module |> Module.get_attribute(:ex_mcp_dsl_prompts, []) |> Enum.reverse()

    assert_unique_ids!(env, tools, :tool, & &1.name)
    assert_unique_ids!(env, resources, :resource, & &1.uri)
    assert_unique_ids!(env, resource_templates, :resource_template, & &1.uriTemplate)
    assert_unique_ids!(env, prompts, :prompt, & &1.name)

    quote do
      unquote(
        generate_server_callbacks(env.module, opts, tools, resources, resource_templates, prompts)
      )

      unquote_splicing(generate_tool_handlers(tools))
      unquote(generate_tool_callbacks(tools))

      unquote_splicing(generate_resource_handlers(resources, :resource))
      unquote_splicing(generate_resource_handlers(resource_templates, :resource_template))
      unquote(generate_resource_callbacks(resources, resource_templates))

      unquote_splicing(generate_prompt_handlers(prompts))
      unquote(generate_prompt_callbacks(prompts))
    end
  end

  @doc """
  Defines a tool with a co-located handler.
  """
  defmacro tool(name, description \\ nil, do: block) do
    entry = build_entry(__CALLER__, :tool, name, description, block)

    quote do
      @ex_mcp_dsl_tools unquote(Macro.escape(entry))
    end
  end

  @doc """
  Defines a static resource with a co-located read handler.
  """
  defmacro resource(uri, description \\ nil, do: block) do
    entry = build_entry(__CALLER__, :resource, uri, description, block)

    quote do
      @ex_mcp_dsl_resources unquote(Macro.escape(entry))
    end
  end

  @doc """
  Defines a resource template with a co-located read handler.
  """
  defmacro resource_template(uri_template, description \\ nil, do: block) do
    entry = build_entry(__CALLER__, :resource_template, uri_template, description, block)

    quote do
      @ex_mcp_dsl_resource_templates unquote(Macro.escape(entry))
    end
  end

  @doc """
  Defines a prompt with a co-located renderer.
  """
  defmacro prompt(name, description \\ nil, do: block) do
    entry = build_entry(__CALLER__, :prompt, name, description, block)

    quote do
      @ex_mcp_dsl_prompts unquote(Macro.escape(entry))
    end
  end

  defmacro param(_name, _type, _opts \\ []), do: :ok
  defmacro arg(_name, _opts \\ []), do: :ok
  defmacro run(_handler), do: :ok
  defmacro handle(_handler), do: :ok
  defmacro read(_handler), do: :ok
  defmacro render(_handler), do: :ok
  defmacro title(_title), do: :ok
  defmacro name(_name), do: :ok
  defmacro description(_description), do: :ok
  defmacro annotations(_annotations), do: :ok
  defmacro icons(_icons), do: :ok
  defmacro meta(_meta), do: :ok
  defmacro execution(_execution), do: :ok
  defmacro input_schema(_schema), do: :ok
  defmacro output_schema(_schema), do: :ok
  defmacro mime_type(_mime_type), do: :ok
  defmacro size(_size), do: :ok

  @doc false
  def validate_tool_response(response, nil), do: {:ok, response}

  def validate_tool_response(response, output_schema) do
    structured_content =
      Map.get(response, :structuredContent) || Map.get(response, "structuredContent")

    if is_nil(structured_content) do
      {:ok, response}
    else
      data = atom_keys_to_strings(structured_content)

      case validate_with_schema(data, output_schema) do
        :ok ->
          {:ok, response}

        {:error, errors} ->
          {:error, "Output validation failed: #{format_validation_errors(errors)}"}
      end
    end
  end

  @handler_keys [:run, :handle, :read, :render]

  @tool_only [:run, :handle, :input_schema, :output_schema, :execution]
  @resource_only [:read, :mime_type, :size]
  @prompt_only [:render, :arg]
  @param_allowed_kinds [:tool, :resource_template]

  @instruction_suggestions %{
    inputSchema: :input_schema,
    outputSchema: :output_schema,
    mimeType: :mime_type,
    handler: :run,
    params: :param,
    arguments: :arg,
    argument: :arg
  }

  defp build_entry(env, kind, id_ast, description_ast, block) do
    id = eval_ast!(id_ast, env, "declaration name/URI")
    description = eval_ast!(description_ast, env, "description")
    assert_non_empty_id!(env, kind, id)

    instructions = parse_instructions(block, env, kind)
    label = declaration_label(kind, id)

    case kind do
      :tool ->
        handler = required_handler!(env, instructions, [:run, :handle], label)
        params = Map.get(instructions, :params, [])

        definition =
          Builder.tool(id, Map.get(instructions, :description, description),
            params: params,
            input_schema: Map.get(instructions, :input_schema),
            output_schema: Map.get(instructions, :output_schema),
            annotations: Map.get(instructions, :annotations),
            title: Map.get(instructions, :title),
            icons: Map.get(instructions, :icons),
            execution: Map.get(instructions, :execution),
            meta: Map.get(instructions, :meta)
          )

        {definition, handler, params}

      :resource ->
        handler = required_handler!(env, instructions, [:read], label)

        definition =
          Builder.resource(id, Map.get(instructions, :description, description),
            name: Map.get(instructions, :name),
            title: Map.get(instructions, :title),
            mime_type: Map.get(instructions, :mime_type),
            annotations: Map.get(instructions, :annotations),
            size: Map.get(instructions, :size),
            icons: Map.get(instructions, :icons),
            meta: Map.get(instructions, :meta)
          )

        {definition, handler, []}

      :resource_template ->
        handler = required_handler!(env, instructions, [:read], label)
        params = Map.get(instructions, :params, [])

        definition =
          Builder.resource_template(id, Map.get(instructions, :description, description),
            name: Map.get(instructions, :name),
            title: Map.get(instructions, :title),
            mime_type: Map.get(instructions, :mime_type),
            annotations: Map.get(instructions, :annotations),
            icons: Map.get(instructions, :icons),
            meta: Map.get(instructions, :meta)
          )

        {definition, handler, params}

      :prompt ->
        handler = required_handler!(env, instructions, [:render], label)
        args = Map.get(instructions, :args, [])

        definition =
          Builder.prompt(id, Map.get(instructions, :description, description),
            title: Map.get(instructions, :title),
            args: args,
            icons: Map.get(instructions, :icons),
            meta: Map.get(instructions, :meta)
          )

        {definition, handler, args}
    end
  end

  defp parse_instructions(block, env, kind) do
    block
    |> block_statements()
    |> Enum.reduce(%{params: [], args: []}, &parse_instruction(&1, &2, env, kind))
    |> Map.update!(:params, &Enum.reverse/1)
    |> Map.update!(:args, &Enum.reverse/1)
  end

  defp block_statements({:__block__, _meta, statements}), do: statements
  defp block_statements(statement), do: [statement]

  defp parse_instruction({:param, meta, args}, acc, env, kind) do
    assert_instruction_allowed!(env, meta, kind, :param)
    param = parse_param(args, env, meta)
    Map.update!(acc, :params, &[param | &1])
  end

  defp parse_instruction({:arg, meta, args}, acc, env, kind) do
    assert_instruction_allowed!(env, meta, kind, :arg)
    arg = parse_prompt_arg(args, env, meta)
    Map.update!(acc, :args, &[arg | &1])
  end

  defp parse_instruction({handler_kind, meta, [handler]}, acc, env, kind)
       when handler_kind in @handler_keys do
    assert_instruction_allowed!(env, meta, kind, handler_kind)

    if Map.has_key?(acc, handler_kind) or has_other_handler?(acc, handler_kind) do
      compile_error!(
        env,
        meta,
        "#{kind_name(kind)} already defines a handler; only one of run/handle/read/render is allowed"
      )
    end

    Map.put(acc, handler_kind, handler)
  end

  defp parse_instruction({instr, meta, [value]}, acc, env, kind)
       when instr in [
              :title,
              :name,
              :description,
              :annotations,
              :icons,
              :meta,
              :execution,
              :input_schema,
              :output_schema,
              :mime_type,
              :size
            ] do
    assert_instruction_allowed!(env, meta, kind, instr)
    Map.put(acc, instr, eval_ast!(value, env, Atom.to_string(instr), meta))
  end

  defp parse_instruction({unknown, meta, _args}, _acc, env, _kind) when is_atom(unknown) do
    suggestion =
      case Map.get(@instruction_suggestions, unknown) do
        nil ->
          ""

        known ->
          " Did you mean `#{known}`?"
      end

    compile_error!(
      env,
      meta,
      "Unknown Arbor.MCP.Server.DSL instruction: #{unknown}.#{suggestion}"
    )
  end

  defp parse_param([name, type], env, meta), do: parse_param([name, type, []], env, meta)

  defp parse_param([name, type, opts], env, meta) do
    param_name = eval_name!(name, env, meta)
    param_type = eval_ast!(type, env, "param type", meta)
    param_opts = eval_ast!(opts, env, "param options", meta)
    assert_param_type!(env, meta, param_name, param_type)
    Builder.param(param_name, param_type, param_opts)
  end

  defp parse_prompt_arg([name], env, meta), do: parse_prompt_arg([name, []], env, meta)

  defp parse_prompt_arg([name, opts], env, meta) do
    Builder.param(
      eval_name!(name, env, meta),
      :string,
      eval_ast!(opts, env, "arg options", meta)
    )
  end

  defp assert_param_type!(env, meta, name, type) do
    cond do
      type == :array ->
        compile_error!(
          env,
          meta,
          "Invalid param type :array for #{inspect(name)}. " <>
            "Use {:array, item_type}, e.g. {:array, :string} or {:array, :number}. " <>
            "Allowed types: #{Builder.allowed_param_types_hint()}"
        )

      Builder.allowed_param_type?(type) ->
        :ok

      true ->
        compile_error!(
          env,
          meta,
          "Invalid param type #{inspect(type)} for #{inspect(name)}. " <>
            "Allowed types: #{Builder.allowed_param_types_hint()}"
        )
    end
  end

  defp assert_instruction_allowed!(env, meta, kind, instruction) do
    allowed? =
      cond do
        instruction in [:title, :name, :description, :annotations, :icons, :meta] ->
          true

        instruction == :param ->
          kind in @param_allowed_kinds

        instruction in @tool_only ->
          kind == :tool

        instruction in @resource_only ->
          kind in [:resource, :resource_template]

        instruction in @prompt_only ->
          kind == :prompt

        true ->
          false
      end

    unless allowed? do
      compile_error!(
        env,
        meta,
        "`#{instruction}` is not valid inside #{kind_name(kind)}. " <>
          instruction_context_hint(instruction)
      )
    end
  end

  defp instruction_context_hint(:param),
    do: "Use `param` in tool or resource_template declarations."

  defp instruction_context_hint(:arg), do: "Use `arg` in prompt declarations."

  defp instruction_context_hint(instr) when instr in [:run, :handle],
    do: "Use `run` in tool declarations."

  defp instruction_context_hint(:read),
    do: "Use `read` in resource or resource_template declarations."

  defp instruction_context_hint(:render), do: "Use `render` in prompt declarations."

  defp instruction_context_hint(instr) when instr in [:input_schema, :output_schema, :execution],
    do: "Use `#{instr}` in tool declarations."

  defp instruction_context_hint(instr) when instr in [:mime_type, :size],
    do: "Use `#{instr}` in resource or resource_template declarations."

  defp instruction_context_hint(_), do: ""

  defp has_other_handler?(acc, handler_kind) do
    @handler_keys
    |> Enum.reject(&(&1 == handler_kind))
    |> Enum.any?(&Map.has_key?(acc, &1))
  end

  defp required_handler!(env, instructions, keys, label) do
    Enum.find_value(keys, &Map.get(instructions, &1)) ||
      compile_error!(
        env,
        nil,
        "#{label} must define #{handler_names(keys)}, e.g. #{example_handler(keys)}"
      )
  end

  defp handler_names([key]), do: "`#{key}`"
  defp handler_names(keys), do: Enum.map_join(keys, " or ", &"`#{&1}`")

  defp example_handler(keys) do
    cond do
      :run in keys or :handle in keys ->
        "run fn args, state -> {:ok, result, state} end"

      :read in keys ->
        "read fn params, state -> {:ok, result, state} end"

      :render in keys ->
        "render fn args, state -> {:ok, result, state} end"

      true ->
        "..."
    end
  end

  defp assert_non_empty_id!(env, kind, id) when is_binary(id) do
    if String.trim(id) == "" do
      compile_error!(env, nil, "#{kind_name(kind)} name/URI must be a non-empty string")
    end
  end

  defp assert_non_empty_id!(env, kind, id) do
    compile_error!(
      env,
      nil,
      "#{kind_name(kind)} name/URI must be a string, got: #{inspect(id)}"
    )
  end

  defp assert_unique_ids!(env, entries, kind, id_fun) do
    entries
    |> Enum.map(fn {definition, _handler, _params} -> id_fun.(definition) end)
    |> Enum.frequencies()
    |> Enum.each(fn {id, count} ->
      if count > 1 do
        compile_error!(
          env,
          nil,
          "Duplicate #{kind_name(kind)} #{inspect(id)} declared #{count} times"
        )
      end
    end)
  end

  defp declaration_label(:tool, id), do: "tool #{inspect(id)}"
  defp declaration_label(:resource, id), do: "resource #{inspect(id)}"
  defp declaration_label(:resource_template, id), do: "resource_template #{inspect(id)}"
  defp declaration_label(:prompt, id), do: "prompt #{inspect(id)}"

  defp kind_name(:tool), do: "tool"
  defp kind_name(:resource), do: "resource"
  defp kind_name(:resource_template), do: "resource_template"
  defp kind_name(:prompt), do: "prompt"

  defp eval_name!(ast, env, meta) do
    case eval_ast!(ast, env, "name", meta) do
      name when is_atom(name) ->
        name

      name when is_binary(name) ->
        String.to_atom(name)

      other ->
        compile_error!(env, meta, "Expected atom or string name, got: #{inspect(other)}")
    end
  end

  defp eval_ast!(ast, env, context), do: eval_ast!(ast, env, context, nil)

  defp eval_ast!(ast, env, context, meta) do
    ast
    |> Macro.expand(env)
    |> literal_value!(env, context, meta)
  end

  defp literal_value!({:%{}, _meta, pairs}, env, context, meta) do
    Map.new(pairs, fn {key, value} ->
      {literal_value!(key, env, context, meta), literal_value!(value, env, context, meta)}
    end)
  end

  defp literal_value!({:{}, _meta, values}, env, context, meta),
    do: List.to_tuple(Enum.map(values, &literal_value!(&1, env, context, meta)))

  # 2-tuples only (keyword pairs and {:array, :string}); never treat AST 3-tuples as data
  defp literal_value!({left, right}, env, context, meta),
    do: {literal_value!(left, env, context, meta), literal_value!(right, env, context, meta)}

  defp literal_value!(list, env, context, meta) when is_list(list),
    do: Enum.map(list, &literal_value!(&1, env, context, meta))

  defp literal_value!(value, _env, _context, _meta) when is_binary(value), do: value
  defp literal_value!(value, _env, _context, _meta) when is_atom(value), do: value
  defp literal_value!(value, _env, _context, _meta) when is_integer(value), do: value
  defp literal_value!(value, _env, _context, _meta) when is_float(value), do: value

  defp literal_value!(other, env, context, meta) do
    compile_error!(
      env,
      meta,
      "Expected a compile-time literal for #{context}, got: #{Macro.to_string(other)}. " <>
        "Use literals such as :string, :integer, {:array, :string}, or a map/list of literals."
    )
  end

  defp compile_error!(env, meta, message) do
    raise CompileError,
      file: env.file,
      line: line_from(meta) || env.line,
      description: message
  end

  defp line_from(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_from(_), do: nil

  defp generate_tool_handlers(tools) do
    tools
    |> Enum.with_index()
    |> Enum.map(fn {{_tool, handler, _params}, index} ->
      name = :"__ex_mcp_dsl_tool_#{index}__"

      quote do
        @doc false
        def unquote(name)(args, state), do: unquote(handler).(args, state)
      end
    end)
  end

  defp generate_server_callbacks(module, opts, tools, resources, resource_templates, prompts) do
    server_info = server_info(module, opts)
    capabilities = capabilities(tools, resources, resource_templates, prompts)
    start_link_callback = generate_start_link_callback(server_info)
    initialize_callback = generate_initialize_callback(server_info, capabilities)

    quote do
      unquote(start_link_callback)
      unquote(initialize_callback)

      @doc false
      def __server_info__, do: unquote(Macro.escape(server_info))

      @doc false
      def __server_capabilities__, do: unquote(Macro.escape(capabilities))
    end
  end

  defp generate_start_link_callback(server_info) do
    quote do
      alias Arbor.MCP.Server.{HandlerServer, Transport}

      @doc """
      Starts this MCP handler using the requested transport.
      """
      def start_link(opts \\ []) do
        case Keyword.get(opts, :transport, :beam) do
          :test ->
            opts
            |> Keyword.put_new(:handler, __MODULE__)
            |> HandlerServer.start_link()

          :beam ->
            opts
            |> Keyword.put_new(:handler, __MODULE__)
            |> HandlerServer.start_link()

          transport when transport in [:http, :stdio] ->
            Transport.start_server(
              __MODULE__,
              unquote(Macro.escape(server_info)),
              [],
              opts
            )

          transport ->
            {:error, {:unsupported_transport, transport}}
        end
      end
    end
  end

  defp generate_initialize_callback(server_info, capabilities) do
    quote do
      alias Arbor.MCP.Internal.VersionRegistry
      alias Arbor.MCP.Protocol.Initialize

      @impl Arbor.MCP.Server.Handler
      def handle_initialize(params, state) do
        client_version =
          Map.get(params, "protocolVersion") ||
            Map.get(params, :protocolVersion) ||
            VersionRegistry.latest_version()

        protocol_version =
          case VersionRegistry.negotiate_version(
                 client_version,
                 VersionRegistry.supported_versions()
               ) do
            {:ok, version} -> version
            {:error, _reason} -> VersionRegistry.latest_version()
          end

        result =
          Initialize.build_initialize_result(params, %{
            "protocolVersion" => protocol_version,
            "serverInfo" => unquote(Macro.escape(server_info)),
            "capabilities" => unquote(Macro.escape(capabilities))
          })

        {:ok, result, Map.put(state, :protocol_version, protocol_version)}
      end
    end
  end

  defp generate_tool_callbacks([]), do: nil

  defp generate_tool_callbacks(tools) do
    definitions = Enum.map(tools, fn {definition, _handler, _params} -> definition end)

    mapping =
      tools
      |> Enum.with_index()
      |> Map.new(fn {{definition, _handler, params}, index} ->
        compile_tool_schema(definition[:inputSchema], :input)
        output_schema = compile_tool_schema(definition[:outputSchema], :output)
        {definition.name, {:"__ex_mcp_dsl_tool_#{index}__", output_schema, params}}
      end)

    quote do
      alias Arbor.MCP.Server.DSL.{Builder, Result}

      @impl Arbor.MCP.Server.Handler
      def handle_list_tools(_cursor, state) do
        {:ok, unquote(Macro.escape(definitions)), nil, state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_call_tool(name, arguments, state) do
        mapping = unquote(Macro.escape(mapping))

        case Map.get(mapping, name) do
          {handler, output_schema, params} ->
            arguments = Builder.normalize_arguments(arguments, params)
            result = apply(__MODULE__, handler, [arguments, state])

            case Result.normalize_tool(result, state) do
              {:ok, response, new_state} ->
                validation =
                  response
                  |> Arbor.MCP.Server.DSL.validate_tool_response(output_schema)
                  |> __ex_mcp_dsl_widen_validation__()

                case validation do
                  {:ok, response} -> {:ok, response, new_state}
                  {:error, reason} -> {:ok, Result.error(reason), new_state}
                end
            end

          nil ->
            {:error, Arbor.MCP.Error.protocol_error(-32602, "Unknown tool: #{name}"), state}
        end
      end

      defp __ex_mcp_dsl_widen_validation__(validation), do: validation
    end
  end

  defp generate_resource_handlers(entries, kind) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {{_definition, handler, _params}, index} ->
      name = :"__ex_mcp_dsl_#{kind}_#{index}__"

      quote do
        @doc false
        def unquote(name)(params, state), do: unquote(handler).(params, state)
      end
    end)
  end

  defp generate_resource_callbacks([], []), do: nil

  defp generate_resource_callbacks(resources, resource_templates) do
    resource_definitions =
      Enum.map(resources, fn {definition, _handler, _params} -> definition end)

    template_definitions =
      Enum.map(resource_templates, fn {definition, _handler, _params} -> definition end)

    resource_mapping =
      resources
      |> Enum.with_index()
      |> Map.new(fn {{definition, _handler, _params}, index} ->
        {definition.uri, {:"__ex_mcp_dsl_resource_#{index}__", definition[:mimeType]}}
      end)

    template_mapping =
      resource_templates
      |> Enum.with_index()
      |> Enum.map(fn {{definition, _handler, params}, index} ->
        {definition.uriTemplate, :"__ex_mcp_dsl_resource_template_#{index}__",
         definition[:mimeType], params}
      end)

    quote do
      alias Arbor.MCP.Server.DSL.{Builder, Matcher, Result}

      unquote(resource_overridables(resources, resource_templates))
      unquote(generate_list_resources(resource_definitions))
      unquote(generate_list_resource_templates(template_definitions))

      @impl Arbor.MCP.Server.Handler
      def handle_read_resource(uri, state) do
        resource_mapping = unquote(Macro.escape(resource_mapping))
        template_mapping = unquote(Macro.escape(template_mapping))

        case Map.get(resource_mapping, uri) do
          {handler, mime_type} ->
            params = %{uri: uri}
            result = apply(__MODULE__, handler, [params, state])
            Result.normalize_resource(result, uri, mime_type, state)

          nil ->
            read_resource_template(uri, template_mapping, state)
        end
      end

      defp read_resource_template(uri, template_mapping, state) do
        Enum.find_value(template_mapping, fn {template, handler, mime_type, params} ->
          case Matcher.match_uri_template(uri, template) do
            {:ok, variables} ->
              variables =
                variables
                |> Builder.normalize_template_variables()
                |> Map.put(:uri, uri)
                |> Builder.normalize_arguments(params)

              result = apply(__MODULE__, handler, [variables, state])
              Result.normalize_resource(result, uri, mime_type, state)

            :error ->
              nil
          end
        end) ||
          {:error,
           Arbor.MCP.Error.protocol_error(
             Arbor.MCP.Protocol.ErrorCodes.resource_not_found(:modern),
             "Resource not found: #{uri}"
           ), state}
      end
    end
  end

  defp resource_overridables([], []) do
    nil
  end

  defp resource_overridables(resources, resource_templates) do
    callbacks =
      []
      |> maybe_add_callback(resources != [], {:handle_list_resources, 2})
      |> maybe_add_callback(resource_templates != [], {:handle_list_resource_templates, 2})
      |> maybe_add_callback(
        resources != [] or resource_templates != [],
        {:handle_read_resource, 2}
      )

    quote do
      defoverridable unquote(callbacks)
    end
  end

  defp generate_list_resources([]), do: nil

  defp generate_list_resources(resource_definitions) do
    quote do
      @impl Arbor.MCP.Server.Handler
      def handle_list_resources(_cursor, state) do
        {:ok, unquote(Macro.escape(resource_definitions)), nil, state}
      end
    end
  end

  defp generate_list_resource_templates([]), do: nil

  defp generate_list_resource_templates(template_definitions) do
    quote do
      @impl Arbor.MCP.Server.Handler
      def handle_list_resource_templates(_cursor, state) do
        {:ok, unquote(Macro.escape(template_definitions)), nil, state}
      end
    end
  end

  defp generate_prompt_handlers(prompts) do
    prompts
    |> Enum.with_index()
    |> Enum.map(fn {{_prompt, handler, _args}, index} ->
      name = :"__ex_mcp_dsl_prompt_#{index}__"

      quote do
        @doc false
        def unquote(name)(args, state), do: unquote(handler).(args, state)
      end
    end)
  end

  defp generate_prompt_callbacks([]), do: nil

  defp generate_prompt_callbacks(prompts) do
    definitions = Enum.map(prompts, fn {definition, _handler, _args} -> definition end)

    mapping =
      prompts
      |> Enum.with_index()
      |> Map.new(fn {{definition, _handler, args}, index} ->
        {definition.name, {:"__ex_mcp_dsl_prompt_#{index}__", args}}
      end)

    quote do
      alias Arbor.MCP.Server.DSL.{Builder, Result}

      defoverridable handle_list_prompts: 2, handle_get_prompt: 3

      @impl Arbor.MCP.Server.Handler
      def handle_list_prompts(_cursor, state) do
        {:ok, unquote(Macro.escape(definitions)), nil, state}
      end

      @impl Arbor.MCP.Server.Handler
      def handle_get_prompt(name, arguments, state) do
        mapping = unquote(Macro.escape(mapping))

        case Map.get(mapping, name) do
          {handler, args} ->
            arguments = Builder.normalize_arguments(arguments, args)
            result = apply(__MODULE__, handler, [arguments, state])
            Result.normalize_prompt(result, state)

          nil ->
            {:error, Arbor.MCP.Error.protocol_error(-32602, "Prompt not found: #{name}"), state}
        end
      end
    end
  end

  defp compile_tool_schema(schema, kind) do
    validate_descriptor_schema!(schema, kind)

    case SchemaPolicy.compile_optional(schema,
           resolve_timeout_ms: @compile_time_schema_timeout_ms
         ) do
      {:ok, resolved} ->
        resolved

      {:error, reason} ->
        raise ArgumentError,
              "invalid #{kind}_schema/1: " <> SchemaPolicy.format_error(reason)
    end
  end

  defp validate_descriptor_schema!(nil, :output), do: :ok

  defp validate_descriptor_schema!(schema, kind) when is_map(schema) and not is_struct(schema) do
    if kind == :input and
         (Map.get(schema, :type) || Map.get(schema, "type")) not in ["object", :object],
       do: raise(ArgumentError, "invalid input_schema/1: root type must be object"),
       else: :ok
  end

  defp validate_descriptor_schema!(_schema, kind),
    do: raise(ArgumentError, "invalid #{kind}_schema/1: Tool schema must be an object")

  defp validate_with_schema(data, schema) do
    case SchemaPolicy.validate_optional(data, schema) do
      :ok ->
        :ok

      {:error, reason} when is_tuple(reason) or is_atom(reason) ->
        {:error, [SchemaPolicy.format_error(reason)]}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp atom_keys_to_strings(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), atom_keys_to_strings(value)}
      {key, value} -> {key, atom_keys_to_strings(value)}
    end)
  end

  defp atom_keys_to_strings(list) when is_list(list), do: Enum.map(list, &atom_keys_to_strings/1)
  defp atom_keys_to_strings(value), do: value

  defp format_validation_errors(errors) when is_list(errors),
    do: Enum.map_join(errors, ", ", &inspect/1)

  defp maybe_add_callback(callbacks, true, callback), do: [callback | callbacks]
  defp maybe_add_callback(callbacks, false, _callback), do: callbacks

  defp server_info(module, opts) do
    case Keyword.get(opts, :server_info) do
      nil ->
        %{
          "name" => to_string(Keyword.get(opts, :name, module)),
          "version" => to_string(Keyword.get(opts, :version, "1.0.0"))
        }

      server_info ->
        server_info
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.update("name", to_string(module), &to_string/1)
        |> Map.update("version", "1.0.0", &to_string/1)
    end
  end

  defp capabilities(tools, resources, resource_templates, prompts) do
    %{}
    |> maybe_put_capability(tools != [], "tools", %{})
    |> maybe_put_capability(resources != [] or resource_templates != [], "resources", %{})
    |> maybe_put_capability(prompts != [], "prompts", %{})
  end

  defp maybe_put_capability(capabilities, true, key, value),
    do: Map.put(capabilities, key, value)

  defp maybe_put_capability(capabilities, false, _key, _value), do: capabilities
end
