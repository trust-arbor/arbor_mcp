defmodule Arbor.MCP.Authorization.ScopeValidatorTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Authorization.ScopeValidator
  alias Arbor.MCP.Protocol.Methods

  describe "get_required_scopes/2" do
    test "returns correct scopes for standard methods" do
      assert ScopeValidator.get_required_scopes(%{"method" => "tools/list"}) == ["mcp:tools:list"]
      assert ScopeValidator.get_required_scopes(%{"method" => "tools/get"}) == ["mcp:tools:get"]

      assert ScopeValidator.get_required_scopes(%{"method" => "tools/execute"}) == [
               "mcp:tools:execute"
             ]

      assert ScopeValidator.get_required_scopes(%{
               "method" => "tools/execute",
               "params" => %{"tool_name" => "my_tool"}
             }) == ["mcp:tools:execute:my_tool"]

      assert ScopeValidator.get_required_scopes(%{
               "method" => "tools/call",
               "params" => %{"name" => "my_tool"}
             }) == ["mcp:tools:execute:my_tool"]

      assert ScopeValidator.get_required_scopes(%{"method" => "resources/list"}) == [
               "mcp:resources:list"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "resources/get"}) == [
               "mcp:resources:get"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "resources/read"}) == [
               "mcp:resources:get"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "resources/create"}) == [
               "mcp:resources:create"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "resources/update"}) == [
               "mcp:resources:update"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "resources/delete"}) == [
               "mcp:resources:delete"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "prompts/execute"}) == [
               "mcp:prompts:execute"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "prompts/get"}) == [
               "mcp:prompts:get"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "completion/complete"}) == [
               "mcp:completion:complete"
             ]

      assert ScopeValidator.get_required_scopes(%{"method" => "session/delete"}) == [
               "mcp:sessions:delete"
             ]
    end

    test "fails closed for unknown methods" do
      assert ScopeValidator.get_required_scopes(%{"method" => "unknown/method"}) ==
               {:error, :unmapped_method}
    end

    test "fails closed for request without method" do
      assert ScopeValidator.get_required_scopes(%{"params" => %{}}) ==
               {:error, :unmapped_method}
    end

    test "maps only validated methodless responses to protocol bookkeeping" do
      for id <- ["reverse-1", 1, nil] do
        assert ScopeValidator.get_required_scopes(%{
                 "jsonrpc" => "2.0",
                 "id" => id,
                 "result" => %{}
               }) == []

        assert ScopeValidator.get_required_scopes(%{
                 "jsonrpc" => "2.0",
                 "id" => id,
                 "error" => %{"code" => -32603, "message" => "Client failure"}
               }) == []
      end
    end

    test "response bookkeeping is not a methodless or malformed envelope fallback" do
      valid = %{"jsonrpc" => "2.0", "id" => "reverse-1", "result" => %{}}

      for malformed <- [
            Map.delete(valid, "id"),
            Map.delete(valid, "result"),
            Map.put(valid, "id", 1.5),
            Map.put(valid, "jsonrpc", "1.0"),
            Map.put(valid, "method", "unknown/operation"),
            Map.put(valid, "error", %{"code" => -32603, "message" => "Failure"}),
            %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"message" => "Failure"}}
          ] do
        assert ScopeValidator.get_required_scopes(malformed) == {:error, :unmapped_method}
      end
    end

    test "custom response policies remain authoritative and nil uses validated fallback" do
      response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

      assert ScopeValidator.get_required_scopes(response, fn _ -> ["host:reverse:reply"] end) ==
               ["host:reverse:reply"]

      assert ScopeValidator.get_required_scopes(response, fn _ -> nil end) == []

      assert ScopeValidator.get_required_scopes(response, fn _ -> [] end) ==
               {:error, :invalid_scope_mapping}
    end

    test "uses custom mapper when provided" do
      custom_mapper = fn
        %{"method" => "custom/op"} -> ["my:custom:scope"]
        %{"method" => "resources/get", "params" => %{"id" => id}} -> ["mcp:resources:get:#{id}"]
        _ -> nil
      end

      assert ScopeValidator.get_required_scopes(%{"method" => "custom/op"}, custom_mapper) == [
               "my:custom:scope"
             ]

      assert ScopeValidator.get_required_scopes(
               %{"method" => "resources/get", "params" => %{"id" => "res_123"}},
               custom_mapper
             ) == ["mcp:resources:get:res_123"]
    end

    test "falls back to default mapper when custom mapper returns nil" do
      custom_mapper = fn _ -> nil end

      assert ScopeValidator.get_required_scopes(
               %{"method" => "tools/list"},
               custom_mapper
             ) == ["mcp:tools:list"]
    end

    test "rejects invalid custom mapper output" do
      assert ScopeValidator.get_required_scopes(%{"method" => "custom/op"}, fn _ -> "admin" end) ==
               {:error, :invalid_scope_mapping}

      assert ScopeValidator.get_required_scopes(%{"method" => "custom/op"}, fn _ -> [] end) ==
               {:error, :invalid_scope_mapping}
    end

    test "has an explicit policy for every canonical MCP method" do
      for {method, _min, _max, _kind, _handlers} <- Methods.rows() do
        refute match?(
                 {:error, _reason},
                 ScopeValidator.get_required_scopes(%{"method" => method})
               ),
               "missing scope policy for #{method}"
      end
    end
  end

  describe "validate/2" do
    test "returns :ok for exact scope match" do
      token_scopes = ["mcp:tools:list", "mcp:tools:get"]
      required_scopes = ["mcp:tools:list"]
      assert ScopeValidator.validate(token_scopes, required_scopes) == :ok
    end

    test "returns :ok when all required scopes are present" do
      token_scopes = ["mcp:tools:list", "mcp:tools:get", "mcp:prompts:execute"]
      required_scopes = ["mcp:tools:list", "mcp:prompts:execute"]
      assert ScopeValidator.validate(token_scopes, required_scopes) == :ok
    end

    test "returns :ok for wildcard scope match" do
      token_scopes = ["mcp:tools:execute"]
      required_scopes = ["mcp:tools:execute:my_tool"]
      assert ScopeValidator.validate(token_scopes, required_scopes) == :ok
    end

    test "does not infer undeclared parent scopes as wildcards" do
      token_scopes = ["mcp:resources"]
      required_scopes = ["mcp:resources:get:specific_res"]

      assert ScopeValidator.validate(token_scopes, required_scopes) ==
               {:error, :insufficient_scope}
    end

    test "returns :ok with a mix of exact and wildcard scopes" do
      token_scopes = ["mcp:tools:execute", "mcp:resources:list"]
      required_scopes = ["mcp:tools:execute:my_tool", "mcp:resources:list"]
      assert ScopeValidator.validate(token_scopes, required_scopes) == :ok
    end

    test "returns {:error, :insufficient_scope} when a scope is missing" do
      token_scopes = ["mcp:tools:list"]
      required_scopes = ["mcp:tools:list", "mcp:tools:get"]

      assert ScopeValidator.validate(token_scopes, required_scopes) ==
               {:error, :insufficient_scope}
    end

    test "returns {:error, :insufficient_scope} when required scope is more general" do
      token_scopes = ["mcp:tools:execute:my_tool"]
      required_scopes = ["mcp:tools:execute"]

      assert ScopeValidator.validate(token_scopes, required_scopes) ==
               {:error, :insufficient_scope}
    end

    test "returns {:error, :insufficient_scope} for sibling scopes" do
      token_scopes = ["mcp:tools:get"]
      required_scopes = ["mcp:tools:list"]

      assert ScopeValidator.validate(token_scopes, required_scopes) ==
               {:error, :insufficient_scope}
    end

    test "returns :ok for empty required scopes" do
      token_scopes = ["mcp:tools:list"]
      required_scopes = []
      assert ScopeValidator.validate(token_scopes, required_scopes) == :ok
    end

    test "returns {:error, :insufficient_scope} for empty token scopes with non-empty required" do
      token_scopes = []
      required_scopes = ["mcp:tools:list"]

      assert ScopeValidator.validate(token_scopes, required_scopes) ==
               {:error, :insufficient_scope}
    end
  end

  describe "get_all_static_scopes/0" do
    test "returns a list of all predefined static scopes" do
      expected_scopes = [
        "mcp:tools:list",
        "mcp:tools:get",
        "mcp:tools:execute",
        "mcp:resources:list",
        "mcp:resources:get",
        "mcp:resources:create",
        "mcp:resources:update",
        "mcp:resources:delete",
        "mcp:prompts:list",
        "mcp:prompts:get",
        "mcp:prompts:execute",
        "mcp:completion:complete",
        "mcp:server:discover",
        "mcp:resources:subscribe",
        "mcp:logging:set",
        "mcp:roots:list",
        "mcp:sampling:create",
        "mcp:elicitation:create",
        "mcp:tasks:get",
        "mcp:tasks:list",
        "mcp:tasks:result",
        "mcp:tasks:cancel",
        "mcp:tasks:update",
        "mcp:subscriptions:listen",
        "mcp:requests:cancel",
        "mcp:sessions:listen",
        "mcp:sessions:delete"
      ]

      assert ScopeValidator.get_all_static_scopes() -- expected_scopes == []
      assert expected_scopes -- ScopeValidator.get_all_static_scopes() == []
    end
  end
end
