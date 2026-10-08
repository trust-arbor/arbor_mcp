defmodule Arbor.MCP.Compliance.IconsTest do
  @moduledoc """
  Compliance tests for icons support in MCP 2025-11-25.

  Verifies that tools, resources, and prompts defined with the server DSL
  correctly include icon metadata, and that definitions without icons do not
  include the icons key.
  """

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage
  use ExUnit.Case, async: true

  @moduletag :compliance

  defmodule ToolWithIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "wrench_tool", "A tool with an emoji icon" do
      icons([%{src: "\u{1F527}"}])

      input_schema(%{
        type: "object",
        properties: %{input: %{type: "string"}},
        required: ["input"]
      })

      run(fn %{input: input}, state ->
        {:ok, %{text: "Processed: #{input}"}, state}
      end)
    end
  end

  defmodule ToolWithMultipleIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "multi_icon_tool", "A tool with multiple icon types" do
      icons([
        %{src: "\u{1F4E6}"},
        %{src: "https://example.com/tool-icon.svg", mimeType: "image/svg+xml"}
      ])

      input_schema(%{
        type: "object",
        properties: %{data: %{type: "string"}},
        required: ["data"]
      })

      run(fn _params, state -> {:ok, %{text: "done"}, state} end)
    end
  end

  defmodule ToolWithoutIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "plain_tool", "A tool with no icons defined" do
      input_schema(%{
        type: "object",
        properties: %{value: %{type: "string"}},
        required: ["value"]
      })

      run(fn _params, state -> {:ok, %{text: "ok"}, state} end)
    end
  end

  defmodule ResourceWithIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    resource "config://app/database", "Database configuration resource" do
      name("Database Config")
      mime_type("application/json")
      icons([%{src: "\u{1F5C4}\u{FE0F}"}])

      read(fn _params, state -> {:ok, %{json: %{host: "localhost"}}, state} end)
    end
  end

  defmodule ResourceWithSvgIcon do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    resource "file:///data/report.csv", "CSV report data resource" do
      name("Report Data")
      mime_type("text/csv")

      icons([
        %{src: "https://example.com/csv-icon.svg", mimeType: "image/svg+xml"}
      ])

      read(fn _params, state -> {:ok, "col1,col2\nval1,val2", state} end)
    end
  end

  defmodule ResourceWithoutIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    resource "config://app/settings", "Application settings without icons" do
      name("App Settings")
      mime_type("application/json")

      read(fn _params, state -> {:ok, %{json: %{debug: false}}, state} end)
    end
  end

  defmodule PromptWithIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    prompt "code_review", "Review code for best practices" do
      title("Code Review")
      icons([%{src: "\u{1F50D}"}])
      arg(:code, required: true, description: "Code to review")

      render(fn %{code: code}, state ->
        {:ok, %{messages: [%{role: "user", content: %{type: "text", text: "Review: #{code}"}}]},
         state}
      end)
    end
  end

  defmodule PromptWithMultipleIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    prompt "summarize", "Summarize text content" do
      title("Summarizer")

      icons([
        %{src: "\u{1F4DD}"},
        %{src: "https://example.com/summarize.png", mimeType: "image/png"}
      ])

      arg(:text, required: true, description: "Text to summarize")
      arg(:max_length, description: "Maximum summary length")

      render(fn _params, state ->
        {:ok, %{messages: [%{role: "user", content: %{type: "text", text: "Summarize this"}}]},
         state}
      end)
    end
  end

  defmodule PromptWithoutIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    prompt "greeting", "A simple greeting prompt without icons" do
      title("Greeting")

      render(fn _params, state ->
        {:ok, %{messages: [%{role: "user", content: %{type: "text", text: "Hello!"}}]}, state}
      end)
    end
  end

  defmodule ServerWithMixedIcons do
    use Arbor.MCP.Server.Handler
    use Arbor.MCP.Server.DSL

    tool "icon_tool", "Tool with icon" do
      icons([%{src: "\u{2699}\u{FE0F}"}])
      input_schema(%{type: "object", properties: %{x: %{type: "string"}}})
      run(fn _params, state -> {:ok, %{text: "ok"}, state} end)
    end

    tool "no_icon_tool", "Tool without icon" do
      input_schema(%{type: "object", properties: %{y: %{type: "string"}}})
      run(fn _params, state -> {:ok, %{text: "ok"}, state} end)
    end

    resource "res://with-icon", "Resource with icon" do
      name("With Icon")
      icons([%{src: "\u{1F4C1}"}])
      read(fn _params, state -> {:ok, "data", state} end)
    end

    resource "res://without-icon", "Resource without icon" do
      name("Without Icon")
      read(fn _params, state -> {:ok, "data", state} end)
    end

    prompt "icon_prompt", "Prompt with icon" do
      title("Icon Prompt")
      icons([%{src: "\u{1F4AC}"}])
      render(fn _params, state -> {:ok, %{messages: []}, state} end)
    end

    prompt "no_icon_prompt", "Prompt without icon" do
      title("No Icon Prompt")
      render(fn _params, state -> {:ok, %{messages: []}, state} end)
    end
  end

  describe "tool icons compliance" do
    test "tool defined with icons macro has icons in metadata" do
      tool = tool!(ToolWithIcons, "wrench_tool")

      assert Map.has_key?(tool, :icons)
      assert is_list(tool.icons)
      assert length(tool.icons) == 1

      [icon] = tool.icons
      assert icon.src == "\u{1F527}"
    end

    test "tool with multiple icon types has all icons in metadata" do
      tool = tool!(ToolWithMultipleIcons, "multi_icon_tool")

      assert Map.has_key?(tool, :icons)
      assert is_list(tool.icons)
      assert length(tool.icons) == 2

      emoji_icon = Enum.find(tool.icons, &(&1.src == "\u{1F4E6}"))
      assert emoji_icon != nil

      svg_icon = Enum.find(tool.icons, &(&1.src == "https://example.com/tool-icon.svg"))
      assert svg_icon != nil
      assert svg_icon.mimeType == "image/svg+xml"
    end

    test "tool without icons macro does not have icons key" do
      tool = tool!(ToolWithoutIcons, "plain_tool")

      refute Map.has_key?(tool, :icons)
    end

    test "tool with icons still has all other required fields" do
      tool = tool!(ToolWithIcons, "wrench_tool")

      assert tool.name == "wrench_tool"
      assert tool.description == "A tool with an emoji icon"
      assert is_map(tool.inputSchema)
      assert tool.inputSchema.type == "object"
    end
  end

  describe "resource icons compliance" do
    test "resource defined with icons macro has icons in metadata" do
      resource = resource!(ResourceWithIcons, "config://app/database")

      assert Map.has_key?(resource, :icons)
      assert is_list(resource.icons)
      assert length(resource.icons) == 1

      [icon] = resource.icons
      assert icon.src == "\u{1F5C4}\u{FE0F}"
    end

    test "resource with SVG icon has correct icon metadata" do
      resource = resource!(ResourceWithSvgIcon, "file:///data/report.csv")

      assert Map.has_key?(resource, :icons)
      assert is_list(resource.icons)
      assert length(resource.icons) == 1

      [icon] = resource.icons
      assert icon.src == "https://example.com/csv-icon.svg"
      assert icon.mimeType == "image/svg+xml"
    end

    test "resource without icons macro does not have icons key" do
      resource = resource!(ResourceWithoutIcons, "config://app/settings")

      refute Map.has_key?(resource, :icons)
    end

    test "resource with icons still has all other required fields" do
      resource = resource!(ResourceWithIcons, "config://app/database")

      assert resource.name == "Database Config"
      assert resource.description == "Database configuration resource"
      assert resource.uri == "config://app/database"
      assert resource.mimeType == "application/json"
    end
  end

  describe "prompt icons compliance" do
    test "prompt defined with icons macro has icons in metadata" do
      prompt = prompt!(PromptWithIcons, "code_review")

      assert Map.has_key?(prompt, :icons)
      assert is_list(prompt.icons)
      assert length(prompt.icons) == 1

      [icon] = prompt.icons
      assert icon.src == "\u{1F50D}"
    end

    test "prompt with multiple icon types has all icons in metadata" do
      prompt = prompt!(PromptWithMultipleIcons, "summarize")

      assert Map.has_key?(prompt, :icons)
      assert is_list(prompt.icons)
      assert length(prompt.icons) == 2

      emoji_icon = Enum.find(prompt.icons, &(&1.src == "\u{1F4DD}"))
      assert emoji_icon != nil

      png_icon = Enum.find(prompt.icons, &(&1.src == "https://example.com/summarize.png"))
      assert png_icon != nil
      assert png_icon.mimeType == "image/png"
    end

    test "prompt without icons macro does not have icons key" do
      prompt = prompt!(PromptWithoutIcons, "greeting")

      refute Map.has_key?(prompt, :icons)
    end

    test "prompt with icons still has all other required fields" do
      prompt = prompt!(PromptWithIcons, "code_review")

      assert prompt.name == "code_review"
      assert prompt.title == "Code Review"
      assert prompt.description == "Review code for best practices"
      assert is_list(prompt.arguments)
      assert length(prompt.arguments) == 1
    end
  end

  describe "mixed icons in a single server" do
    test "tools with and without icons coexist correctly" do
      tools = tools(ServerWithMixedIcons)

      icon_tool = tools["icon_tool"]
      assert Map.has_key?(icon_tool, :icons)
      assert length(icon_tool.icons) == 1
      assert hd(icon_tool.icons).src == "\u{2699}\u{FE0F}"

      no_icon_tool = tools["no_icon_tool"]
      refute Map.has_key?(no_icon_tool, :icons)
    end

    test "resources with and without icons coexist correctly" do
      resources = resources(ServerWithMixedIcons)

      icon_resource = resources["res://with-icon"]
      assert Map.has_key?(icon_resource, :icons)
      assert length(icon_resource.icons) == 1
      assert hd(icon_resource.icons).src == "\u{1F4C1}"

      no_icon_resource = resources["res://without-icon"]
      refute Map.has_key?(no_icon_resource, :icons)
    end

    test "prompts with and without icons coexist correctly" do
      prompts = prompts(ServerWithMixedIcons)

      icon_prompt = prompts["icon_prompt"]
      assert Map.has_key?(icon_prompt, :icons)
      assert length(icon_prompt.icons) == 1
      assert hd(icon_prompt.icons).src == "\u{1F4AC}"

      no_icon_prompt = prompts["no_icon_prompt"]
      refute Map.has_key?(no_icon_prompt, :icons)
    end
  end

  describe "icon structure validation" do
    test "emoji icon has required src field" do
      [icon] = tool!(ToolWithIcons, "wrench_tool").icons

      assert Map.has_key?(icon, :src)
      refute Map.has_key?(icon, :type)
      refute Map.has_key?(icon, :uri)
      assert icon.src == "\u{1F527}"
    end

    test "URL-based icon has src and mimeType fields" do
      svg_icon =
        ToolWithMultipleIcons
        |> tool!("multi_icon_tool")
        |> Map.fetch!(:icons)
        |> Enum.find(&String.starts_with?(&1.src, "https://"))

      assert Map.has_key?(svg_icon, :src)
      assert Map.has_key?(svg_icon, :mimeType)
      refute Map.has_key?(svg_icon, :type)
      refute Map.has_key?(svg_icon, :uri)
      refute Map.has_key?(svg_icon, :mediaType)
      assert String.starts_with?(svg_icon.src, "https://")
      assert svg_icon.mimeType == "image/svg+xml"
    end

    test "icons list is always a list when present" do
      assert is_list(tool!(ToolWithIcons, "wrench_tool").icons)
      assert is_list(resource!(ResourceWithIcons, "config://app/database").icons)
      assert is_list(prompt!(PromptWithIcons, "code_review").icons)
    end

    test "icon with sizes field includes size descriptors" do
      # Sizes field per MCP 2025-11-25 spec: string array like ["48x48", "96x96", "any"]
      icon = %{
        src: "https://example.com/icon.png",
        mimeType: "image/png",
        sizes: ["48x48", "96x96"]
      }

      assert icon.src == "https://example.com/icon.png"
      assert icon.mimeType == "image/png"
      assert icon.sizes == ["48x48", "96x96"]
      assert is_list(icon.sizes)
      assert Enum.all?(icon.sizes, &is_binary/1)
    end
  end

  defp tool!(module, name), do: Map.fetch!(tools(module), name)
  defp resource!(module, uri), do: Map.fetch!(resources(module), uri)
  defp prompt!(module, name), do: Map.fetch!(prompts(module), name)

  defp tools(module) do
    {:ok, tools, nil, %{}} = module.handle_list_tools(nil, %{})
    Map.new(tools, &{&1.name, &1})
  end

  defp resources(module) do
    {:ok, resources, nil, %{}} = module.handle_list_resources(nil, %{})
    Map.new(resources, &{&1.uri, &1})
  end

  defp prompts(module) do
    {:ok, prompts, nil, %{}} = module.handle_list_prompts(nil, %{})
    Map.new(prompts, &{&1.name, &1})
  end
end
