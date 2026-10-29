defmodule Arbor.MCP.Protocol.ElicitationTest do
  @moduledoc """
  Running out of time while validating an elicitation is a timeout, not bad
  params: whoever asked for the elicitation must be able to tell the two
  apart.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Protocol.Elicitation

  @valid %{
    "message" => "Choose a display name",
    "requestedSchema" => %{"type" => "object", "properties" => %{}}
  }

  defp now, do: System.monotonic_time(:millisecond)

  describe "validate/2" do
    test "valid params before the deadline are normalized" do
      assert {:ok, @valid} = Elicitation.validate(@valid, now() + 1_000)
      assert {:ok, @valid} = Elicitation.validate(@valid, :infinity)
    end

    test "valid params with a spent deadline are a timeout, not invalid params" do
      assert {:error, {:elicitation_validation_timeout, 0}} =
               Elicitation.validate(@valid, now() - 1)

      # A deadline of now has no time left either.
      assert {:error, {:elicitation_validation_timeout, 0}} = Elicitation.validate(@valid, now())
    end

    test "a spent deadline is a timeout whatever the params are" do
      assert {:error, {:elicitation_validation_timeout, 0}} =
               Elicitation.validate(%{"requestedSchema" => false}, now() - 1_000)
    end

    test "invalid params before the deadline are invalid params" do
      deadline = now() + 1_000

      for params <- [
            %{"message" => "Choose", "requestedSchema" => false},
            %{"message" => "Choose", "requestedSchema" => %{"type" => "array"}},
            %{"requestedSchema" => %{"type" => "object", "properties" => %{}}},
            Map.put(@valid, "private", self()),
            :not_a_map
          ] do
        assert {:error, :invalid_elicitation_params} = Elicitation.validate(params, deadline),
               "expected #{inspect(params)} to be invalid"
      end
    end
  end

  describe "validate_reverse/2" do
    test "a validation timeout is the :timeout an expired reverse request reports" do
      assert {:error, :timeout} = Elicitation.validate_reverse(@valid, now() - 1)
    end

    test "invalid and valid params keep their results" do
      deadline = now() + 1_000

      assert {:error, :invalid_elicitation_params} =
               Elicitation.validate_reverse(%{"requestedSchema" => false}, deadline)

      assert {:ok, @valid} = Elicitation.validate_reverse(@valid, deadline)
    end
  end
end
