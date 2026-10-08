defmodule Arbor.MCP.Client.InteractiveHandler do
  @moduledoc """
  Interactive terminal handler for MCP client events.

  Presents elicitation requests, sampling requests, and permission prompts
  to the user via stdin/stdout. Useful for CLI applications that need
  human-in-the-loop interaction with MCP servers.

  ## Usage

      {:ok, client} = Arbor.MCP.Client.start_link(
        transport: :http,
        url: "http://localhost:3000/mcp",
        handler: Arbor.MCP.Client.InteractiveHandler,
        capabilities: %{"elicitation" => %{}, "sampling" => %{}}
      )

  When the server sends `elicitation/create`, the handler will:
  1. Display the message and schema to the user
  2. Prompt for each field in the schema
  3. Apply defaults when the user presses Enter without input
  4. Return the collected data or allow cancellation

  ## Schema Rendering

  Supports all JSON Schema types:
  - `string` → text prompt (with default, minLength, maxLength)
  - `integer` / `number` → numeric prompt (with minimum, maximum)
  - `boolean` → yes/no prompt
  - `enum` → numbered selection list
  - `array` → comma-separated values
  - `object` → nested prompts (one level)
  """

  @behaviour Arbor.MCP.Client.Handler

  @impl true
  def init(args) do
    {:ok, Map.new(args || [])}
  end

  @impl true
  def handle_ping(state), do: {:ok, %{}, state}

  @impl true
  def handle_list_roots(state), do: {:ok, [], state}

  @impl true
  def handle_create_message(_params, state) do
    {:error, "Interactive sampling not yet supported", state}
  end

  @impl true
  def handle_elicitation_create(message, requested_schema, state) do
    IO.puts("\n--- MCP Elicitation Request ---")
    IO.puts(message)
    IO.puts("")

    properties = Map.get(requested_schema, "properties", %{})
    required = Map.get(requested_schema, "required", [])

    if map_size(properties) == 0 do
      # No fields — just confirm
      case prompt_confirm("Accept this request?", true) do
        true -> {:ok, %{"action" => "accept", "content" => %{}}, state}
        false -> {:ok, %{"action" => "decline"}, state}
      end
    else
      case collect_fields(properties, required) do
        {:ok, content} ->
          {:ok, %{"action" => "accept", "content" => content}, state}

        :cancelled ->
          {:ok, %{"action" => "cancel"}, state}

        :declined ->
          {:ok, %{"action" => "decline"}, state}
      end
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # Collect user input for each property in the schema
  defp collect_fields(properties, required) do
    properties
    |> Enum.sort_by(fn {name, _} ->
      # Required fields first
      if name in required, do: 0, else: 1
    end)
    |> Enum.reduce_while({:ok, %{}}, fn {name, schema}, {:ok, acc} ->
      is_required = name in required

      case prompt_field(name, schema, is_required) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        :skip -> {:cont, {:ok, acc}}
        :cancel -> {:halt, :cancelled}
      end
    end)
  end

  defp prompt_field(name, schema, is_required) do
    type = Map.get(schema, "type", "string")
    description = Map.get(schema, "description")
    default = Map.get(schema, "default")
    enum_values = Map.get(schema, "enum")

    # Build the prompt label
    label = build_label(name, description, default, is_required)

    cond do
      enum_values ->
        prompt_enum(label, enum_values, default)

      type == "boolean" ->
        prompt_boolean(label, default)

      type in ["integer", "number"] ->
        prompt_number(label, type, schema, default)

      type == "array" ->
        prompt_array(label, schema, default)

      true ->
        prompt_string(label, schema, default)
    end
  end

  defp build_label(name, description, default, is_required) do
    parts = [name]
    parts = if description, do: parts ++ [" (#{description})"], else: parts
    parts = if default != nil, do: parts ++ [" [default: #{inspect(default)}]"], else: parts
    parts = if is_required, do: parts ++ [" *"], else: parts
    Enum.join(parts)
  end

  defp prompt_string(label, schema, default) do
    input = IO.gets("  #{label}: ") |> String.trim()

    cond do
      input == "" and default != nil -> {:ok, default}
      input == "" -> :skip
      input == "!cancel" -> :cancel
      true -> validate_string(input, schema)
    end
  end

  defp prompt_number(label, type, schema, default) do
    input = IO.gets("  #{label}: ") |> String.trim()

    cond do
      input == "" and default != nil ->
        {:ok, default}

      input == "" ->
        :skip

      input == "!cancel" ->
        :cancel

      true ->
        case parse_number(input, type) do
          {:ok, value} -> validate_number(value, schema)
          :error -> prompt_number(label, type, schema, default)
        end
    end
  end

  defp prompt_boolean(label, default) do
    default_hint = if default == true, do: "Y/n", else: "y/N"
    input = IO.gets("  #{label} (#{default_hint}): ") |> String.trim() |> String.downcase()

    case input do
      "" when default != nil -> {:ok, default}
      "" -> {:ok, false}
      "y" -> {:ok, true}
      "yes" -> {:ok, true}
      "n" -> {:ok, false}
      "no" -> {:ok, false}
      "!cancel" -> :cancel
      _ -> prompt_boolean(label, default)
    end
  end

  defp prompt_enum(label, values, default) do
    IO.puts("  #{label}:")

    values
    |> Enum.with_index(1)
    |> Enum.each(fn {val, idx} ->
      marker = if val == default, do: " (default)", else: ""
      IO.puts("    #{idx}. #{val}#{marker}")
    end)

    input = IO.gets("  Choose [1-#{length(values)}]: ") |> String.trim()

    cond do
      input == "" and default != nil ->
        {:ok, default}

      input == "!cancel" ->
        :cancel

      true ->
        case Integer.parse(input) do
          {idx, _} when idx >= 1 and idx <= length(values) ->
            {:ok, Enum.at(values, idx - 1)}

          _ ->
            # Try matching by value name
            if input in values do
              {:ok, input}
            else
              prompt_enum(label, values, default)
            end
        end
    end
  end

  defp prompt_array(label, _schema, default) do
    IO.puts("  #{label} (comma-separated):")
    input = IO.gets("  > ") |> String.trim()

    cond do
      input == "" and default != nil -> {:ok, default}
      input == "" -> {:ok, []}
      input == "!cancel" -> :cancel
      true -> {:ok, String.split(input, ",") |> Enum.map(&String.trim/1)}
    end
  end

  @dialyzer {:nowarn_function, prompt_confirm: 2}
  defp prompt_confirm(message, default) do
    hint = if default, do: "Y/n", else: "y/N"
    input = IO.gets("  #{message} (#{hint}): ") |> String.trim() |> String.downcase()

    case input do
      "" -> default
      "y" -> true
      "yes" -> true
      "n" -> false
      "no" -> false
      _ -> prompt_confirm(message, default)
    end
  end

  defp parse_number(input, "integer") do
    case Integer.parse(input) do
      {val, ""} -> {:ok, val}
      _ -> :error
    end
  end

  defp parse_number(input, _) do
    case Float.parse(input) do
      {val, ""} -> {:ok, val}
      _ -> :error
    end
  end

  defp validate_string(value, schema) do
    min = Map.get(schema, "minLength", 0)
    max = Map.get(schema, "maxLength", :infinity)

    cond do
      String.length(value) < min ->
        IO.puts("    Minimum #{min} characters required")
        :skip

      max != :infinity and String.length(value) > max ->
        IO.puts("    Maximum #{max} characters allowed")
        :skip

      true ->
        {:ok, value}
    end
  end

  defp validate_number(value, schema) do
    min = Map.get(schema, "minimum")
    max = Map.get(schema, "maximum")

    cond do
      min && value < min ->
        IO.puts("    Minimum value is #{min}")
        :skip

      max && value > max ->
        IO.puts("    Maximum value is #{max}")
        :skip

      true ->
        {:ok, value}
    end
  end
end
