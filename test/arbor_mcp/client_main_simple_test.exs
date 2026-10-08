defmodule Arbor.MCP.ClientSimpleTest do
  use ExUnit.Case

  test "client module exists and has expected functions" do
    # Basic sanity check that the module exists
    assert {:module, Arbor.MCP.Client} = Code.ensure_compiled(Arbor.MCP.Client)

    # Check that expected functions are exported
    functions = Arbor.MCP.Client.__info__(:functions)

    expected_functions = [
      {:start_link, 1},
      {:list_tools, 1},
      {:list_tools, 2},
      {:call_tool, 3},
      {:call_tool, 4},
      {:list_resources, 1},
      {:list_resources, 2},
      {:read_resource, 2},
      {:read_resource, 3},
      {:list_prompts, 1},
      {:list_prompts, 2},
      {:get_prompt, 2},
      {:get_prompt, 3},
      {:get_prompt, 4},
      {:get_status, 1}
    ]

    for func <- expected_functions do
      assert func in functions, "Expected function #{inspect(func)} not found"
    end
  end

  test "client struct has expected fields" do
    # Create a Client struct and verify fields
    state = %Arbor.MCP.Client{}

    expected_fields = [
      :transport_mod,
      :transport_state,
      :transport_opts,
      :server_info,
      :connection_status,
      :pending_requests,
      :last_activity,
      :receiver_task,
      :reconnect_attempts,
      :health_check_ref,
      :health_check_interval,
      :client_info
    ]

    for field <- expected_fields do
      assert Map.has_key?(state, field), "Expected field #{field} not found in Client struct"
    end
  end
end
