defmodule Arbor.MCP.Client.ConnectionManagerPropertyTest do
  @moduledoc """
  Property-based tests for Arbor.MCP.Client.ConnectionManager transport configuration.

  These tests ensure that all transport configuration formats are handled correctly
  and that no FunctionClauseErrors occur with valid input combinations.
  """

  use ExUnit.Case, async: true
  use PropCheck

  alias Arbor.MCP.Client.ConnectionManager
  alias Arbor.MCP.Testing.MockTransport
  alias Arbor.MCP.Transport.{HTTP, Stdio, Test}
  alias Arbor.MCP.Transport.HTTP.LegacySSE

  # We'll test through the public prepare_transport_config function
  defmodule TestWrapper do
    @moduledoc false

    def normalize_transport_spec(transport_spec, opts) do
      # Test through the public API by wrapping the transport_spec appropriately
      full_opts = [transport: transport_spec] ++ opts

      case ConnectionManager.prepare_transport_config(full_opts) do
        {:ok, [transports: [normalized_spec]]} -> normalized_spec
        {:error, reason} -> {:error, reason}
      end
    end
  end

  describe "transport configuration property tests" do
    test "removed transport aliases are rejected" do
      assert {:error, native_reason} =
               ConnectionManager.prepare_transport_config(transport: :native)

      assert native_reason =~ "Unsupported transport :native"

      assert {:error, _reason} =
               ConnectionManager.prepare_transport_config(transport: {:native, []})

      assert {:error, _reason} =
               ConnectionManager.prepare_transport_config(transport: [type: :native])
    end

    test "transport :sse is the legacy HTTP+SSE connector" do
      assert {:ok, [transports: [{LegacySSE, opts}]]} =
               ConnectionManager.prepare_transport_config(
                 transport: :sse,
                 url: "http://localhost:4000"
               )

      assert opts[:url] == "http://localhost:4000"
      refute opts[:use_sse]

      assert {:ok, [transports: [{LegacySSE, _}]]} =
               ConnectionManager.prepare_transport_config(transport: {:sse, []})

      assert {:ok, [transports: [{LegacySSE, _}]]} =
               ConnectionManager.prepare_transport_config(transport: [type: :sse])
    end

    property "normalize_transport_spec handles all atom transport types" do
      forall transport_atom <- oneof([:stdio, :http, :sse, :test, :mock, :beam]) do
        forall opts <- list({atom(), term()}) do
          case TestWrapper.normalize_transport_spec(transport_atom, opts) do
            {transport_mod, merged_opts} when is_atom(transport_mod) and is_list(merged_opts) ->
              # Valid response - transport module and options
              true

            {:error, _reason} ->
              # Expected error for invalid combinations
              true

            _other ->
              # Log unexpected responses for debugging
              # Unexpected response for debugging purposes
              false
          end
        end
      end
    end

    property "normalize_transport_spec handles tuple transport specifications" do
      forall {transport_atom, transport_opts} <- {
               oneof([:stdio, :http, :sse, :test, :mock, :beam]),
               list({atom(), term()})
             } do
        case TestWrapper.normalize_transport_spec({transport_atom, transport_opts}, []) do
          {transport_mod, merged_opts} when is_atom(transport_mod) and is_list(merged_opts) ->
            true

          {:error, _reason} ->
            true

          _other ->
            # Unexpected response for debugging purposes
            false
        end
      end
    end

    property "normalize_transport_spec handles keyword list transport specifications" do
      forall transport_spec <-
               oneof([
                 # With explicit type
                 [{:type, oneof([:stdio, :http, :test, :mock])}, {:server_pid, make_ref()}],
                 [
                   {:type, oneof([:stdio, :http, :test, :mock])},
                   {:timeout, choose(1000, 60000)}
                 ],
                 # Without explicit type - inferred from keys
                 [{:server_pid, make_ref()}],
                 [{:command, non_empty(list(oneof([char(), non_empty(binary())])))}],
                 [{:url, non_empty(binary())}]
               ]) do
        case TestWrapper.normalize_transport_spec(transport_spec, []) do
          {transport_mod, merged_opts} when is_atom(transport_mod) and is_list(merged_opts) ->
            true

          {:error, _reason} ->
            # Expected for some invalid combinations
            true

          _other ->
            # Unexpected response for debugging purposes
            false
        end
      end
    end

    property "mock transport preserves its server_pid option" do
      forall server_pid <- make_ref() do
        transport_spec = [type: :mock, server_pid: server_pid]

        case TestWrapper.normalize_transport_spec(transport_spec, []) do
          {MockTransport, opts} ->
            Keyword.get(opts, :server_pid) == server_pid and not Keyword.has_key?(opts, :server)

          {:error, _reason} ->
            true

          _other ->
            # Unexpected response for debugging purposes
            false
        end
      end
    end

    property "options merging preserves provided options" do
      forall {transport_atom, timeout, retry_count} <- {
               oneof([:stdio, :http, :test, :mock]),
               choose(1000, 60000),
               choose(1, 10)
             } do
        extra_opts = [timeout: timeout, retry_count: retry_count]

        case TestWrapper.normalize_transport_spec(transport_atom, extra_opts) do
          {_transport_mod, merged_opts} when is_list(merged_opts) ->
            # Check that our specific options are present
            Keyword.get(merged_opts, :timeout) == timeout and
              Keyword.get(merged_opts, :retry_count) == retry_count

          {:error, _reason} ->
            true

          _other ->
            false
        end
      end
    end
  end

  describe "edge cases and error conditions" do
    test "handles invalid transport types gracefully" do
      invalid_transports = [
        :invalid_transport,
        "string_transport",
        123,
        %{invalid: :map}
      ]

      for invalid_transport <- invalid_transports do
        case TestWrapper.normalize_transport_spec(invalid_transport, []) do
          {:error, _reason} ->
            # Expected error
            :ok

          {transport_mod, _opts} when is_atom(transport_mod) ->
            # Some invalid atoms might be treated as custom transport modules
            :ok

          other ->
            flunk(
              "Unexpected response for invalid transport #{inspect(invalid_transport)}: #{inspect(other)}"
            )
        end
      end
    end

    test "handles empty keyword lists" do
      assert {:error, _} = TestWrapper.normalize_transport_spec([], [])
    end

    test "handles keyword lists without type or recognizable keys" do
      invalid_specs = [
        [random_key: "value"],
        [another: :atom, random: 123]
      ]

      for spec <- invalid_specs do
        case TestWrapper.normalize_transport_spec(spec, []) do
          {:error, reason} ->
            assert is_binary(reason)

          other ->
            flunk("Expected error for invalid spec #{inspect(spec)}, got: #{inspect(other)}")
        end
      end
    end
  end

  describe "regression tests for specific configurations" do
    test "handles mock transport with server_pid (from supervisor tests)" do
      # This was the failing case from supervisor_test.exs
      server_pid = spawn(fn -> :ok end)
      transport_spec = [type: :mock, server_pid: server_pid]

      assert {MockTransport, opts} = TestWrapper.normalize_transport_spec(transport_spec, [])
      assert Keyword.get(opts, :server_pid) == server_pid
      assert not Keyword.has_key?(opts, :server)
    end

    test "handles test transport without explicit type" do
      server_pid = spawn(fn -> :ok end)
      transport_spec = [server_pid: server_pid]

      assert {Test, opts} = TestWrapper.normalize_transport_spec(transport_spec, [])
      assert Keyword.get(opts, :server) == server_pid
    end

    test "handles stdio transport with command" do
      transport_spec = [command: ["some", "command"]]

      assert {Stdio, opts} = TestWrapper.normalize_transport_spec(transport_spec, [])
      assert Keyword.get(opts, :command) == ["some", "command"]
    end

    test "handles http transport with url" do
      transport_spec = [url: "http://example.com"]

      assert {HTTP, opts} = TestWrapper.normalize_transport_spec(transport_spec, [])
      assert Keyword.get(opts, :url) == "http://example.com"
    end
  end
end
