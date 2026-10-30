defmodule Arbor.MCP.Server.DSL.ServerOptionsTest do
  @moduledoc """
  DSL servers declare what the official SDKs let a server declare:
  - capabilities with `listChanged`, plus a `capabilities:` override;
  - `instructions:`, which clients read with `Client.instructions/1`;
  - paginated lists with `page_size:`;
  - completion for prompt arguments and template variables through `complete:`.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Client

  defmodule Frameworks do
    @moduledoc false
    def suggest(value, context) do
      language = get_in(context, ["arguments", "language"])
      options = %{"elixir" => ["phoenix", "plug"], "python" => ["flask", "fastapi"]}
      options |> Map.get(language, []) |> Enum.filter(&String.starts_with?(&1, value))
    end
  end

  defmodule Server do
    @moduledoc false
    use Arbor.MCP.Server.Handler

    use Arbor.MCP.Server.DSL,
      name: "options",
      version: "1.0.0",
      instructions: "Call scaffold first.",
      capabilities: [resources: [subscribe: true]],
      page_size: 2

    tool "one" do
      run(fn _args, state -> {:ok, "1", state} end)
    end

    tool "two" do
      run(fn _args, state -> {:ok, "2", state} end)
    end

    tool "three" do
      run(fn _args, state -> {:ok, "3", state} end)
    end

    prompt "scaffold", "Scaffold a project" do
      arg(:language, complete: ["elixir", "erlang", "python"])
      arg(:framework, complete: &Frameworks.suggest/2)
      arg(:name, complete: :suggest_names)
      render(fn _args, state -> {:ok, "go", state} end)
    end

    resource_template "repo://{owner}/{name}", "A repository" do
      param(:owner, :string, complete: ["anthropics", "trust-arbor"])
      param(:name, :string)
      read(fn %{owner: owner, name: name}, state -> {:ok, "#{owner}/#{name}", state} end)
    end

    def suggest_names(value, _context), do: ["#{value}-app", "#{value}-service"]
  end

  defp start_client(mode) do
    {:ok, server} = Server.start_link(transport: :test)

    {:ok, client} =
      Client.start_link(
        transport: :test,
        server: server,
        protocol_mode: mode,
        health_check_interval: nil
      )

    client
  end

  test "capabilities advertise listChanged, completions and the override" do
    assert %{
             "tools" => %{"listChanged" => true},
             "prompts" => %{"listChanged" => true},
             "resources" => %{"listChanged" => true, "subscribe" => true},
             "completions" => %{}
           } = Server.__server_capabilities__()
  end

  test "instructions reach the client in both eras" do
    for mode <- [:legacy_only, :modern_only] do
      assert {:ok, "Call scaffold first."} = mode |> start_client() |> Client.instructions()
    end
  end

  test "lists are paginated with an opaque cursor" do
    client = start_client(:legacy_only)

    assert {:ok, first} = Client.list_tools(client, format: :map)
    assert ["one", "two"] = Enum.map(first["tools"], & &1["name"])
    assert is_binary(first["nextCursor"])

    assert {:ok, second} = Client.list_tools(client, cursor: first["nextCursor"], format: :map)
    assert ["three"] = Enum.map(second["tools"], & &1["name"])
    refute second["nextCursor"]

    assert {:ok, all} = Client.all_tools(client)
    assert length(all) == 3

    assert {:error, %{code: -32602}} = Client.list_tools(client, cursor: "not-a-cursor")
  end

  test "prompt arguments complete from lists, captures and local functions" do
    client = start_client(:legacy_only)
    ref = %{"type" => "ref/prompt", "name" => "scaffold"}

    assert {:ok, %{"completion" => %{"values" => ["erlang"]}}} =
             complete(client, ref, "language", "Er")

    assert {:ok, %{"completion" => %{"values" => ["phoenix"]}}} =
             complete(client, ref, "framework", "ph",
               context: %{"arguments" => %{"language" => "elixir"}}
             )

    assert {:ok, %{"completion" => %{"values" => ["my-app", "my-service"], "hasMore" => false}}} =
             complete(client, ref, "name", "my")
  end

  test "template variables complete too" do
    client = start_client(:legacy_only)
    ref = %{"type" => "ref/resource", "uri" => "repo://{owner}/{name}"}

    assert {:ok, %{"completion" => %{"values" => ["trust-arbor"]}}} =
             complete(client, ref, "owner", "tr")
  end

  # It falls back to handle_complete/3, and the default of that, in a server
  # that serves completions, completes to nothing, as the TypeScript SDK does.
  test "an argument without a completer completes to nothing" do
    client = start_client(:legacy_only)
    ref = %{"type" => "ref/resource", "uri" => "repo://{owner}/{name}"}

    assert {:ok, %{"completion" => %{"values" => [], "hasMore" => false}}} =
             complete(client, ref, "name", "x")
  end

  test "an empty value lists every candidate, and a missing one is invalid" do
    client = start_client(:legacy_only)
    ref = %{"type" => "ref/prompt", "name" => "scaffold"}

    assert {:ok, %{"completion" => %{"values" => ["elixir", "erlang", "python"], "total" => 3}}} =
             complete(client, ref, "language", "")

    assert {:error, %{"code" => -32602}} =
             Client.complete(client, ref, %{"name" => "language"}, format: :map)
  end

  describe "invalid declarations fail at compile time" do
    for {label, use_opts, declaration, message} <- [
          {"anonymous completer", "", ~s|arg :a, complete: fn v, _ -> [v] end|,
           "Anonymous functions"},
          {"non-string values", "", ~s|arg :a, complete: [:x]|, "must list strings"},
          {"wrong capture arity", "", ~s|arg :a, complete: &String.upcase/1|, "of arity 2"},
          {"undefined local completer", "", ~s|arg :a, complete: :missing|,
           "needs a public missing/2"},
          {"zero page size", ", page_size: 0", ~s|arg :a|, "page_size: must be a positive"},
          {"non-string instructions", ", instructions: :hi", ~s|arg :a|,
           "instructions: must be a string"}
        ] do
      test label do
        module = "InvalidOptions#{System.unique_integer([:positive])}"

        source = """
        defmodule #{module} do
          use Arbor.MCP.Server.Handler
          use Arbor.MCP.Server.DSL#{unquote(use_opts)}
          prompt "p", "A prompt" do
            #{unquote(declaration)}
            render fn _args, state -> {:ok, "unused", state} end
          end
        end
        """

        error = assert_raise CompileError, fn -> Code.compile_string(source, "options.ex") end
        assert error.description =~ unquote(message)
      end
    end
  end

  defp complete(client, ref, name, value, opts \\ []) do
    Client.complete(client, ref, %{"name" => name, "value" => value}, [format: :map] ++ opts)
  end
end
