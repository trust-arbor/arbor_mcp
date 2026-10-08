defmodule ExMCP.ACP.Adapters.ClaudeSDK.FaultsGoldenTest do
  @moduledoc """
  Characterization gate for the Claude SDK adapter's fault handling
  (`docs/POST_1_0_MAINTENANCE_PLAN.md`, "Claude adapter characterization
  gate": cancellation, `interrupt`, error replies, late and unknown
  responses, and subprocess exit).

  Each test drives `ExMCP.ACP.Adapters.ClaudeSDK` through
  `ExMCP.Test.ClaudeGolden` and compares the recorded transcript against a
  committed fixture under `test/fixtures/acp/claude/faults/`. The fixtures
  pin:

    * `session/cancel` writing the SDK `interrupt` control request, and
      answering every queued prompt of that session with
      `stopReason: "cancelled"` while leaving the *active* prompt pending
      (Claude answers it with its own `result`), including a cancel that
      names another session, one that names none, and one with nothing
      open at all;
    * the prompt queue: a second prompt being skipped rather than written,
      draining in order on each `result`, and being cancelled wholesale by
      `session/cancel`, `session/close` and `session/delete`;
    * the `read_file` control request round trip (`fs/read_text_file`, the
      `contents` / `content` reply spellings, the `absPath` fallback) and
      the control error a client error reply writes;
    * a `read_file` response at its exact `max_bytes` boundary succeeding
      without inventing an ACP byte-limit field; focused public-callback
      tests in `file_read_limit_test.exs` cover refusals, UTF-8 byte counts,
      cancellation and one-time settlement;
    * the fail-closed answers for control requests the adapter does not
      implement and for a malformed control request;
    * `control_cancel_request` dropping a pending client request so a late
      reply writes nothing, a duplicate reply being dropped the same way,
      a reply for an id that was never issued, and a response that is
      neither a result nor an error;
    * the outbound messages that are skipped without a write: an unknown
      method, an unknown notification, and a message with neither a method
      nor an id; and the inbound lines that are skipped: a blank line,
      whitespace, non-JSON, a JSON array, and an unknown event type.

  Subprocess exit is deliberately absent. `ExMCP.ACP.Adapters.ClaudeSDK`
  is not adapter-managed: `command/1` returns an executable for the bridge
  to spawn and the adapter implements neither `handle_adapter_message/2`
  nor `shutdown/1`, so port exit, port close and partial-line buffering are
  owned by `ExMCP.ACP.AdapterBridge` and covered by its own tests. There is
  no adapter callback this gate could drive to observe them.

  Mutation check (2026-09-21): in `claude_sdk.ex`, making
  `handle_notification("session/cancel", ...)` skip the queue sweep
  (returning `{:ok, data, state}` without calling `cancel_queued_prompts/2`)
  fails `cancel_answers_every_queued_prompt`.

  To regenerate a fixture after an intentional behavior change, run the test
  with `CLAUDE_GOLDEN=update mix test <this file>[:line]`; that run rewrites
  the fixture and fails on purpose, so review the diff and re-run without
  the variable to confirm.
  """

  use ExUnit.Case, async: true

  alias ExMCP.Test.ClaudeGolden
  alias ExMCP.Test.ClaudeGolden.Flows

  @area "faults"

  describe "cancellation" do
    test "cancel_writes_the_interrupt_control_request" do
      steps = turn() ++ [Flows.cancel()]

      transcript =
        ClaudeGolden.assert_golden(@area, "cancel_writes_the_interrupt_control_request", steps)

      assert %{tag: :ok, writes: [%{"request" => %{"subtype" => "interrupt"}}]} =
               ClaudeGolden.last_result(transcript)
    end

    test "cancel_answers_every_queued_prompt" do
      steps =
        turn() ++
          [
            Flows.prompt("acp-prompt-2", "second"),
            Flows.prompt("acp-prompt-3", "third"),
            Flows.cancel()
          ]

      transcript = ClaudeGolden.assert_golden(@area, "cancel_answers_every_queued_prompt", steps)

      assert %{tag: :messages_and_write, messages: messages} =
               ClaudeGolden.last_result(transcript)

      assert Enum.map(messages, & &1["id"]) == ["acp-prompt-2", "acp-prompt-3"]
      assert Enum.all?(messages, &(&1["result"]["stopReason"] == "cancelled"))
    end

    test "cancel_leaves_the_active_prompt_for_claude_to_settle" do
      steps =
        turn() ++
          [
            Flows.cancel(),
            {:note, "Claude answers the interrupted turn with its own result"},
            Flows.result(%{"stop_reason" => "cancelled"})
          ]

      transcript =
        ClaudeGolden.assert_golden(
          @area,
          "cancel_leaves_the_active_prompt_for_claude_to_settle",
          steps
        )

      assert [%{"id" => "acp-prompt", "result" => %{"stopReason" => "cancelled"}}] =
               prompt_responses(transcript)
    end

    test "cancel_without_a_session_id_uses_the_active_prompt_session" do
      steps = turn() ++ [Flows.cancel(%{})]

      ClaudeGolden.assert_golden(
        @area,
        "cancel_without_a_session_id_uses_the_active_prompt_session",
        steps
      )
    end

    test "cancel_for_another_session_keeps_the_queue" do
      steps =
        turn() ++
          [
            Flows.prompt("acp-prompt-2", "second"),
            Flows.cancel(%{"sessionId" => "other-session"}),
            {:note, "The queued prompt survived and still drains on the next result"},
            Flows.result()
          ]

      ClaudeGolden.assert_golden(@area, "cancel_for_another_session_keeps_the_queue", steps)
    end

    test "cancel_without_any_session_still_interrupts" do
      steps = [Flows.cancel(%{})]

      transcript =
        ClaudeGolden.assert_golden(@area, "cancel_without_any_session_still_interrupts", steps)

      assert %{tag: :ok, writes: [%{"request" => %{"subtype" => "interrupt"}}]} =
               ClaudeGolden.last_result(transcript)
    end

    test "cancel_forgets_deferred_background_work" do
      steps =
        turn() ++
          [
            Flows.system("task_started", %{
              "task_id" => "task-1",
              "subagent_type" => "explorer",
              "description" => "Explore"
            }),
            Flows.result(),
            {:note, "The deferred result is dropped, so the next result settles the prompt"},
            Flows.cancel(),
            Flows.result()
          ]

      transcript =
        ClaudeGolden.assert_golden(@area, "cancel_forgets_deferred_background_work", steps)

      assert length(prompt_responses(transcript)) == 1
    end

    test "the_interrupt_response_is_consumed_silently" do
      steps = turn() ++ [Flows.cancel(), {:respond_control, "interrupt", %{}}]

      transcript =
        ClaudeGolden.assert_golden(@area, "the_interrupt_response_is_consumed_silently", steps)

      assert %{tag: :skip} = ClaudeGolden.last_result(transcript)
    end

    test "a_control_error_response_is_consumed_silently" do
      steps =
        turn() ++ [Flows.cancel(), {:respond_control_error, "interrupt", "no turn in flight"}]

      ClaudeGolden.assert_golden(@area, "a_control_error_response_is_consumed_silently", steps)
    end
  end

  describe "prompt queue" do
    test "a_second_prompt_is_queued_rather_than_written" do
      steps = turn() ++ [Flows.prompt("acp-prompt-2", "second")]

      transcript =
        ClaudeGolden.assert_golden(@area, "a_second_prompt_is_queued_rather_than_written", steps)

      assert %{tag: :ok, skipped: true} = ClaudeGolden.last_result(transcript)
    end

    test "queued_prompts_drain_in_order" do
      steps =
        turn() ++
          [
            Flows.prompt("acp-prompt-2", "second"),
            Flows.prompt("acp-prompt-3", "third"),
            Flows.result(),
            Flows.result(),
            Flows.result()
          ]

      transcript = ClaudeGolden.assert_golden(@area, "queued_prompts_drain_in_order", steps)

      assert Enum.map(prompt_responses(transcript), & &1["id"]) == [
               "acp-prompt",
               "acp-prompt-2",
               "acp-prompt-3"
             ]
    end

    test "session_close_cancels_the_queue" do
      steps =
        turn() ++ [Flows.prompt("acp-prompt-2", "second"), Flows.session_close("acp-close")]

      transcript = ClaudeGolden.assert_golden(@area, "session_close_cancels_the_queue", steps)

      assert %{messages: messages} = ClaudeGolden.last_result(transcript)
      assert Enum.map(messages, & &1["id"]) == ["acp-prompt", "acp-prompt-2"]
    end

    test "session_delete_cancels_the_queue" do
      session = Flows.session_uuid(1)

      steps =
        [
          Flows.session_jsonl(session, Flows.summary_entries("delete me")),
          Flows.session_resume("acp-resume", session),
          Flows.prompt("acp-prompt", "first"),
          Flows.prompt("acp-prompt-2", "second"),
          {:outbound,
           %{
             "jsonrpc" => "2.0",
             "id" => "acp-delete",
             "method" => "session/delete",
             "params" => %{"sessionId" => session, "cwd" => Flows.cwd()}
           }}
        ]

      ClaudeGolden.assert_golden(@area, "session_delete_cancels_the_queue", steps)
    end

    test "a_queued_prompt_for_another_session_is_kept_by_a_scoped_cancel" do
      steps =
        turn() ++
          [
            Flows.prompt("acp-prompt-2", "second", %{"sessionId" => "other-session"}),
            Flows.cancel(),
            {:note, "The other session's prompt is still queued"},
            Flows.result()
          ]

      ClaudeGolden.assert_golden(
        @area,
        "a_queued_prompt_for_another_session_is_kept_by_a_scoped_cancel",
        steps
      )
    end
  end

  describe "control requests" do
    test "read_file_round_trips_through_the_client" do
      steps =
        turn() ++
          [
            Flows.read_file_request(),
            Flows.reply_last(%{"content" => "# Notes\n"})
          ]

      transcript =
        ClaudeGolden.assert_golden(@area, "read_file_round_trips_through_the_client", steps)

      assert [%{"method" => "fs/read_text_file"}] = acp_requests(transcript)

      assert %{writes: [%{"response" => %{"response" => %{"contents" => "# Notes\n"}}}]} =
               ClaudeGolden.last_result(transcript)
    end

    test "read_file_accepts_the_contents_spelling_and_abs_path" do
      steps =
        turn() ++
          [
            Flows.read_file_request(),
            Flows.reply_last(%{"contents" => "body", "absPath" => "/elsewhere/notes.md"})
          ]

      ClaudeGolden.assert_golden(
        @area,
        "read_file_accepts_the_contents_spelling_and_abs_path",
        steps
      )
    end

    test "read_file_without_content_answers_empty" do
      steps = turn() ++ [Flows.read_file_request(), Flows.reply_last(%{})]

      ClaudeGolden.assert_golden(@area, "read_file_without_content_answers_empty", steps)
    end

    test "read_file_honors_the_max_bytes_limit" do
      steps =
        turn() ++
          [
            {:note,
             "ACP has line/limit fields rather than a byte cap; the adapter retains " <>
               "max_bytes and validates the correlated response before answering Claude"},
            Flows.read_file_request("req-read", %{"max_bytes" => 4}),
            Flows.reply_last(%{"content" => "body"})
          ]

      transcript =
        ClaudeGolden.assert_golden(@area, "read_file_honors_the_max_bytes_limit", steps)

      assert [%{"params" => params}] = acp_requests(transcript)
      assert Map.keys(params) == ["path", "sessionId"]

      assert %{writes: [%{"response" => %{"response" => %{"contents" => "body"}}}]} =
               ClaudeGolden.last_result(transcript)
    end

    test "a_read_file_error_becomes_a_control_error" do
      steps =
        turn() ++
          [
            Flows.read_file_request(),
            Flows.error_reply(%{"code" => -32_002, "message" => "permission denied"})
          ]

      transcript =
        ClaudeGolden.assert_golden(@area, "a_read_file_error_becomes_a_control_error", steps)

      assert %{writes: [%{"response" => %{"error" => "permission denied"}}]} =
               ClaudeGolden.last_result(transcript)
    end

    test "an_error_without_a_message_uses_the_default_text" do
      steps = turn() ++ [Flows.read_file_request(), Flows.error_reply(%{"code" => -1})]

      ClaudeGolden.assert_golden(@area, "an_error_without_a_message_uses_the_default_text", steps)
    end

    test "an_unsupported_control_subtype_is_refused" do
      steps =
        turn() ++
          [
            {:inbound,
             %{
               "type" => "control_request",
               "request_id" => "req-x",
               "request" => %{"subtype" => "hook_callback", "callback_id" => "h1"}
             }}
          ]

      transcript =
        ClaudeGolden.assert_golden(@area, "an_unsupported_control_subtype_is_refused", steps)

      assert %{tag: :skip_and_write, writes: [%{"response" => %{"subtype" => "error"}}]} =
               ClaudeGolden.last_result(transcript)
    end

    test "a_malformed_control_request_is_refused" do
      steps =
        turn() ++
          [
            {:inbound,
             %{"type" => "control_request", "request_id" => "req-y", "request" => %{"no" => 1}}}
          ]

      transcript =
        ClaudeGolden.assert_golden(@area, "a_malformed_control_request_is_refused", steps)

      assert %{writes: [%{"response" => %{"error" => "Malformed Claude SDK control request"}}]} =
               ClaudeGolden.last_result(transcript)
    end

    test "a_control_request_without_a_request_key_is_skipped" do
      steps =
        turn() ++ [{:inbound, %{"type" => "control_request", "request_id" => "req-z"}}]

      ClaudeGolden.assert_golden(
        @area,
        "a_control_request_without_a_request_key_is_skipped",
        steps
      )
    end
  end

  describe "late and unknown responses" do
    test "a_cancelled_client_request_drops_its_late_reply" do
      steps =
        turn() ++
          [
            Flows.can_use_tool("req-1"),
            Flows.control_cancel("req-1"),
            {:note, "The pending request is gone, so the client's reply writes nothing"},
            Flows.select("allow_once")
          ]

      transcript =
        ClaudeGolden.assert_golden(
          @area,
          "a_cancelled_client_request_drops_its_late_reply",
          steps
        )

      assert %{tag: :ok, skipped: true} = ClaudeGolden.last_result(transcript)
    end

    test "a_control_cancel_for_an_unknown_request_changes_nothing" do
      steps =
        turn() ++
          [
            Flows.can_use_tool("req-1"),
            Flows.control_cancel("req-does-not-exist"),
            Flows.select("allow_once")
          ]

      ClaudeGolden.assert_golden(
        @area,
        "a_control_cancel_for_an_unknown_request_changes_nothing",
        steps
      )
    end

    test "a_duplicate_reply_is_dropped" do
      steps =
        turn() ++ [Flows.can_use_tool(), Flows.select("allow_once"), Flows.select("reject_once")]

      transcript = ClaudeGolden.assert_golden(@area, "a_duplicate_reply_is_dropped", steps)

      assert %{tag: :ok, skipped: true} = ClaudeGolden.last_result(transcript)
    end

    test "a_reply_for_an_id_that_was_never_issued_is_dropped" do
      steps =
        turn() ++
          [
            Flows.can_use_tool(),
            {:outbound,
             %{
               "jsonrpc" => "2.0",
               "id" => "acp-never-issued",
               "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
             }},
            {:note, "The real request is still pending and can be answered afterwards"},
            Flows.select("allow_once")
          ]

      ClaudeGolden.assert_golden(
        @area,
        "a_reply_for_an_id_that_was_never_issued_is_dropped",
        steps
      )
    end

    test "a_response_that_is_neither_result_nor_error_is_dropped" do
      steps =
        turn() ++
          [
            Flows.can_use_tool(),
            {:outbound, %{"jsonrpc" => "2.0", "id" => "acp-weird", "outcome" => "selected"}}
          ]

      ClaudeGolden.assert_golden(
        @area,
        "a_response_that_is_neither_result_nor_error_is_dropped",
        steps
      )
    end
  end

  describe "skipped traffic" do
    test "unknown_methods_and_notifications_are_skipped" do
      steps =
        turn() ++
          [
            {:outbound,
             %{
               "jsonrpc" => "2.0",
               "id" => "acp-x",
               "method" => "session/unheard_of",
               "params" => %{}
             }},
            {:outbound, %{"jsonrpc" => "2.0", "method" => "notifications/progress"}},
            {:outbound, %{"jsonrpc" => "2.0", "params" => %{"anything" => true}}}
          ]

      transcript =
        ClaudeGolden.assert_golden(@area, "unknown_methods_and_notifications_are_skipped", steps)

      assert [%{tag: :ok, skipped: true}, %{tag: :ok, skipped: true}, %{tag: :ok, skipped: true}] =
               transcript |> Enum.take(-3) |> Enum.map(& &1.result)
    end

    test "unparsable_lines_are_skipped" do
      steps =
        turn() ++
          [
            {:inbound_raw, ""},
            {:inbound_raw, "\n"},
            {:inbound_raw, "   "},
            {:inbound_raw, "{not json"},
            {:inbound_raw, "[1, 2, 3]\n"},
            {:inbound_raw, "\"a string\""}
          ]

      transcript = ClaudeGolden.assert_golden(@area, "unparsable_lines_are_skipped", steps)

      assert ClaudeGolden.messages(transcript) == []
    end

    test "an_initialize_request_is_answered_by_the_bridge" do
      steps = [
        {:note, "initialize only captures client capabilities; the bridge replies"},
        Flows.initialize("acp-init", %{"elicitation" => %{"form" => %{}}})
      ]

      transcript =
        ClaudeGolden.assert_golden(
          @area,
          "an_initialize_request_is_answered_by_the_bridge",
          steps
        )

      assert %{tag: :ok, skipped: true} = ClaudeGolden.last_result(transcript)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp turn do
    [Flows.session_new(), Flows.prompt("acp-prompt", "first")]
  end

  defp acp_requests(transcript) do
    transcript
    |> ClaudeGolden.messages()
    |> Enum.filter(&(Map.has_key?(&1, "method") and Map.has_key?(&1, "id")))
  end

  defp prompt_responses(transcript) do
    transcript
    |> ClaudeGolden.messages()
    |> Enum.filter(&(Map.has_key?(&1, "result") and String.starts_with?(&1["id"], "acp-prompt")))
  end
end
