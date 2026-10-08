defmodule Arbor.MCP.ConsentHandler.Test do
  @moduledoc """
  Test consent handler for automated testing scenarios.

  This handler provides deterministic consent responses for testing purposes.
  It uses an Agent to store pre-configured responses and tracks consent history
  for test verification.

  ## Usage in Tests

      # Setup test consent responses
      Arbor.MCP.ConsentHandler.Test.start_link()
      Arbor.MCP.ConsentHandler.Test.set_consent_response("user1", "https://api.example.com", :approved)
      Arbor.MCP.ConsentHandler.Test.set_consent_response("user2", "https://evil.com", :denied)

      # Run your security tests...

      # Verify consent was requested
      history = Arbor.MCP.ConsentHandler.Test.get_consent_history()
      assert length(history) == 2

      # Cleanup
      Arbor.MCP.ConsentHandler.Test.clear_all_consents()
  """

  @behaviour Arbor.MCP.ConsentHandler

  use Agent

  @type consent_response :: :approved | :denied | :error
  @type consent_key :: {user_id :: String.t(), resource_origin :: String.t()}
  @type consent_history_entry :: %{
          user_id: String.t(),
          resource_origin: String.t(),
          request_context: map(),
          response: consent_response(),
          timestamp: DateTime.t()
        }

  @doc """
  Starts the test consent handler Agent.

  This should be called in test setup to initialize the handler state.
  """
  def start_link(opts \\ []) do
    Agent.start_link(
      fn -> %{responses: %{}, history: []} end,
      Keyword.put_new(opts, :name, __MODULE__)
    )
  end

  @doc """
  Stops the test consent handler Agent.
  """
  def stop do
    if Process.whereis(__MODULE__) do
      Agent.stop(__MODULE__)
    end
  end

  @doc """
  Sets a pre-configured consent response for a user/origin combination.

  ## Parameters

  - `user_id` - The user identifier
  - `resource_origin` - The resource origin (e.g., "https://api.example.com")
  - `response` - The response to return (`:approved`, `:denied`, or `:error`)

  ## Examples

      # User will approve access to api.example.com
      set_consent_response("user1", "https://api.example.com", :approved)

      # User will deny access to evil.com
      set_consent_response("user2", "https://evil.com", :denied)
  """
  @spec set_consent_response(String.t(), String.t(), consent_response()) :: :ok
  def set_consent_response(user_id, resource_origin, response) do
    Agent.update(__MODULE__, fn state ->
      key = {user_id, resource_origin}
      responses = Map.put(state.responses, key, response)
      %{state | responses: responses}
    end)
  end

  @doc """
  Clears all pre-configured consent responses and history.

  This should be called between tests to ensure clean state.
  """
  @spec clear_all_consents() :: :ok
  def clear_all_consents do
    Agent.update(__MODULE__, fn _state ->
      %{responses: %{}, history: []}
    end)
  end

  @doc """
  Gets the history of all consent requests made during testing.

  Returns a list of consent history entries in chronological order.
  """
  @spec get_consent_history() :: [consent_history_entry()]
  def get_consent_history do
    Agent.get(__MODULE__, fn state -> Enum.reverse(state.history) end)
  end

  @doc """
  Gets the number of consent requests made for a specific user/origin combination.
  """
  @spec get_consent_request_count(String.t(), String.t()) :: non_neg_integer()
  def get_consent_request_count(user_id, resource_origin) do
    Agent.get(__MODULE__, fn state ->
      state.history
      |> Enum.count(fn entry ->
        entry.user_id == user_id and entry.resource_origin == resource_origin
      end)
    end)
  end

  @impl true
  def request_consent(user_id, resource_origin, request_context) do
    # Record the consent request in history
    history_entry = %{
      user_id: user_id,
      resource_origin: resource_origin,
      request_context: request_context,
      response: nil,
      timestamp: DateTime.utc_now()
    }

    # Get pre-configured response or default to denied
    key = {user_id, resource_origin}

    response =
      Agent.get(__MODULE__, fn state ->
        Map.get(state.responses, key, :denied)
      end)

    # Update history with the response
    Agent.update(__MODULE__, fn state ->
      updated_entry = %{history_entry | response: response}
      history = [updated_entry | state.history]
      %{state | history: history}
    end)

    # Return appropriate response
    case response do
      :approved ->
        expires_at = DateTime.add(DateTime.utc_now(), :timer.hours(1), :millisecond)
        {:approved, expires_at: expires_at}

      :denied ->
        {:denied, reason: "Test consent denied for #{resource_origin}"}

      :error ->
        {:error, reason: "Test consent error for #{resource_origin}"}
    end
  end

  @impl true
  def check_existing_consent(_user_id, _resource_origin) do
    # For testing, we don't maintain persistent consent state
    # Each request goes through request_consent/3
    :not_found
  end

  @impl true
  def revoke_consent(_user_id, _resource_origin) do
    # For testing, consent revocation is handled by clearing responses
    :ok
  end
end
