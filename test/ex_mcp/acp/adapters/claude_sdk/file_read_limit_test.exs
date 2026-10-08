defmodule ExMCP.ACP.Adapters.ClaudeSDK.FileReadLimitTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.ClaudeSDK

  setup do
    {:ok, state} = ClaudeSDK.init(session_id: "session", cwd: "/workspace")
    %{state: state}
  end

  test "an exact byte limit succeeds without inventing ACP fields", %{state: state} do
    {request, state} = read_request(state, %{"max_bytes" => 4})

    assert request["method"] == "fs/read_text_file"
    assert request["params"] == %{"sessionId" => "session", "path" => "/workspace/file.txt"}

    {response, state} = reply(state, request["id"], %{"content" => "body"})
    assert_success(response, "body")
    assert state.pending_client_requests == %{}
  end

  test "an over-limit response fails once without returning partial contents", %{state: state} do
    {request, state} = read_request(state, %{"max_bytes" => 4})
    {response, state} = reply(state, request["id"], %{"content" => "body!"})

    assert_error(response, "read_file response exceeds max_bytes")
    refute Map.has_key?(response["response"], "response")
    assert state.pending_client_requests == %{}

    assert {:ok, :skip, ^state} =
             ClaudeSDK.translate_outbound(%{"id" => request["id"], "result" => %{}}, state)
  end

  test "the cap counts UTF-8 bytes and never splits a multibyte character", %{state: state} do
    content = "é🙂"
    assert byte_size(content) == 6

    {request, state} = read_request(state, %{"max_bytes" => 6})
    {response, state} = reply(state, request["id"], %{"contents" => content})
    assert_success(response, content)

    {request, state} = read_request(state, %{"max_bytes" => 5})
    {response, _state} = reply(state, request["id"], %{"contents" => content})
    assert_error(response, "read_file response exceeds max_bytes")
  end

  test "zero permits empty contents but rejects any returned byte", %{state: state} do
    {request, state} = read_request(state, %{"max_bytes" => 0})
    {response, state} = reply(state, request["id"], %{})
    assert_success(response, "")

    {request, state} = read_request(state, %{"max_bytes" => 0})
    {response, _state} = reply(state, request["id"], %{"content" => "a"})
    assert_error(response, "read_file response exceeds max_bytes")
  end

  test "invalid limits fail before an ACP request or pending entry is created", %{state: state} do
    for limit <- [-1, 1.5, "4", nil, false, %{}, []] do
      assert {:skip_and_write, data, ^state} =
               inbound_read(state, %{"max_bytes" => limit})

      assert_error(decode(data), "read_file max_bytes must be a non-negative integer")
      assert state.pending_client_requests == %{}
    end
  end

  test "invalid UTF-8 and non-text results become control errors", %{state: state} do
    results = [
      %{"content" => <<255>>},
      %{"contents" => <<255>>},
      %{"content" => 42},
      %{"content" => false},
      %{"contents" => false},
      []
    ]

    for result <- results do
      {request, pending} = read_request(state, %{"max_bytes" => 16})
      {response, final} = reply(pending, request["id"], result)

      assert_error(response, "read_file response must contain UTF-8 text")
      assert final.pending_client_requests == %{}
    end
  end

  test "an absent cap preserves both content spelling and absolute path", %{state: state} do
    {request, state} = read_request(state, %{})

    {response, _state} =
      reply(state, request["id"], %{"contents" => "longer contents", "absPath" => "/actual/file"})

    assert_success(response, "longer contents")
    assert response["response"]["response"]["absPath"] == "/actual/file"
  end

  test "each pending read retains its own byte cap", %{state: state} do
    {first, state} = read_request(state, %{"max_bytes" => 4}, "first")
    {second, state} = read_request(state, %{"max_bytes" => 6}, "second")

    {response, state} = reply(state, second["id"], %{"content" => "é🙂"})
    assert_success(response, "é🙂", "second")

    {response, state} = reply(state, first["id"], %{"content" => "é🙂"})
    assert_error(response, "read_file response exceeds max_bytes", "first")
    assert state.pending_client_requests == %{}
  end

  test "client errors retain their native control error and settle the cap", %{state: state} do
    {request, state} = read_request(state, %{"max_bytes" => 4})

    assert {:ok, data, state} =
             ClaudeSDK.translate_outbound(
               %{"id" => request["id"], "error" => %{"code" => -32_002, "message" => "denied"}},
               state
             )

    assert_error(decode(data), "denied")
    assert state.pending_client_requests == %{}
  end

  test "cancellation drops the capped read and a late response writes nothing", %{state: state} do
    {request, state} = read_request(state, %{"max_bytes" => 4})
    cancel = %{"type" => "control_cancel_request", "request_id" => "read"}
    assert {:skip, state} = ClaudeSDK.translate_inbound(Jason.encode!(cancel), state)
    assert state.pending_client_requests == %{}

    assert {:ok, :skip, ^state} =
             ClaudeSDK.translate_outbound(
               %{"id" => request["id"], "result" => %{"content" => "late"}},
               state
             )
  end

  defp inbound_read(state, options, request_id \\ "read") do
    request = Map.merge(%{"subtype" => "read_file", "path" => "/workspace/file.txt"}, options)
    message = %{"type" => "control_request", "request_id" => request_id, "request" => request}
    ClaudeSDK.translate_inbound(Jason.encode!(message), state)
  end

  defp read_request(state, options, request_id \\ "read") do
    assert {:messages, [request], state} = inbound_read(state, options, request_id)
    {request, state}
  end

  defp reply(state, id, result) do
    assert {:ok, data, state} =
             ClaudeSDK.translate_outbound(%{"id" => id, "result" => result}, state)

    {decode(data), state}
  end

  defp decode(data) do
    bytes = IO.iodata_to_binary(data)
    assert String.ends_with?(bytes, "\n")
    Jason.decode!(bytes)
  end

  defp assert_success(response, content, request_id \\ "read") do
    assert %{
             "type" => "control_response",
             "response" => %{
               "subtype" => "success",
               "request_id" => ^request_id,
               "response" => %{"contents" => ^content}
             }
           } = response
  end

  defp assert_error(response, error, request_id \\ "read") do
    assert %{
             "type" => "control_response",
             "response" => %{"subtype" => "error", "request_id" => ^request_id, "error" => ^error}
           } = response
  end
end
