#!/usr/bin/env elixir

# Sandboxed file manager MCP server using the modern Arbor.MCP Handler + DSL API.

Mix.install([
  {:arbor_mcp, path: Path.expand("..", __DIR__)}
])

defmodule FileManager do
  use Arbor.MCP.Server.Handler
  use Arbor.MCP.Server.DSL, name: "file-manager", version: "1.0.0"

  @impl true
  def init(args) do
    root_dir =
      args
      |> Keyword.get_lazy(:root_dir, &default_root_dir/0)
      |> Path.expand()

    File.mkdir_p!(root_dir)
    {:ok, %{root_dir: root_dir}}
  end

  tool "list_files", "Lists files under the sandbox root" do
    title("List Files")
    param(:path, :string, default: ".")
    param(:recursive, :boolean, default: false)

    run(fn %{path: path, recursive: recursive}, state ->
      with {:ok, full_path} <- safe_path(state.root_dir, path),
           {:ok, files} <- list_files(full_path, state.root_dir, recursive) do
        # ToolResult is aliased by `use Arbor.MCP.Server.DSL`
        {:ok,
         ToolResult.structured("Found #{length(files)} entries.", %{
           root: state.root_dir,
           path: path,
           files: files
         }), state}
      else
        {:error, reason} -> {:error, reason, state}
      end
    end)
  end

  tool "read_file", "Reads a text file from the sandbox" do
    title("Read File")
    param(:path, :string, required: true)

    run(fn %{path: path}, state ->
      with {:ok, full_path} <- safe_path(state.root_dir, path),
           {:ok, content} <- File.read(full_path) do
        {:ok, content, state}
      else
        {:error, reason} -> {:error, "Could not read #{path}: #{inspect(reason)}", state}
      end
    end)
  end

  tool "write_file", "Writes a text file inside the sandbox" do
    title("Write File")
    param(:path, :string, required: true)
    param(:content, :string, required: true)
    param(:mode, :string, default: "write", description: "write, append, or create")

    run(fn %{path: path, content: content, mode: mode}, state ->
      with {:ok, full_path} <- safe_path(state.root_dir, path),
           :ok <- File.mkdir_p(Path.dirname(full_path)),
           :ok <- write_file(full_path, content, mode) do
        {:ok, "Wrote #{path}.", state}
      else
        {:error, reason} -> {:error, "Could not write #{path}: #{inspect(reason)}", state}
      end
    end)
  end

  tool "file_info", "Returns metadata for a sandboxed file" do
    title("File Info")
    param(:path, :string, required: true)

    run(fn %{path: path}, state ->
      with {:ok, full_path} <- safe_path(state.root_dir, path),
           {:ok, info} <- file_info(full_path, state.root_dir) do
        {:ok, ToolResult.structured("Metadata for #{path}.", info), state}
      else
        {:error, reason} -> {:error, "Could not inspect #{path}: #{inspect(reason)}", state}
      end
    end)
  end

  resource_template "file:///{path}", "Reads a text file from the sandbox" do
    title("Sandbox File")
    mime_type("text/plain")
    param(:path, :string)

    read(fn %{path: path, uri: uri}, state ->
      with {:ok, full_path} <- safe_path(state.root_dir, path),
           {:ok, content} <- File.read(full_path) do
        {:ok, %{uri: uri, text: content}, state}
      else
        {:error, reason} -> {:error, "Could not read #{path}: #{inspect(reason)}", state}
      end
    end)
  end

  resource_template "file-metadata:///{path}", "Returns file metadata as JSON" do
    title("File Metadata")
    mime_type("application/json")
    param(:path, :string)

    read(fn %{path: path, uri: uri}, state ->
      with {:ok, full_path} <- safe_path(state.root_dir, path),
           {:ok, info} <- file_info(full_path, state.root_dir) do
        {:ok, %{uri: uri, text: Jason.encode!(info)}, state}
      else
        {:error, reason} -> {:error, "Could not inspect #{path}: #{inspect(reason)}", state}
      end
    end)
  end

  prompt "organize_files", "Creates a file organization prompt" do
    title("Organize Files")
    arg(:directory, required: true)
    arg(:strategy)

    render(fn %{directory: directory} = args, state ->
      strategy = Map.get(args, :strategy, "by type and purpose")

      {:ok,
       %{
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: "Suggest a #{strategy} organization plan for #{directory}."
             }
           }
         ]
       }, state}
    end)
  end

  defp default_root_dir do
    root = Path.join(System.tmp_dir!(), "ex_mcp_file_manager_example")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "readme.txt"), "Welcome to the File Manager example.\n")
    root
  end

  defp safe_path(root_dir, requested_path) do
    root = Path.expand(root_dir)
    path = Path.expand(Path.join(root, requested_path))

    if path == root or String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      {:error, :outside_root}
    end
  end

  defp list_files(path, root, false) do
    with {:ok, entries} <- File.ls(path) do
      files =
        entries
        |> Enum.map(&Path.join(path, &1))
        |> Enum.map(&file_summary(&1, root))

      {:ok, files}
    end
  end

  defp list_files(path, root, true) do
    files =
      path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.map(&file_summary(&1, root))

    {:ok, files}
  end

  defp file_summary(path, root) do
    {:ok, stat} = File.stat(path)

    %{
      path: Path.relative_to(path, root),
      type: Atom.to_string(stat.type),
      size: stat.size
    }
  end

  defp file_info(path, root) do
    with {:ok, stat} <- File.stat(path) do
      {:ok,
       %{
         path: Path.relative_to(path, root),
         type: Atom.to_string(stat.type),
         size: stat.size,
         modified: format_time(stat.mtime)
       }}
    end
  end

  defp format_time({date, time}) do
    {:ok, naive} = NaiveDateTime.new(Date.from_erl!(date), Time.from_erl!(time))
    NaiveDateTime.to_iso8601(naive)
  end

  defp write_file(path, content, "append"), do: File.write(path, content, [:append])

  defp write_file(path, content, "create") do
    if File.exists?(path), do: {:error, :exists}, else: File.write(path, content)
  end

  defp write_file(path, content, _mode), do: File.write(path, content)
end

defmodule FileManagerRunner do
  def run do
    root = Path.join(System.tmp_dir!(), "ex_mcp_file_manager_example")
    IO.puts("Starting File Manager MCP Server on stdio.")
    IO.puts("Sandbox root: #{root}")

    {:ok, _server} = FileManager.start_link(transport: :stdio, handler_args: [root_dir: root])
    Process.sleep(:infinity)
  end
end

if System.get_env("MCP_ENV") != "test" do
  FileManagerRunner.run()
end
