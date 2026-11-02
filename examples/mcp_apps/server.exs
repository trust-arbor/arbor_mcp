defmodule Arbor.MCP.Examples.McpApps do
  @moduledoc false
  use Arbor.MCP.Server.Handler

  alias Arbor.MCP.{Apps, Error}
  alias Arbor.MCP.Server.Context

  @uri "ui://arbor/plan.html"
  @schema %{
    "type" => "object",
    "properties" => %{
      "seats" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
      "storageGb" => %{"type" => "integer", "minimum" => 0, "maximum" => 2000}
    },
    "additionalProperties" => false
  }
  @policy %{
    "csp" => %{
      "connectDomains" => [],
      "resourceDomains" => [],
      "frameDomains" => [],
      "baseUriDomains" => []
    },
    "prefersBorder" => false
  }

  # Static discovery metadata for this raw Handler. The Server DSL generates
  # these declarations automatically when using tool/resource blocks.
  @doc false
  def __server_info__, do: %{name: "arbor-mcp-apps", version: "1.0.0"}
  @doc false
  def __server_capabilities__, do: %{tools: %{}, resources: %{}}

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :view_path, Path.join(__DIR__, "dist/view.html"))

    with {:ok, html} <- File.read(path),
         {:ok, main} <-
           Apps.tool(
             %{
               "name" => "plan",
               "description" =>
                 "Estimate a monthly workspace plan with an interactive pricing view.",
               "inputSchema" => @schema
             },
             %{"resourceUri" => @uri}
           ),
         {:ok, update} <-
           Apps.tool(
             %{
               "name" => "update_plan",
               "description" => "Recalculate the displayed plan.",
               "inputSchema" => @schema
             },
             %{"visibility" => ["app"]}
           ),
         {:ok, resource} <-
           Apps.resource(
             %{
               "uri" => @uri,
               "name" => "Workspace plan",
               "description" => "Interactive illustrative pricing calculator"
             },
             @policy
           ),
         {:ok, policy} <-
           Apps.tool(
             %{
               "name" => "plan_policy",
               "description" => "Read the model-facing notes about this pricing example.",
               "inputSchema" => %{"type" => "object", "properties" => %{}}
             },
             %{"visibility" => ["model"]}
           ),
         :ok <- Apps.validate_catalog([main, update, policy], [resource]),
         {:ok, content} <- Apps.html(@uri, html, @policy) do
      {:ok,
       %{
         tools: [main, update, policy],
         resources: [resource],
         content: content,
         legacy_capabilities: %{}
       }}
    else
      {:error, :enoent} -> {:error, :build_view_first}
      error -> error
    end
  end

  # The example runs with execution: :stateful. Legacy capabilities belong to
  # an initialized connection/session, whereas modern capabilities belong to
  # the current request. Never share one client's profile with another.
  @impl true
  def handle_initialize(params, state) do
    key = legacy_key()

    if map_size(state.legacy_capabilities) < 16 or Map.has_key?(state.legacy_capabilities, key) do
      result = %{
        serverInfo: %{name: "arbor-mcp-apps", version: "1.0.0"},
        capabilities: %{tools: %{}, resources: %{}}
      }

      capabilities = Map.get(params, "capabilities", %{})
      {:ok, result, put_in(state.legacy_capabilities[key], capabilities)}
    else
      {:error, %{code: -32000, message: "Example legacy connection limit reached"}, state}
    end
  end

  @impl true
  def handle_list_tools(_cursor, state) do
    capabilities =
      case Context.current() do
        %{era: :modern, client_capabilities: capabilities} -> capabilities || %{}
        %{era: :legacy} -> Map.get(state.legacy_capabilities, legacy_key(), %{})
        _outside_request -> %{}
      end

    {:ok, tools} = Apps.tools_for_client(state.tools, capabilities)
    {:ok, tools, nil, state}
  end

  @impl true
  def handle_get_tool(name, state),
    do: {:ok, Enum.find(state.tools, &(&1["name"] == name)), state}

  @impl true
  def handle_call_tool(name, arguments, state) when name in ["plan", "update_plan"] do
    seats = Map.get(arguments, "seats", 8)
    storage = Map.get(arguments, "storageGb", 100)

    if is_integer(seats) and seats in 1..50 and is_integer(storage) and storage in 0..2000 do
      total = seats * 1800 + storage * 20

      text =
        "#{seats} seats and #{storage} GB storage: $#{div(total, 100)}.#{String.pad_leading(Integer.to_string(rem(total, 100)), 2, "0")} per month. Illustrative pricing; nothing is purchased."

      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => text}],
         "structuredContent" => %{"seats" => seats, "storageGb" => storage, "totalCents" => total},
         "_meta" => %{"example/viewLabel" => "Local estimate"}
       }, state}
    else
      {:error, Error.protocol_error(-32602, "Plan inputs are outside the supported range"), state}
    end
  end

  def handle_call_tool("plan_policy", _arguments, state),
    do:
      {:ok,
       %{
         "content" => [
           %{
             "type" => "text",
             "text" =>
               "Illustrative pricing only; this example does not purchase or store a plan."
           }
         ]
       }, state}

  def handle_call_tool(_name, _arguments, state),
    do: {:error, Error.protocol_error(-32602, "Unknown tool"), state}

  @impl true
  def handle_list_resources(_cursor, state), do: {:ok, state.resources, nil, state}

  @impl true
  def handle_read_resource(@uri, state), do: {:ok, [state.content], state}

  def handle_read_resource(_uri, state),
    do: {:error, Error.protocol_error(-32002, "Resource not found"), state}

  defp legacy_key do
    case Context.session_id() do
      nil -> {:connection, Context.scope()}
      session -> {:session, session}
    end
  end
end
