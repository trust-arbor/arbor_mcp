defmodule Arbor.MCP.Compliance.UrlElicitationTest do
  @moduledoc """
  Tests for URL-mode elicitation in MCP protocol version 2025-11-25.

  Verifies:
  - Protocol.encode_elicitation_create_url/3 creates correct JSON-RPC messages
  - Protocol.encode_elicitation_complete_notification/1 creates correct notifications
  - Version availability of notifications/elicitation/complete
  - Client and server handler callbacks for URL-mode elicitation
  """
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.Protocol

  describe "encode_elicitation_create_url/3" do
    test "creates a valid JSON-RPC request with url field" do
      message = "Please authenticate via the following URL"
      url = "https://auth.example.com/login?session=abc123"

      encoded = Protocol.encode_elicitation_create_url(message, url)

      assert encoded["jsonrpc"] == "2.0"
      assert encoded["method"] == "elicitation/create"
      assert is_integer(encoded["id"])
      assert encoded["params"]["message"] == message
      assert encoded["params"]["url"] == url
      assert encoded["params"]["mode"] == "url"
      assert is_binary(encoded["params"]["elicitationId"])
    end

    test "does not include requestedSchema field" do
      encoded = Protocol.encode_elicitation_create_url("msg", "https://example.com")

      refute Map.has_key?(encoded["params"], "requestedSchema")
    end

    test "includes message, url, mode, and elicitationId in params" do
      encoded = Protocol.encode_elicitation_create_url("msg", "https://example.com")

      assert Map.keys(encoded["params"]) |> Enum.sort() == [
               "elicitationId",
               "message",
               "mode",
               "url"
             ]
    end

    test "mode is always 'url' not 'form'" do
      encoded = Protocol.encode_elicitation_create_url("msg", "https://example.com")

      assert encoded["params"]["mode"] == "url"
      refute encoded["params"]["mode"] == "form"
    end

    test "accepts optional opts keyword list" do
      encoded =
        Protocol.encode_elicitation_create_url("msg", "https://example.com", timeout: 30_000)

      assert encoded["method"] == "elicitation/create"
      assert encoded["params"]["url"] == "https://example.com"
    end

    test "generates unique ids for each call" do
      encoded1 = Protocol.encode_elicitation_create_url("msg", "https://example.com/1")
      encoded2 = Protocol.encode_elicitation_create_url("msg", "https://example.com/2")

      assert encoded1["id"] != encoded2["id"]
    end

    test "preserves url with query parameters" do
      url = "https://auth.example.com/oauth?client_id=abc&redirect_uri=http%3A%2F%2Flocalhost"
      encoded = Protocol.encode_elicitation_create_url("Authenticate", url)

      assert encoded["params"]["url"] == url
    end
  end

  describe "encode_elicitation_complete_notification/1" do
    test "creates a valid JSON-RPC notification" do
      elicitation_id = "elicit-001"

      notification = Protocol.encode_elicitation_complete_notification(elicitation_id)

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/elicitation/complete"
      assert notification["params"]["elicitationId"] == elicitation_id
    end

    test "does not include an id field (notification, not request)" do
      notification = Protocol.encode_elicitation_complete_notification("elicit-001")

      refute Map.has_key?(notification, "id")
    end

    test "params contain only elicitationId" do
      notification = Protocol.encode_elicitation_complete_notification("elicit-xyz")

      assert Map.keys(notification["params"]) == ["elicitationId"]
    end

    test "works with different elicitation ID formats" do
      for id <- ["elicit-001", "abc-def-ghi", "12345", "uuid-4f3e-8a1b"] do
        notification = Protocol.encode_elicitation_complete_notification(id)
        assert notification["params"]["elicitationId"] == id
      end
    end
  end

  describe "method_available?/2 for notifications/elicitation/complete" do
    test "is available in version 2025-11-25" do
      assert Protocol.method_available?("notifications/elicitation/complete", "2025-11-25")
    end

    test "is NOT available in version 2025-06-18" do
      refute Protocol.method_available?("notifications/elicitation/complete", "2025-06-18")
    end

    test "is NOT available in version 2025-03-26" do
      refute Protocol.method_available?("notifications/elicitation/complete", "2025-03-26")
    end

    test "is NOT available in version 2024-11-05" do
      refute Protocol.method_available?("notifications/elicitation/complete", "2024-11-05")
    end
  end

  describe "method_available?/2 for elicitation/create" do
    test "is available in 2025-06-18 (form-based elicitation)" do
      assert Protocol.method_available?("elicitation/create", "2025-06-18")
    end

    test "is available in 2025-11-25 (includes URL-mode)" do
      assert Protocol.method_available?("elicitation/create", "2025-11-25")
    end

    test "is NOT available in 2025-03-26" do
      refute Protocol.method_available?("elicitation/create", "2025-03-26")
    end
  end

  describe "URL-mode vs form-mode elicitation encoding" do
    test "form-mode includes requestedSchema, URL-mode includes url" do
      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
      form_encoded = Protocol.encode_elicitation_create("Provide info", schema)

      url_encoded =
        Protocol.encode_elicitation_create_url("Authenticate", "https://auth.example.com")

      # Both use the same method
      assert form_encoded["method"] == "elicitation/create"
      assert url_encoded["method"] == "elicitation/create"

      # Form-mode has requestedSchema, URL-mode has url
      assert Map.has_key?(form_encoded["params"], "requestedSchema")
      refute Map.has_key?(form_encoded["params"], "url")

      assert Map.has_key?(url_encoded["params"], "url")
      refute Map.has_key?(url_encoded["params"], "requestedSchema")
    end
  end

  describe "validate_message_version/2 for URL elicitation" do
    test "elicitation complete notification passes validation for 2025-11-25" do
      notification = Protocol.encode_elicitation_complete_notification("elicit-001")

      assert :ok == Protocol.validate_message_version(notification, "2025-11-25")
    end

    test "elicitation complete notification fails validation for 2025-06-18" do
      notification = Protocol.encode_elicitation_complete_notification("elicit-001")

      assert {:error, _reason} = Protocol.validate_message_version(notification, "2025-06-18")
    end
  end

  describe "server handler callback for elicitation complete" do
    defmodule TestServerHandler do
      use Arbor.MCP.Server.Handler

      @impl true
      def handle_initialize(_params, state) do
        {:ok,
         %{
           protocolVersion: "2025-11-25",
           serverInfo: %{name: "url-elicit-test", version: "1.0.0"},
           capabilities: %{}
         }, state}
      end

      @impl true
      def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

      @impl true
      def handle_call_tool(_name, _args, state), do: {:error, "not implemented", state}

      @impl true
      def handle_elicitation_complete(elicitation_id, state) do
        {:ok, Map.put(state, :completed_elicitation, elicitation_id)}
      end
    end

    test "default handler implementation returns {:ok, state}" do
      defmodule DefaultHandler do
        use Arbor.MCP.Server.Handler

        @impl true
        def handle_initialize(_params, state), do: {:ok, %{}, state}

        @impl true
        def handle_list_tools(_cursor, state), do: {:ok, [], nil, state}

        @impl true
        def handle_call_tool(_name, _args, state), do: {:error, "not implemented", state}
      end

      assert {:ok, %{}} = DefaultHandler.handle_elicitation_complete("elicit-001", %{})
    end

    test "custom handler can track completed elicitations" do
      {:ok, new_state} = TestServerHandler.handle_elicitation_complete("elicit-abc", %{})

      assert new_state.completed_elicitation == "elicit-abc"
    end
  end

  describe "client handler callback for URL elicitation" do
    defmodule TestClientHandler do
      @behaviour Arbor.MCP.Client.Handler

      @impl true
      def init(args), do: {:ok, args}

      @impl true
      def handle_ping(state), do: {:ok, %{}, state}

      @impl true
      def handle_list_roots(state) do
        {:ok, [%{uri: "file:///test", name: "test"}], state}
      end

      @impl true
      def handle_create_message(_params, state) do
        {:error, "not supported", state}
      end

      @impl true
      def handle_url_elicitation(_message, url, state) do
        {:ok, %{action: "accept", content: %{"authenticated" => true}},
         Map.put(state, :visited_url, url)}
      end
    end

    test "client handler receives URL elicitation and can respond" do
      {:ok, result, new_state} =
        TestClientHandler.handle_url_elicitation(
          "Please authenticate",
          "https://auth.example.com/login",
          %{}
        )

      assert result.action == "accept"
      assert result.content["authenticated"] == true
      assert new_state.visited_url == "https://auth.example.com/login"
    end

    test "handle_url_elicitation is an optional callback" do
      optional = Arbor.MCP.Client.Handler.behaviour_info(:optional_callbacks)
      assert {:handle_url_elicitation, 3} in optional
      assert {:handle_url_elicitation, 4} in optional
    end
  end
end
