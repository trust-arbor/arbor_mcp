defmodule Arbor.MCP.Client.InputDispatcherTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Client.InputDispatcher

  defmodule UrlFourHandler do
    def handle_url_elicitation(message, url, elicitation_id, state) do
      send(state.owner, {:url4, message, url, elicitation_id})
      {:ok, %{"action" => "accept", "via" => "four"}, state}
    end
  end

  defmodule UrlThreeHandler do
    def handle_url_elicitation(message, url, state) do
      send(state.owner, {:url3, message, url})
      {:ok, %{"action" => "accept", "via" => "three"}, state}
    end
  end

  defmodule BothUrlHandlers do
    def handle_url_elicitation(message, url, state) do
      send(state.owner, {:url3, message, url})
      {:ok, %{"action" => "accept", "via" => "three"}, state}
    end

    def handle_url_elicitation(message, url, elicitation_id, state) do
      send(state.owner, {:url4, message, url, elicitation_id})
      {:ok, %{"action" => "accept", "via" => "four"}, state}
    end
  end

  @url_params %{
    "mode" => "url",
    "message" => "Sign in to continue",
    "url" => "https://auth.example.com/login",
    "elicitationId" => "elicit-login-1"
  }

  defp dispatch(handler, params \\ @url_params) do
    InputDispatcher.dispatch(
      "elicitation/create",
      params,
      handler,
      %{owner: self()},
      %{"elicitation" => %{"url" => %{}}}
    )
  end

  test "calls handle_url_elicitation/4 with elicitationId when implemented" do
    assert {:ok, %{"action" => "accept", "via" => "four"}, _state} = dispatch(UrlFourHandler)

    assert_receive {:url4, "Sign in to continue", "https://auth.example.com/login",
                    "elicit-login-1"}
  end

  test "keeps handle_url_elicitation/3 when /4 is not implemented" do
    assert {:ok, %{"action" => "accept", "via" => "three"}, _state} = dispatch(UrlThreeHandler)
    assert_receive {:url3, "Sign in to continue", "https://auth.example.com/login"}
    refute_receive {:url4, _, _, _}
  end

  test "prefers /4 when both arities are exported" do
    assert {:ok, %{"action" => "accept", "via" => "four"}, _state} = dispatch(BothUrlHandlers)

    assert_receive {:url4, "Sign in to continue", "https://auth.example.com/login",
                    "elicit-login-1"}

    refute_receive {:url3, _, _}
  end

  test "passes a missing elicitationId as nil to /4" do
    params = Map.delete(@url_params, "elicitationId")
    assert {:ok, %{"via" => "four"}, _state} = dispatch(UrlFourHandler, params)
    assert_receive {:url4, "Sign in to continue", "https://auth.example.com/login", nil}
  end
end
