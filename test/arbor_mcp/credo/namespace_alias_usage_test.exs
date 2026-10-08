defmodule Arbor.MCP.Credo.NamespaceAliasUsageTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Credo.NamespaceAliasUsage
  alias Credo.Check.Design.AliasUsage
  alias Credo.SourceFile

  @params [if_nested_deeper_than: 2, if_called_more_often_than: 1]

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:credo)
    :ok
  end

  test "old and new package roots keep the same shallow and deep module policy" do
    for {old, renamed} <- [
          {"ExMCP.Error", "Arbor.MCP.Error"},
          {"ExMCP.JSONRPC", "Arbor.RPC.JSONRPC"},
          {"ExMCP.Server.Dispatch", "Arbor.MCP.Server.Dispatch"},
          {"ExMCP.Transport.Stdio", "Arbor.RPC.Transport.Stdio"}
        ] do
      previous = old |> source() |> AliasUsage.run(@params)
      current = renamed |> source() |> NamespaceAliasUsage.run(@params)
      assert length(current) == length(previous)
    end

    assert [] = "Arbor.MCP.Error" |> source() |> NamespaceAliasUsage.run(@params)
    assert [_, _] = "Arbor.MCP.Server.Dispatch" |> source() |> NamespaceAliasUsage.run(@params)
  end

  test "unrelated namespaces and names that only resemble package roots remain flagged" do
    for name <- ["ThirdParty.Protocol.Client", "Arbor.MCPExtension.Client", "Arbor.Other.Client"] do
      file = source(name)
      assert NamespaceAliasUsage.run(file, @params) == AliasUsage.run(file, @params)
      assert [_, _] = NamespaceAliasUsage.run(file, @params)
    end
  end

  test "frequency and alias conflicts still come from the standard check" do
    assert [] =
             "Arbor.MCP.Server.Dispatch"
             |> source(calls: 1)
             |> NamespaceAliasUsage.run(@params)

    assert [] =
             "Arbor.MCP.Server.Dispatch"
             |> source(alias: "OtherPackage.Dispatch")
             |> NamespaceAliasUsage.run(@params)

    assert [_, _] =
             "Arbor.MCP.Server.Dispatch"
             |> source()
             |> NamespaceAliasUsage.run(@params)
  end

  test "standard exclusions and issue identity are preserved" do
    file = source("Arbor.MCP.Server.Dispatch")
    [issue | _rest] = NamespaceAliasUsage.run(file, @params)
    assert issue.check == AliasUsage
    assert issue.trigger == "Arbor.MCP.Server.Dispatch"

    assert [] =
             NamespaceAliasUsage.run(
               file,
               Keyword.put(@params, :excluded_lastnames, ["Dispatch"])
             )

    assert [] =
             NamespaceAliasUsage.run(file, Keyword.put(@params, :excluded_namespaces, ["Arbor"]))
  end

  defp source(name, opts \\ []) do
    alias_source = if opts[:alias], do: "alias #{opts[:alias]}", else: ""

    calls =
      Enum.map_join(1..Keyword.get(opts, :calls, 2), "\n", fn _index -> "#{name}.call()" end)

    SourceFile.parse(
      """
      defmodule CheckFixture do
        #{alias_source}
        def run do
          #{calls}
        end
      end
      """,
      "fixture_#{name}_#{make_ref() |> inspect()}.ex"
    )
  end
end
