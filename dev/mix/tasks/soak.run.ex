defmodule Mix.Tasks.Soak.Run do
  @moduledoc "Runs the continuous MCP qualification harness. See docs/qualification/SOAK_HARNESS.md."
  @shortdoc "Runs the MCP continuous qualification harness"
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Arbor.MCP.Soak.Runner.run(args) do
      {:ok, summary} ->
        Mix.shell().info("Soak passed: #{summary["summary_path"]}")

      {:error, summary} ->
        Mix.raise("Soak failed: #{summary["summary_path"]}")
    end
  end
end
