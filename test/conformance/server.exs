# Arbor.MCP Conformance Test Server
#
# Implements the "everything server" for MCP conformance testing.
# Uses library infrastructure (HttpPlug, SSESession, DnsRebinding).
# Tool/resource/prompt definitions are the only test-specific code.
#
# Start with: elixir test/conformance/server.exs [port]
# Then run:   npx @modelcontextprotocol/conformance server --url http://localhost:PORT/mcp

Mix.install([
  {:arbor_mcp, path: "."},
  {:plug_cowboy, "~> 2.7"},
  {:ranch, "== 1.8.1"},
  {:jason, "~> 1.4"}
])

# ── Test Data ────────────────────────────────────────────────────

# 1x1 red PNG pixel
test_image =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

# Minimal WAV file
test_audio = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

# Store in application env so handler module can access them
Application.put_env(:conformance, :test_image, test_image)
Application.put_env(:conformance, :test_audio, test_audio)

# ── Handler (tools, resources, prompts) ──────────────────────────

defmodule ConformanceHandler do
  use Arbor.MCP.Server.Handler

  alias Arbor.MCP.Server.Context

  @json_schema_uri "https://json-schema.org/draft/2020-12/schema"

  def __server_info__,
    do: %{name: "mcp-conformance-test-server", version: "1.0.0"}

  def __server_capabilities__ do
    %{
      "tools" => %{},
      "resources" => %{},
      "prompts" => %{},
      "completions" => %{}
    }
  end

  @impl true
  def init(_args), do: {:ok, %{subscriptions: MapSet.new()}}

  @impl true
  def handle_initialize(_params, state) do
    {:ok,
     %{
       name: "mcp-conformance-test-server",
       version: "1.0.0",
       capabilities: %{
         tools: %{listChanged: true},
         resources: %{subscribe: true, listChanged: true},
         prompts: %{listChanged: true},
         logging: %{},
         completions: %{}
       }
     }, state}
  end

  # ── Tools ────────────────────────────────────────────────────

  @impl true
  def handle_list_tools(_cursor, state) do
    image = Application.get_env(:conformance, :test_image)
    audio = Application.get_env(:conformance, :test_audio)
    _ = {image, audio}

    tools = [
      %{
        name: "test_simple_text",
        description: "Tests simple text content response",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_image_content",
        description: "Tests image content response",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_audio_content",
        description: "Tests audio content response",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_embedded_resource",
        description: "Tests embedded resource content response",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_multiple_content_types",
        description: "Tests response with multiple content types",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_tool_with_logging",
        description: "Tests tool that emits log messages",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_error_handling",
        description: "Tests error response handling",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_tool_with_progress",
        description: "Tests tool that reports progress",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_sampling",
        description: "Tests server-initiated sampling",
        inputSchema: %{
          type: "object",
          properties: %{prompt: %{type: "string"}},
          required: ["prompt"]
        }
      },
      %{
        name: "test_elicitation",
        description: "Tests server-initiated elicitation",
        inputSchema: %{
          type: "object",
          properties: %{message: %{type: "string"}},
          required: ["message"]
        }
      },
      %{
        name: "test_elicitation_sep1034_defaults",
        description: "Tests elicitation with defaults",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_elicitation_sep1330_enums",
        description: "Tests elicitation with enums",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "json_schema_2020_12_tool",
        description: "Tool with JSON Schema 2020-12 features",
        inputSchema: json_schema_2020_12()
      },
      %{
        name: "test_custom_header_validation",
        description: "Tests server-side Mcp-Param validation",
        inputSchema: %{
          type: "object",
          properties: %{
            routed_value: %{
              type: "string",
              "x-mcp-header": "Routed-Value"
            }
          },
          required: ["routed_value"]
        }
      },
      %{
        name: "test_missing_capability",
        description: "Requires the sampling client capability",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_streaming_elicitation",
        description: "Diagnostic tool validating response progress streams",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "test_logging_tool",
        description: "Diagnostic logging validator tool",
        inputSchema: %{type: "object", properties: %{}}
      }
      | mrtr_tools()
    ]

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("test_simple_text", _args, state) do
    {:ok, [%{type: "text", text: "This is a simple text response for testing."}], state}
  end

  def handle_call_tool("test_image_content", _args, state) do
    {:ok,
     [
       %{
         type: "image",
         data: Application.get_env(:conformance, :test_image),
         mimeType: "image/png"
       }
     ], state}
  end

  def handle_call_tool("test_audio_content", _args, state) do
    {:ok,
     [
       %{
         type: "audio",
         data: Application.get_env(:conformance, :test_audio),
         mimeType: "audio/wav"
       }
     ], state}
  end

  def handle_call_tool("test_embedded_resource", _args, state) do
    {:ok,
     [
       %{
         type: "resource",
         resource: %{
           uri: "test://embedded-resource",
           mimeType: "text/plain",
           text: "This is an embedded resource content."
         }
       }
     ], state}
  end

  def handle_call_tool("test_multiple_content_types", _args, state) do
    {:ok,
     [
       %{type: "text", text: "Multiple content types test:"},
       %{
         type: "image",
         data: Application.get_env(:conformance, :test_image),
         mimeType: "image/png"
       },
       %{
         type: "resource",
         resource: %{
           uri: "test://mixed-content-resource",
           mimeType: "application/json",
           text: Jason.encode!(%{test: "data", value: 123})
         }
       }
     ], state}
  end

  # Legacy bidirectional scenarios are handled by the fixture router. Modern
  # request-scoped notifications are emitted by the real HttpPlug path.
  def handle_call_tool("test_tool_with_logging", _args, state),
    do: {:ok, [%{type: "text", text: "Tool with logging executed successfully"}], state}

  def handle_call_tool("test_tool_with_progress", _args, state) do
    token = Context.progress_token() || 0

    for progress <- [0, 50, 100] do
      :ok =
        Context.report_progress(
          progress,
          100,
          "Completed step #{progress} of 100"
        )
    end

    {:ok, [%{type: "text", text: to_string(token)}], state}
  end

  def handle_call_tool("test_sampling", %{"prompt" => p}, state),
    do: {:ok, [%{type: "text", text: "Sampling: #{p}"}], state}

  def handle_call_tool("test_elicitation", %{"message" => m}, state),
    do: {:ok, [%{type: "text", text: "Elicitation: #{m}"}], state}

  def handle_call_tool("test_elicitation_sep1034_defaults", _args, state),
    do: {:ok, [%{type: "text", text: "Elicitation defaults"}], state}

  def handle_call_tool("test_elicitation_sep1330_enums", _args, state),
    do: {:ok, [%{type: "text", text: "Elicitation enums"}], state}

  def handle_call_tool("json_schema_2020_12_tool", _args, state),
    do: {:ok, [%{type: "text", text: "JSON Schema 2020-12"}], state}

  def handle_call_tool("test_custom_header_validation", %{"routed_value" => value}, state),
    do: {:ok, [%{type: "text", text: value}], state}

  def handle_call_tool("test_missing_capability", _args, state) do
    {:error, Arbor.MCP.Error.missing_required_client_capability(%{"sampling" => %{}}), state}
  end

  def handle_call_tool("test_input_required_result_elicitation", _args, state) do
    case Context.input_responses() do
      %{"user_name" => %{"content" => %{"name" => name}}} when is_binary(name) ->
        {:ok, [%{type: "text", text: "Hello, #{name}!"}], state}

      _missing_or_invalid ->
        {:input_required, elicitation_requests("user_name", "What is your name?", "name"),
         %{"flow" => "elicitation"}, state}
    end
  end

  def handle_call_tool("test_input_required_result_sampling", _args, state) do
    case Context.input_responses() do
      %{"capital_question" => response} ->
        {:ok, [%{type: "text", text: "Sampling response: #{Jason.encode!(response)}"}], state}

      _missing ->
        requests = %{
          "capital_question" => %{
            "method" => "sampling/createMessage",
            "params" => %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" => %{"type" => "text", "text" => "What is the capital of France?"}
                }
              ],
              "maxTokens" => 100
            }
          }
        }

        {:input_required, requests, %{"flow" => "sampling"}, state}
    end
  end

  def handle_call_tool("test_input_required_result_list_roots", _args, state) do
    case Context.input_responses() do
      %{"client_roots" => response} ->
        {:ok, [%{type: "text", text: "Roots: #{Jason.encode!(response)}"}], state}

      _missing ->
        {:input_required, %{"client_roots" => %{"method" => "roots/list", "params" => %{}}},
         %{"flow" => "roots"}, state}
    end
  end

  def handle_call_tool("test_input_required_result_request_state", _args, state) do
    case Context.input_responses() do
      %{"confirm" => _response} ->
        suffix =
          if Context.request_state() == %{"flow" => "request-state"},
            do: "state-ok",
            else: "state-error"

        {:ok, [%{type: "text", text: suffix}], state}

      _missing ->
        {:input_required, elicitation_requests("confirm", "Please confirm", "ok", "boolean"),
         %{"flow" => "request-state"}, state}
    end
  end

  def handle_call_tool("test_input_required_result_multiple_inputs", _args, state) do
    case Context.input_responses() do
      responses when is_map(responses) and map_size(responses) == 3 ->
        {:ok, [%{type: "text", text: "Received all inputs"}], state}

      _missing ->
        requests =
          elicitation_requests("user_name", "What is your name?", "name")
          |> Map.put("greeting", %{
            "method" => "sampling/createMessage",
            "params" => %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" => %{"type" => "text", "text" => "Generate a greeting"}
                }
              ],
              "maxTokens" => 50
            }
          })
          |> Map.put("client_roots", %{"method" => "roots/list", "params" => %{}})

        {:input_required, requests, %{"flow" => "multiple"}, state}
    end
  end

  def handle_call_tool("test_input_required_result_multi_round", _args, state) do
    case {Context.request_state(), Context.input_responses()} do
      {%{"round" => 1}, %{"step1" => _response}} ->
        {:input_required,
         elicitation_requests("step2", "Step 2: What is your favorite color?", "color"),
         %{"round" => 2}, state}

      {%{"round" => 2}, %{"step2" => _response}} ->
        {:ok, [%{type: "text", text: "Multi-round complete"}], state}

      _initial ->
        {:input_required, elicitation_requests("step1", "Step 1: What is your name?", "name"),
         %{"round" => 1}, state}
    end
  end

  def handle_call_tool("test_input_required_result_tampered_state", _args, state) do
    case Context.input_responses() do
      nil ->
        {:input_required, elicitation_requests("confirm", "Please confirm", "ok", "boolean"),
         %{"flow" => "tamper-check"}, state}

      _response ->
        {:ok, [%{type: "text", text: "State accepted"}], state}
    end
  end

  def handle_call_tool("test_input_required_result_capabilities", _args, state) do
    requests = %{
      "sample" => %{
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [
            %{
              "role" => "user",
              "content" => %{"type" => "text", "text" => "Capability check"}
            }
          ],
          "maxTokens" => 10
        }
      }
    }

    {:input_required, requests, %{"flow" => "capabilities"}, state}
  end

  def handle_call_tool("test_error_handling", _args, state),
    do: {:error, "This tool intentionally returns an error for testing", state}

  def handle_call_tool("test_streaming_elicitation", _args, state) do
    _ = Context.report_progress(50, 100)
    {:ok, [%{type: "text", text: "Streaming complete"}], state}
  end

  def handle_call_tool("test_logging_tool", _args, state) do
    _ = Context.send_log_message(:info, "Diagnostic trace logging activated")
    {:ok, [%{type: "text", text: "Logging evaluated"}], state}
  end

  def handle_call_tool(name, _args, state), do: {:error, "Unknown tool: #{name}", state}

  # ── Resources ────────────────────────────────────────────────

  @impl true
  def handle_list_resources(_cursor, state) do
    {:ok,
     [
       %{
         uri: "test://static-text",
         name: "Static Text Resource",
         description: "A static text resource",
         mimeType: "text/plain"
       },
       %{
         uri: "test://static-binary",
         name: "Static Binary Resource",
         description: "A static binary resource",
         mimeType: "image/png"
       },
       %{
         uri: "test://watched-resource",
         name: "Watched Resource",
         description: "A subscribable resource",
         mimeType: "text/plain"
       }
     ], nil, state}
  end

  @impl true
  def handle_read_resource("test://static-text", state),
    do:
      {:ok,
       [
         %{
           uri: "test://static-text",
           mimeType: "text/plain",
           text: "This is the content of the static text resource."
         }
       ], state}

  def handle_read_resource("test://static-binary", state),
    do:
      {:ok,
       [
         %{
           uri: "test://static-binary",
           mimeType: "image/png",
           blob: Application.get_env(:conformance, :test_image)
         }
       ], state}

  def handle_read_resource("test://watched-resource", state),
    do:
      {:ok,
       [
         %{
           uri: "test://watched-resource",
           mimeType: "text/plain",
           text: "Watched resource content"
         }
       ], state}

  def handle_read_resource("test://template/" <> rest, state) do
    id = rest |> String.split("/") |> List.first()

    {:ok,
     [
       %{
         uri: "test://template/#{id}/data",
         mimeType: "application/json",
         text: Jason.encode!(%{id: id, templateTest: true, data: "Data for ID: #{id}"})
       }
     ], state}
  end

  def handle_read_resource(uri, state) do
    error =
      Arbor.MCP.Error.protocol_error(
        Arbor.MCP.Protocol.ErrorCodes.resource_not_found("2026-07-28"),
        "Resource not found",
        %{"uri" => uri}
      )

    {:error, error, state}
  end

  @impl true
  def handle_list_resource_templates(_cursor, state) do
    {:ok,
     [
       %{
         uriTemplate: "test://template/{id}/data",
         name: "Resource Template",
         description: "A resource template",
         mimeType: "application/json"
       }
     ], nil, state}
  end

  @impl true
  def handle_subscribe_resource(uri, state),
    do: {:ok, %{state | subscriptions: MapSet.put(state.subscriptions, uri)}}

  @impl true
  def handle_unsubscribe_resource(uri, state),
    do: {:ok, %{state | subscriptions: MapSet.delete(state.subscriptions, uri)}}

  # ── Prompts ────────────────────────────────────────────────

  @impl true
  def handle_list_prompts(_cursor, state) do
    {:ok,
     [
       %{name: "test_simple_prompt", description: "A simple prompt without arguments"},
       %{
         name: "test_prompt_with_arguments",
         description: "A prompt with required arguments",
         arguments: [
           %{name: "arg1", description: "First argument", required: true},
           %{name: "arg2", description: "Second argument", required: true}
         ]
       },
       %{
         name: "test_prompt_with_embedded_resource",
         description: "A prompt with embedded resource",
         arguments: [%{name: "resourceUri", description: "URI of resource", required: true}]
       },
       %{name: "test_prompt_with_image", description: "A prompt with image content"},
       %{
         name: "test_input_required_result_prompt",
         description: "Prompt requiring client input"
       }
     ], nil, state}
  end

  @impl true
  def handle_get_prompt("test_simple_prompt", _args, state),
    do:
      {:ok,
       %{
         messages: [
           %{role: "user", content: %{type: "text", text: "This is a simple prompt for testing."}}
         ]
       }, state}

  def handle_get_prompt("test_prompt_with_arguments", args, state) do
    {:ok,
     %{
       messages: [
         %{
           role: "user",
           content: %{
             type: "text",
             text: "Prompt with arguments: arg1='#{args["arg1"]}', arg2='#{args["arg2"]}'"
           }
         }
       ]
     }, state}
  end

  def handle_get_prompt("test_prompt_with_embedded_resource", args, state) do
    uri = args["resourceUri"] || "test://embedded-resource"

    {:ok,
     %{
       messages: [
         %{
           role: "user",
           content: %{
             type: "resource",
             resource: %{
               uri: uri,
               mimeType: "text/plain",
               text: "Embedded resource content for testing."
             }
           }
         },
         %{
           role: "user",
           content: %{type: "text", text: "Please process the embedded resource above."}
         }
       ]
     }, state}
  end

  def handle_get_prompt("test_prompt_with_image", _args, state) do
    {:ok,
     %{
       messages: [
         %{
           role: "user",
           content: %{
             type: "image",
             data: Application.get_env(:conformance, :test_image),
             mimeType: "image/png"
           }
         },
         %{role: "user", content: %{type: "text", text: "Please analyze the image above."}}
       ]
     }, state}
  end

  def handle_get_prompt("test_input_required_result_prompt", _args, state) do
    case Context.input_responses() do
      %{"user_context" => %{"content" => %{"context" => context}}} ->
        {:ok,
         %{
           messages: [
             %{role: "user", content: %{type: "text", text: "Context: #{context}"}}
           ]
         }, state}

      _missing ->
        {:input_required,
         elicitation_requests("user_context", "What context should the prompt use?", "context"),
         %{"flow" => "prompt"}, state}
    end
  end

  def handle_get_prompt(name, _args, state), do: {:error, "Unknown prompt: #{name}", state}

  @impl true
  def handle_complete(_ref, _argument, state) do
    {:ok, %{completion: %{values: [], total: 0, hasMore: false}}, state}
  end

  defp json_schema_2020_12 do
    %{
      "$schema" => @json_schema_uri,
      "type" => "object",
      "$defs" => %{
        "address" => %{
          "$anchor" => "addressDef",
          "type" => "object",
          "properties" => %{
            "street" => %{"type" => "string"},
            "city" => %{"type" => "string"}
          }
        }
      },
      "properties" => %{
        "name" => %{"type" => "string"},
        "address" => %{"$ref" => "#/$defs/address"},
        "contactMethod" => %{"type" => "string", "enum" => ["phone", "email"]},
        "phone" => %{"type" => "string"},
        "email" => %{"type" => "string"}
      },
      "allOf" => [%{"anyOf" => [%{"required" => ["phone"]}, %{"required" => ["email"]}]}],
      "if" => %{
        "properties" => %{"contactMethod" => %{"const" => "phone"}},
        "required" => ["contactMethod"]
      },
      "then" => %{"required" => ["phone"]},
      "else" => %{"required" => ["email"]},
      "additionalProperties" => false
    }
  end

  defp mrtr_tools do
    for {name, description} <- [
          {"test_input_required_result_elicitation", "Tests elicitation input requests"},
          {"test_input_required_result_sampling", "Tests sampling input requests"},
          {"test_input_required_result_list_roots", "Tests roots input requests"},
          {"test_input_required_result_request_state", "Tests requestState round trips"},
          {"test_input_required_result_multiple_inputs", "Tests multiple input requests"},
          {"test_input_required_result_multi_round", "Tests multi-round input requests"},
          {"test_input_required_result_tampered_state", "Tests requestState integrity"},
          {"test_input_required_result_capabilities", "Tests client capability filtering"}
        ] do
      %{name: name, description: description, inputSchema: %{type: "object", properties: %{}}}
    end
  end

  defp elicitation_requests(id, message, property, type \\ "string") do
    %{
      id => %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => message,
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{property => %{"type" => type}},
            "required" => [property]
          }
        }
      }
    }
  end
end

# ── SSE Router (handles bidirectional tools) ─────────────────────

defmodule ConformanceRouter do
  @behaviour Plug
  import Plug.Conn
  require Logger

  alias Arbor.MCP.Plugs.DnsRebinding
  alias Arbor.MCP.Server.SSESession

  @sse_tools ~w(test_tool_with_logging test_tool_with_progress test_sampling test_elicitation test_elicitation_sep1034_defaults test_elicitation_sep1330_enums)

  # allowed_origins :any — this is a localhost-only conformance fixture; the
  # DnsRebinding plug above already pins the Host header to localhost names,
  # and HttpPlug no longer has a same-origin Origin fallback.
  @mcp_opts Arbor.MCP.HttpPlug.init(
              handler: ConformanceHandler,
              server_info: %{name: "mcp-conformance-test-server", version: "1.0.0"},
              protocol_mode: :prefer_modern,
              mrtr: true,
              request_state: [
                active_key_id: "conformance",
                keys: %{"conformance" => :binary.copy(<<42>>, 32)},
                ttl_seconds: 300
              ],
              sse_enabled: true,
              cors_enabled: true,
              allowed_origins: :any
            )

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    # DNS rebinding protection
    conn = DnsRebinding.call(conn, DnsRebinding.init([]))
    if conn.halted, do: conn, else: route(conn)
  end

  defp route(%{method: "POST"} = conn) do
    if modern_request?(conn) do
      Arbor.MCP.HttpPlug.call(conn, @mcp_opts)
    else
      route_legacy_post(conn)
    end
  end

  defp route_legacy_post(conn) do
    {:ok, body, conn} = read_body(conn)

    case Jason.decode(body) do
      {:ok, %{"method" => "tools/call", "params" => %{"name" => name}, "id" => id} = req}
      when name in @sse_tools ->
        handle_sse_tool(conn, name, id, req)

      {:ok, %{"id" => id, "result" => result}} when not is_nil(id) ->
        SSESession.handle_response(id, {:ok, result})
        conn |> put_resp_header("mcp-session-id", session_id(conn)) |> send_resp(202, "")

      {:ok, %{"id" => id, "error" => error}} when not is_nil(id) ->
        SSESession.handle_response(id, {:error, error})
        conn |> put_resp_header("mcp-session-id", session_id(conn)) |> send_resp(202, "")

      _ ->
        handle_normal_post(conn, body)
    end
  end

  defp modern_request?(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [version] -> version == "2026-07-28" or version not in Arbor.MCP.supported_versions()
      _other -> false
    end
  end

  defp route(%{method: "GET"} = conn) do
    if Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "text/event-stream")) do
      sid = session_id(conn)
      SSESession.register_sse_stream(sid)

      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("mcp-session-id", sid)
      |> send_chunked(200)
      |> then(&SSESession.run_sse_loop(&1, sid))
    else
      Arbor.MCP.HttpPlug.call(conn, @mcp_opts)
    end
  end

  defp route(conn), do: Arbor.MCP.HttpPlug.call(conn, @mcp_opts)

  defp handle_normal_post(conn, body) do
    case Jason.decode(body) do
      {:ok, request} ->
        sid = session_id(conn)
        mcp_conn = Arbor.MCP.MessageProcessor.new(request, transport: :http)

        processed =
          Arbor.MCP.MessageProcessor.process(mcp_conn, %{
            handler: ConformanceHandler,
            server_info: %{name: "mcp-conformance-test-server", version: "1.0.0"}
          })

        req_id = request["id"]

        case processed.response do
          nil when req_id == nil ->
            conn |> put_resp_header("mcp-session-id", sid) |> send_resp(202, "")

          nil ->
            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("mcp-session-id", sid)
            |> send_resp(
              500,
              Jason.encode!(%{
                jsonrpc: "2.0",
                error: %{code: -32603, message: "No response"},
                id: request["id"]
              })
            )

          response ->
            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("mcp-session-id", sid)
            |> put_resp_header("mcp-protocol-version", "2025-11-25")
            |> send_resp(200, Jason.encode!(response))
        end

      {:error, _} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{jsonrpc: "2.0", error: %{code: -32700, message: "Parse error"}})
        )
    end
  end

  # ── SSE Tool Handlers ────────────────────────────────────────

  defp handle_sse_tool(conn, name, id, req) do
    # Prefer client-supplied session id so POST tools/call matches GET SSE.
    # If the header is missing, wait for the sole live SSE stream (POST-before-GET race).
    case resolve_sse_session_id(conn) do
      {:ok, sid} ->
        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("mcp-session-id", sid)
          |> send_chunked(200)

        do_sse_tool(conn, name, id, req, sid)

      {:error, reason} ->
        Logger.warning(
          "SSE stream not ready for tool=#{name} reason=#{inspect(reason)}; " <>
            "bidirectional request would fail"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: id,
            result: %{
              content: [
                %{
                  type: "text",
                  text: "Error: no SSE stream (#{inspect(reason)}) for tool #{name}"
                }
              ],
              isError: true
            }
          })
        )
    end
  end

  defp do_sse_tool(conn, "test_tool_with_logging", id, _req, _sid) do
    for msg <- ["Tool execution started", "Tool processing data", "Tool execution completed"] do
      sse_event(conn, %{
        jsonrpc: "2.0",
        method: "notifications/message",
        params: %{level: "info", logger: "conformance-test-server", data: msg}
      })

      Process.sleep(50)
    end

    sse_event(conn, %{
      jsonrpc: "2.0",
      id: id,
      result: %{content: [%{type: "text", text: "Tool with logging executed successfully"}]}
    })

    conn
  end

  defp do_sse_tool(conn, "test_tool_with_progress", id, req, _sid) do
    token = get_in(req, ["params", "_meta", "progressToken"]) || 0

    for {p, t} <- [{0, 100}, {50, 100}, {100, 100}] do
      sse_event(conn, %{
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: %{
          progressToken: token,
          progress: p,
          total: t,
          message: "Completed step #{p} of #{t}"
        }
      })

      Process.sleep(50)
    end

    sse_event(conn, %{
      jsonrpc: "2.0",
      id: id,
      result: %{content: [%{type: "text", text: "#{token}"}]}
    })

    conn
  end

  defp do_sse_tool(conn, "test_sampling", id, req, sid) do
    prompt = get_in(req, ["params", "arguments", "prompt"]) || "Test prompt"

    case SSESession.send_request(sid, "sampling/createMessage", %{
           messages: [%{role: "user", content: %{type: "text", text: prompt}}],
           maxTokens: 100
         }) do
      {:ok, result} ->
        text =
          get_in(result, ["content", "text"]) || get_in(result, ["message", "content", "text"]) ||
            "No response"

        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{content: [%{type: "text", text: "LLM response: #{text}"}]}
        })

      {:error, reason} ->
        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{content: [%{type: "text", text: "Sampling error: #{inspect(reason)}"}]}
        })
    end

    conn
  end

  defp do_sse_tool(conn, "test_elicitation", id, req, sid) do
    message = get_in(req, ["params", "arguments", "message"]) || "Please provide info"

    case SSESession.send_request(sid, "elicitation/create", %{
           message: message,
           requestedSchema: %{
             type: "object",
             properties: %{response: %{type: "string", description: "User's response"}},
             required: ["response"]
           }
         }) do
      {:ok, result} ->
        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{
            content: [
              %{
                type: "text",
                text:
                  "User response: action=#{result["action"]}, content=#{Jason.encode!(result["content"] || %{})}"
              }
            ]
          }
        })

      {:error, reason} ->
        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{content: [%{type: "text", text: "Elicitation error: #{inspect(reason)}"}]}
        })
    end

    conn
  end

  defp do_sse_tool(conn, "test_elicitation_sep1034_defaults", id, _req, sid) do
    schema = %{
      type: "object",
      properties: %{
        name: %{type: "string", description: "User name", default: "John Doe"},
        age: %{type: "integer", description: "User age", default: 30},
        score: %{type: "number", description: "User score", default: 95.5},
        status: %{
          type: "string",
          description: "User status",
          enum: ["active", "inactive", "pending"],
          default: "active"
        },
        verified: %{type: "boolean", description: "Verification status", default: true}
      },
      required: []
    }

    case SSESession.send_request(sid, "elicitation/create", %{
           message: "Please review and update the form fields with defaults",
           requestedSchema: schema
         }) do
      {:ok, result} ->
        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{
            content: [
              %{
                type: "text",
                text:
                  "Elicitation completed: action=#{result["action"]}, content=#{Jason.encode!(result["content"] || %{})}"
              }
            ]
          }
        })

      {:error, reason} ->
        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
        })
    end

    conn
  end

  defp do_sse_tool(conn, "test_elicitation_sep1330_enums", id, _req, sid) do
    schema = %{
      type: "object",
      properties: %{
        untitledSingle: %{
          type: "string",
          description: "Select one option",
          enum: ["option1", "option2", "option3"]
        },
        titledSingle: %{
          type: "string",
          description: "Select one with titles",
          oneOf: [
            %{const: "value1", title: "First Option"},
            %{const: "value2", title: "Second Option"},
            %{const: "value3", title: "Third Option"}
          ]
        },
        legacyEnum: %{
          type: "string",
          description: "Select one (legacy)",
          enum: ["opt1", "opt2", "opt3"],
          enumNames: ["Option One", "Option Two", "Option Three"]
        },
        untitledMulti: %{
          type: "array",
          description: "Select multiple",
          minItems: 1,
          maxItems: 3,
          items: %{type: "string", enum: ["option1", "option2", "option3"]}
        },
        titledMulti: %{
          type: "array",
          description: "Select multiple with titles",
          minItems: 1,
          maxItems: 3,
          items: %{
            anyOf: [
              %{const: "value1", title: "First Choice"},
              %{const: "value2", title: "Second Choice"},
              %{const: "value3", title: "Third Choice"}
            ]
          }
        }
      },
      required: []
    }

    case SSESession.send_request(sid, "elicitation/create", %{
           message: "Please select options from the enum fields",
           requestedSchema: schema
         }) do
      {:ok, result} ->
        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{
            content: [
              %{
                type: "text",
                text:
                  "Elicitation completed: action=#{result["action"]}, content=#{Jason.encode!(result["content"] || %{})}"
              }
            ]
          }
        })

      {:error, reason} ->
        sse_event(conn, %{
          jsonrpc: "2.0",
          id: id,
          result: %{content: [%{type: "text", text: "Error: #{inspect(reason)}"}]}
        })
    end

    conn
  end

  defp sse_event(conn, data),
    do: Plug.Conn.chunk(conn, "event: message\ndata: #{Jason.encode!(data)}\n\n")

  # Session id for ordinary requests: honor header or mint a stable-looking id.
  defp session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [sid | _] when is_binary(sid) and sid != "" -> sid
      _ -> "session-#{System.unique_integer([:positive])}"
    end
  end

  # Bidirectional tools MUST share the GET SSE session id.
  defp resolve_sse_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [sid | _] when is_binary(sid) and sid != "" ->
        case SSESession.await_sse_stream(sid, 3_000) do
          :ok -> {:ok, sid}
          {:error, :timeout} -> {:error, {:no_sse_stream, sid}}
        end

      _ ->
        case SSESession.await_sole_live_session_id(3_000) do
          {:ok, sid} -> {:ok, sid}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end

# ── Start Server ─────────────────────────────────────────────────

port = String.to_integer(List.first(System.argv(), "3001"))
IO.puts("Starting Arbor.MCP conformance server on port #{port}...")

# Create the SSE session table once, owned by this long-lived script process.
# Creating it lazily from request processes raced concurrent first requests
# (server-sse-multiple-streams) and tied the table's life to a single request.
Arbor.MCP.Server.SSESession.init()

children = [{Plug.Cowboy, scheme: :http, plug: ConformanceRouter, options: [port: port]}]
{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("Server ready on http://localhost:#{port}/mcp")
Process.sleep(:infinity)
