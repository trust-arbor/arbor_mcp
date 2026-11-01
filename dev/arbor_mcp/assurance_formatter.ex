defmodule Arbor.MCP.AssuranceFormatter do
  @moduledoc false
  use GenServer

  def init(_options), do: {:ok, []}

  def handle_cast({:test_finished, test}, results) do
    result = %{
      "file" => Path.relative_to_cwd(test.tags.file),
      "name" => Atom.to_string(test.name),
      "cases" => Map.get(test.tags, :assurance, []),
      "state" => if(is_nil(test.state), do: "passed", else: "not_passed")
    }

    {:noreply, [result | results]}
  end

  def handle_cast({:suite_finished, _times}, results) do
    path = System.fetch_env!("MCP_ASSURANCE_RESULTS")
    File.write!(path, Jason.encode!(%{"tests" => Enum.reverse(results)}))
    {:noreply, results}
  end

  def handle_cast(_event, results), do: {:noreply, results}
end
