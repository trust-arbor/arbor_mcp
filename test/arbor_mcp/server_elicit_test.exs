defmodule Arbor.MCP.ServerElicitTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Server

  describe "elicit/1 form mode" do
    test "builds an elicitation/create entry from atom keys" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }

      assert Server.elicit(%{message: "Choose a display name", requested_schema: schema}) == %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "Choose a display name",
                 "requestedSchema" => schema
               }
             }
    end

    test "accepts string and camelCase keys" do
      schema = %{"type" => "object"}

      assert Server.elicit(%{
               "message" => "Name?",
               "requestedSchema" => schema
             }) == %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "Name?",
                 "requestedSchema" => schema
               }
             }
    end

    test "defaults a missing schema to an empty object" do
      assert Server.elicit(%{message: "Anything else?"}) == %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "Anything else?",
                 "requestedSchema" => %{}
               }
             }
    end
  end

  describe "elicit/1 URL mode" do
    test "builds URL params and preserves a supplied elicitationId" do
      assert Server.elicit(%{
               message: "Sign in to continue",
               mode: "url",
               url: "https://auth.example.com/login",
               elicitationId: "elicit-login-1"
             }) == %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "Sign in to continue",
                 "mode" => "url",
                 "url" => "https://auth.example.com/login",
                 "elicitationId" => "elicit-login-1"
               }
             }
    end

    test "generates elicitationId when URL mode omits it" do
      entry =
        Server.elicit(%{
          message: "Sign in",
          mode: "url",
          url: "https://auth.example.com/login"
        })

      assert entry["method"] == "elicitation/create"
      params = entry["params"]
      assert params["mode"] == "url"
      assert params["url"] == "https://auth.example.com/login"
      assert params["message"] == "Sign in"
      assert is_binary(params["elicitationId"])
      assert String.starts_with?(params["elicitationId"], "elicit-")
    end

    test "treats a url field as URL mode when mode is omitted" do
      params =
        Server.elicit(%{
          message: "Open this page",
          url: "https://example.com/continue"
        })["params"]

      assert params["mode"] == "url"
      assert params["url"] == "https://example.com/continue"
      assert is_binary(params["elicitationId"])
    end

    test "accepts elicitation_id snake_case alias" do
      params =
        Server.elicit(%{
          message: "Sign in",
          mode: :url,
          url: "https://auth.example.com/login",
          elicitation_id: "elicit-snake"
        })["params"]

      assert params["elicitationId"] == "elicit-snake"
    end

    test "generated ids are unique" do
      first = Server.elicit(%{mode: "url", url: "https://example.com/a"})
      second = Server.elicit(%{mode: "url", url: "https://example.com/b"})

      assert first["params"]["elicitationId"] != second["params"]["elicitationId"]
    end
  end
end
