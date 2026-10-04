defmodule Arbor.MCP.Content.SchemaOfficialCorpusTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Content.SchemaPolicy

  @fixture Path.expand("../../fixtures/schema/draft2020-12-core.json", __DIR__)
  @external_resource @fixture
  @corpus @fixture |> File.read!() |> Jason.decode!()

  for {keyword, groups} <- @corpus["files"],
      {group, group_index} <- Enum.with_index(groups),
      {test_case, case_index} <- Enum.with_index(group["tests"]) do
    name = "official 2020-12 #{keyword}/#{group_index}/#{case_index}: #{test_case["description"]}"

    test name do
      schema = unquote(Macro.escape(group["schema"]))
      data = unquote(Macro.escape(test_case["data"]))

      if unquote(
           {keyword, group_index} in [{"unevaluatedItems", 18}, {"unevaluatedProperties", 21}]
         ) do
        # Four official cases use URI-named embedded resources. Our existing
        # default policy permits fragment refs only, and must reject explicitly.
        assert {:error, :network_ref_forbidden} = SchemaPolicy.compile(schema)
      else
        assert {:ok, root} = SchemaPolicy.compile(schema)
        result = SchemaPolicy.validate(data, root)

        if unquote(test_case["valid"]),
          do: assert(result == :ok),
          else: assert(match?({:error, _}, result))
      end
    end
  end
end
