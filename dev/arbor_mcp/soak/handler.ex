defmodule Arbor.MCP.Soak.Handler do
  @moduledoc false

  use Arbor.MCP.Server.Handler

  alias Arbor.MCP.Server.Context

  @impl true
  def handle_list_tools(_cursor, state) do
    tools =
      for name <- ["echo", "progress", "hold", "onboard", "notify"] do
        %{name: name, description: "Soak #{name}", inputSchema: %{type: "object"}}
      end

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool("echo", %{"value" => value}, state) do
    {:ok, %{content: [%{type: "text", text: value}]}, state}
  end

  def handle_call_tool("progress", _args, state) do
    :ok = report_progress(1, 2)
    :ok = report_progress(2, 2)
    {:ok, %{content: [%{type: "text", text: "progress complete"}]}, state}
  end

  def handle_call_tool("hold", _args, state) do
    :ok = report_progress(1, 2)

    receive do
      {:arbor_mcp_cancelled, _token, _reason} ->
        {:ok, %{content: [%{type: "text", text: "cancelled"}]}, state}
    after
      2_000 -> {:ok, %{content: [%{type: "text", text: "expired"}]}, state}
    end
  end

  def handle_call_tool("onboard", _args, state) do
    case Context.input_responses() do
      nil ->
        requests = %{
          "name" => %{
            "method" => "elicitation/create",
            "params" => %{
              "message" => "Soak name?",
              "requestedSchema" => %{"type" => "object", "properties" => %{}}
            }
          }
        }

        {:input_required, requests, %{"prefix" => "hello"}, state}

      %{"name" => %{"content" => %{"name" => name}}} ->
        {:ok, %{content: [%{type: "text", text: "hello #{name}"}]}, state}
    end
  end

  def handle_call_tool("notify", _args, state) do
    result = Arbor.MCP.Server.notify_tools_changed(self())
    {:ok, %{content: [%{type: "text", text: inspect(result)}]}, state}
  end

  defp report_progress(progress, total) do
    case Context.report_progress(progress, total) do
      {:error, :request_not_streaming} ->
        Arbor.MCP.Server.notify_progress(self(), Context.progress_token(), progress, total)

      result ->
        result
    end
  end

  @impl true
  def handle_list_resources(_cursor, state) do
    {:ok, [%{uri: "soak://fixed", name: "Fixed soak resource"}], nil, state}
  end

  @impl true
  def handle_list_resource_templates(_cursor, state) do
    {:ok, [%{uriTemplate: "soak://item/{id}", name: "Soak item"}], nil, state}
  end

  @impl true
  def handle_read_resource(uri, state) do
    if uri == "soak://fixed" or String.starts_with?(uri, "soak://item/") do
      {:ok, [%{uri: uri, mimeType: "text/plain", text: "soak #{uri}"}], state}
    else
      {:error, "unknown resource", state}
    end
  end

  @impl true
  def handle_list_prompts(_cursor, state) do
    {:ok, [%{name: "greet", description: "Soak greeting"}], nil, state}
  end

  @impl true
  def handle_get_prompt("greet", %{"name" => name}, state) do
    {:ok, %{messages: [%{role: "user", content: %{type: "text", text: "Hi #{name}"}}]}, state}
  end

  @impl true
  def handle_subscribe_resource("soak://fixed", state), do: {:ok, %{}, state}

  @impl true
  def handle_unsubscribe_resource("soak://fixed", state), do: {:ok, %{}, state}
end
