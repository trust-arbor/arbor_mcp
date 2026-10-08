defmodule Arbor.MCP.Internal.HTTPResponseReducerTest do
  @moduledoc """
  Pure, table-driven coverage of `Arbor.MCP.Internal.HTTPResponseReducer`.

  The pinned HTTP client characterization tests pin each owner's policy at
  the socket boundary; this file pins the shared mechanics, including the
  cases that boundary cannot reach: events for a foreign request ref,
  unknown event shapes, events after `:done` in one batch, and a `:done`
  without a status.
  """

  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.HTTPResponseReducer, as: Reducer

  describe "reduce/4" do
    setup do
      %{ref: make_ref(), other: make_ref()}
    end

    test "accumulates status, reason, headers, and chunks in order and completes on done", %{
      ref: ref
    } do
      events = [
        {:status, ref, 201},
        {:status_reason, ref, "Created"},
        {:headers, ref, [{"X-A", "1"}, {"Content-Type", "text/plain"}]},
        {:data, ref, "ab"},
        {:data, ref, "cd"},
        {:headers, ref, [{"X-Trailer", "t"}]},
        {:done, ref}
      ]

      assert {:done, acc} = Reducer.reduce(events, ref, Reducer.empty_response(), max_bytes: 10)

      assert acc == %{
               status: 201,
               reason: "Created",
               headers: [{"x-a", "1"}, {"content-type", "text/plain"}, {"x-trailer", "t"}],
               chunks: ["cd", "ab"],
               size: 4
             }

      assert Reducer.body(acc) == "abcd"
    end

    test "returns :cont while the response is still open and resumes across batches", %{ref: ref} do
      first = [{:status, ref, 200}, {:headers, ref, []}, {:data, ref, "ab"}]
      second = [{:data, ref, "cd"}, {:done, ref}]

      assert {:cont, open} = Reducer.reduce(first, ref, Reducer.empty_response(), max_bytes: 4)
      assert open.size == 2
      assert {:done, acc} = Reducer.reduce(second, ref, open, max_bytes: 4)
      assert Reducer.body(acc) == "abcd"
      assert acc.size == 4
    end

    test "ignores every event for a foreign request ref", %{ref: ref, other: other} do
      events = [
        {:status, other, 500},
        {:status_reason, other, "Nope"},
        {:headers, other, [{"content-encoding", "gzip"}]},
        {:data, other, String.duplicate("x", 100)},
        {:done, other}
      ]

      assert {:cont, acc} =
               Reducer.reduce(events, ref, Reducer.empty_response(),
                 max_bytes: 4,
                 validate_headers: fn _new, _all -> {:error, :must_not_run} end
               )

      assert acc == Reducer.empty_response()
    end

    test "ignores unknown event shapes", %{ref: ref} do
      events = [{:pong, ref}, {:error, ref, :boom}, :garbage, {:status, ref, 200}]

      assert {:cont, %{status: 200}} =
               Reducer.reduce(events, ref, Reducer.empty_response(), max_bytes: 4)
    end

    test "stops at the first done and ignores later events in the batch", %{ref: ref} do
      events = [{:status, ref, 200}, {:done, ref}, {:data, ref, "late"}, {:status, ref, 500}]

      assert {:done, %{status: 200, chunks: [], size: 0}} =
               Reducer.reduce(events, ref, Reducer.empty_response(), max_bytes: 4)
    end

    test "completes on done even without a status, leaving that decision to the caller", %{
      ref: ref
    } do
      assert {:done, %{status: nil}} =
               Reducer.reduce([{:done, ref}], ref, Reducer.empty_response(), max_bytes: 4)
    end

    test "rejects a body that exceeds max_bytes across chunks and accepts one exactly at it", %{
      ref: ref
    } do
      at_limit = [{:data, ref, "ab"}, {:data, ref, "cd"}, {:done, ref}]
      over = [{:data, ref, "ab"}, {:data, ref, "cde"}, {:done, ref}]

      assert {:done, %{size: 4}} =
               Reducer.reduce(at_limit, ref, Reducer.empty_response(), max_bytes: 4)

      assert {:error, :response_too_large} =
               Reducer.reduce(over, ref, Reducer.empty_response(), max_bytes: 4)
    end

    test "passes the normalized batch and the accumulated list to validate_headers", %{ref: ref} do
      parent = self()

      validate = fn batch, all ->
        send(parent, {:validated, batch, all})
        :ok
      end

      events = [{:headers, ref, [{"A", "1"}]}, {:headers, ref, [{"B", "2"}]}]

      assert {:cont, %{headers: [{"a", "1"}, {"b", "2"}]}} =
               Reducer.reduce(events, ref, Reducer.empty_response(),
                 max_bytes: 4,
                 validate_headers: validate
               )

      assert_receive {:validated, [{"a", "1"}], [{"a", "1"}]}
      assert_receive {:validated, [{"b", "2"}], [{"a", "1"}, {"b", "2"}]}
    end

    test "halts with the caller's reason when validate_headers rejects", %{ref: ref} do
      events = [{:headers, ref, [{"x", "1"}]}, {:data, ref, "ab"}, {:done, ref}]

      assert {:error, {:policy, :nope}} =
               Reducer.reduce(events, ref, Reducer.empty_response(),
                 max_bytes: 4,
                 validate_headers: fn _new, _all -> {:error, {:policy, :nope}} end
               )
    end

    test "requires max_bytes", %{ref: ref} do
      assert_raise KeyError, fn ->
        Reducer.reduce([], ref, Reducer.empty_response(), [])
      end
    end
  end

  describe "normalize_headers/1" do
    test "downcases names, stringifies both parts, and keeps order and duplicates" do
      assert Reducer.normalize_headers([{"X-Dup", "A"}, {~c"x-dup", ~c"b"}, {:host, 1}]) ==
               [{"x-dup", "A"}, {"x-dup", "b"}, {"host", "1"}]
    end
  end

  describe "content_length_too_large?/2 (lenient)" do
    test "table" do
      cases = [
        {[], false},
        {[{"content-length", "4"}], false},
        {[{"content-length", "5"}], true},
        {[{"content-length", "-1"}], false},
        {[{"content-length", " 4"}], true},
        {[{"content-length", "4 "}], true},
        {[{"content-length", "abc"}], true},
        {[{"content-length", ""}], true},
        {[{"content-length", "4"}, {"content-length", "4"}], false},
        {[{"content-length", "4"}, {"content-length", "9"}], true},
        {[{"x-other", "999"}], false}
      ]

      for {headers, expected} <- cases do
        assert Reducer.content_length_too_large?(headers, 4) == expected,
               "expected #{inspect(headers)} -> #{expected}"
      end
    end
  end

  describe "invalid_or_oversized_content_length?/2 (strict)" do
    test "table" do
      cases = [
        {[], false},
        {[{"content-length", "4"}], false},
        {[{"content-length", "0"}], false},
        {[{"content-length", "5"}], true},
        {[{"content-length", "-1"}], true},
        {[{"content-length", " 4 "}], false},
        {[{"content-length", "abc"}], true},
        {[{"content-length", ""}], true},
        {[{"content-length", "4"}, {"content-length", "4"}], true},
        {[{"x-other", "999"}], false}
      ]

      for {headers, expected} <- cases do
        assert Reducer.invalid_or_oversized_content_length?(headers, 4) == expected,
               "expected #{inspect(headers)} -> #{expected}"
      end
    end
  end

  describe "compressed?/1" do
    test "table" do
      cases = [
        {[], false},
        {[{"content-encoding", "identity"}], false},
        {[{"content-encoding", " Identity "}], false},
        {[{"content-encoding", ""}], false},
        {[{"content-encoding", "gzip"}], true},
        {[{"content-encoding", " Br "}], true},
        {[{"content-encoding", "identity"}, {"content-encoding", "gzip"}], true},
        {[{"content-type", "gzip"}], false}
      ]

      for {headers, expected} <- cases do
        assert Reducer.compressed?(headers) == expected,
               "expected #{inspect(headers)} -> #{expected}"
      end
    end
  end

  describe "conflicting_framing?/1" do
    test "table" do
      cases = [
        {[], false},
        {[{"content-length", "4"}], false},
        {[{"transfer-encoding", "chunked"}], false},
        {[{"content-length", "4"}, {"transfer-encoding", "chunked"}], true},
        {[{"transfer-encoding", "chunked"}, {"x", "y"}, {"content-length", "4"}], true}
      ]

      for {headers, expected} <- cases do
        assert Reducer.conflicting_framing?(headers) == expected,
               "expected #{inspect(headers)} -> #{expected}"
      end
    end
  end

  describe "request_target/1" do
    test "table" do
      cases = [
        {%URI{path: nil, query: nil}, "/"},
        {%URI{path: "", query: nil}, "/"},
        {%URI{path: "/", query: nil}, "/"},
        {%URI{path: "/a/b", query: nil}, "/a/b"},
        {%URI{path: nil, query: "x=1"}, "/?x=1"},
        {%URI{path: "", query: "x=1"}, "/?x=1"},
        {%URI{path: "/a", query: "x=1&y=2"}, "/a?x=1&y=2"},
        {%URI{path: "/a", query: ""}, "/a?"}
      ]

      for {uri, expected} <- cases do
        assert Reducer.request_target(uri) == expected, "expected #{inspect(uri)} -> #{expected}"
      end
    end
  end

  describe "small helpers" do
    test "default_port/1" do
      assert Reducer.default_port(:http) == 80
      assert Reducer.default_port(:https) == 443
    end

    test "address_family_options/1" do
      assert Reducer.address_family_options({127, 0, 0, 1}) == [inet4: true, inet6: false]

      assert Reducer.address_family_options({0, 0, 0, 0, 0, 0, 0, 1}) ==
               [inet4: false, inet6: true]
    end

    test "method_name/1" do
      assert Reducer.method_name(:get) == "GET"
      assert Reducer.method_name(:patch) == "PATCH"
    end

    test "remaining_ms/2 never goes negative" do
      assert Reducer.remaining_ms(1_000, 400) == 600
      assert Reducer.remaining_ms(1_000, 1_000) == 0
      assert Reducer.remaining_ms(1_000, 1_500) == 0
    end

    test "body/1 joins chunks in arrival order and handles no chunks" do
      assert Reducer.body(Reducer.empty_response()) == ""
      assert Reducer.body(%{chunks: ["c", "b", "a"]}) == "abc"
    end
  end
end
