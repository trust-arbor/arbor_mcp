defmodule ExMCP.ACP.Adapters.ZCode.CompatibilityTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Adapters.ZCode
  alias ExMCP.ACP.Adapters.ZCode.{Config, Mapper, Sessions}

  defp model(id, levels \\ ["low", "high"]) do
    %{
      "ref" => %{"providerId" => "provider", "modelId" => id},
      "label" => String.upcase(id),
      "reasoning" => %{
        "levels" => Enum.map(levels, &%{"value" => &1, "label" => &1}),
        "defaultLevel" => List.first(levels)
      }
    }
  end

  defp snapshot(id, models, current) do
    %{
      "session" => %{"sessionId" => id, "mode" => "build"},
      "settings" => %{
        "model" => %{"available" => models, "current" => current},
        "thoughtLevel" => %{
          "available" => [
            %{"value" => "low", "label" => "Low"},
            %{"value" => "high", "label" => "High"}
          ],
          "current" => "high",
          "defaultLevel" => "low",
          "enabled" => true
        }
      }
    }
  end

  defp state_with_sessions do
    {:ok, state} = ZCode.init(cwd: "/tmp")

    first =
      Sessions.from_snapshot(
        "first",
        snapshot("first", [model("one"), model("two")], model("one")["ref"]),
        state
      )

    second =
      Sessions.from_snapshot(
        "second",
        snapshot("second", [model("other")], model("other")["ref"]),
        state
      )

    state |> Sessions.put("first", first) |> Sessions.put("second", second)
  end

  defp option(session, id), do: Enum.find(Config.config_options(session), &(&1["id"] == id))
  defp wire(data), do: data |> IO.iodata_to_binary() |> Jason.decode!()

  test "current create snapshots expose model and reasoning choices before ACP session reply" do
    {:ok, state} = ZCode.init(cwd: "/tmp")
    state = %{state | pending_requests: %{1 => %{type: :session_create, acp_id: 101, meta: %{}}}}
    native = snapshot("first", [model("one"), model("two")], model("two")["ref"])
    native = put_in(native, ["settings", "mode"], %{"current" => "plan"})

    {[response], [_subscribe], state} =
      Mapper.reduce_message(%{"id" => 1, "result" => native}, state)

    options = response["result"]["configOptions"]
    selected = Enum.find(options, &(&1["id"] == "model"))
    thought = Enum.find(options, &(&1["id"] == "thought_level"))

    assert response["id"] == 101
    assert response["result"]["modes"]["currentModeId"] == "plan"
    assert selected["currentValue"] == "provider/two"
    assert Enum.map(selected["options"], & &1["value"]) == ["provider/one", "provider/two"]
    assert thought["currentValue"] == "high"
    assert Enum.map(thought["options"], & &1["value"]) == ["low", "high"]
    assert state.models == []
  end

  test "partial native settings keep the full catalog and affect only their session" do
    state = state_with_sessions()
    second = state.sessions["second"]

    patch = %{
      "model" => %{
        "available" => [Map.put(model("two"), "contextWindow", 8192)],
        "current" => model("two")["ref"]
      },
      "thoughtLevel" => %{"current" => "low"}
    }

    message = %{
      "method" => "state.updated",
      "params" => %{"scope" => "session", "sessionId" => "first", "patch" => patch}
    }

    {[_update], [], updated} = Mapper.reduce_message(message, state)
    assert length(updated.sessions["first"].models) == 2
    assert option(updated.sessions["first"], "model")["currentValue"] == "provider/two"
    assert option(updated.sessions["first"], "thought_level")["currentValue"] == "low"
    assert Enum.at(updated.sessions["first"].models, 1)["contextWindow"] == 8192
    assert updated.sessions["second"] == second
    assert {[], [], ^updated} = Mapper.reduce_message(message, updated)

    unknown = put_in(message, ["params", "sessionId"], "unknown")
    assert {[], [], ^state} = Mapper.reduce_message(unknown, state)
  end

  test "legacy flat catalogs and snapshots remain usable" do
    {:ok, state} = ZCode.init(cwd: "/tmp")

    state = %{
      state
      | pending_requests: %{1 => %{type: :workspace_read_state, acp_id: nil, meta: %{}}}
    }

    legacy = %{
      "modelCatalog" => %{
        "available" => [%{"providerId" => "old", "modelId" => "flat", "name" => "Flat"}]
      }
    }

    {[], [], state} = Mapper.reduce_message(%{"id" => 1, "result" => legacy}, state)

    session =
      Sessions.from_snapshot(
        "old",
        %{"session" => %{"model" => %{"providerId" => "old", "modelId" => "flat"}}},
        state
      )

    assert option(session, "model")["currentValue"] == "old/flat"
    assert hd(option(session, "model")["options"])["name"] == "Flat"
    assert option(session, "thought_level")["currentValue"] == "medium"
    state = Sessions.put(state, "old", session)

    {:pending_and_write, data, _pending} =
      ZCode.translate_outbound(
        %{
          "id" => 50,
          "method" => "session/set_model",
          "params" => %{"sessionId" => "old", "modelId" => "flat"}
        },
        state
      )

    assert wire(data)["params"]["model"] == %{"providerId" => "old", "modelId" => "flat"}
  end

  test "config model forwarding preserves session and request IDs and native rejection" do
    state = state_with_sessions()

    request = %{
      "id" => 51,
      "method" => "session/set_config_option",
      "params" => %{"sessionId" => "first", "configId" => "model", "value" => "two"}
    }

    {:pending_and_write, data, pending} = ZCode.translate_outbound(request, state)
    native = wire(data)

    assert native["params"]["sessionId"] == "first"

    assert native["params"]["model"] == %{
             "providerId" => "provider",
             "modelId" => "two",
             "options" => %{"reasoningLevel" => "high"}
           }

    assert pending.sessions == state.sessions
    error = %{"code" => -32_602, "message" => "unsupported native selection"}

    {[reply], [], failed} =
      Mapper.reduce_message(%{"id" => native["id"], "error" => error}, pending)

    assert reply["id"] == 51
    assert reply["error"] == error
    assert failed.sessions == state.sessions

    assert {[], [], ^failed} =
             Mapper.reduce_message(%{"id" => native["id"], "result" => %{}}, failed)
  end

  test "model success merges a current-only snapshot and settles once" do
    state = state_with_sessions()

    request = %{
      "id" => 52,
      "method" => "session/set_model",
      "params" => %{"sessionId" => "first", "modelId" => "two"}
    }

    {:pending_and_write, data, pending} = ZCode.translate_outbound(request, state)
    native = wire(data)

    result = %{
      "settings" => %{
        "model" => %{"available" => [model("two")], "current" => native["params"]["model"]}
      }
    }

    {messages, [], updated} =
      Mapper.reduce_message(%{"id" => native["id"], "result" => result}, pending)

    assert [%{"id" => 52, "result" => %{}}] = Enum.filter(messages, &Map.has_key?(&1, "id"))
    assert length(updated.sessions["first"].models) == 2
    assert updated.sessions["first"].model_ref["modelId"] == "two"
    assert updated.sessions["second"] == state.sessions["second"]

    assert {[], [], ^updated} =
             Mapper.reduce_message(%{"id" => native["id"], "result" => result}, updated)
  end

  test "required reasoning uses a supported default and rejects invalid explicit choices" do
    state = state_with_sessions()
    state = Sessions.update(state, "first", &Map.put(&1, :thought_level, "unsupported"))

    request = %{
      "id" => 53,
      "method" => "session/set_model",
      "params" => %{"sessionId" => "first", "modelId" => "two"}
    }

    {:pending_and_write, data, _pending} = ZCode.translate_outbound(request, state)
    assert wire(data)["params"]["model"]["options"]["reasoningLevel"] == "low"

    invalid = %{
      "id" => 54,
      "method" => "session/set_config_option",
      "params" => %{"sessionId" => "first", "configId" => "thought_level", "value" => "extreme"}
    }

    assert {:error, "Unsupported ZCode thought level: \"extreme\"", ^state} =
             ZCode.translate_outbound(invalid, state)

    valid = put_in(invalid, ["params", "value"], "low")
    {:pending_and_write, data, pending} = ZCode.translate_outbound(valid, state)
    native = wire(data)
    assert native["params"] == %{"sessionId" => "first", "thoughtLevel" => "low"}

    {messages, [], updated} =
      Mapper.reduce_message(%{"id" => native["id"], "result" => %{}}, pending)

    response = Enum.find(messages, &(&1["id"] == 54))
    assert response["result"]["configOptions"] == Config.config_options(updated.sessions["first"])
    assert updated.sessions["first"].thought_level == "low"
    assert updated.sessions["second"] == state.sessions["second"]
  end

  test "empty reasoning catalog is not replaced with invented choices" do
    state = state_with_sessions()

    session =
      Config.apply_settings(state.sessions["first"], %{
        "thoughtLevel" => %{"available" => [], "enabled" => false}
      })

    refute option(session, "thought_level")
    refute Config.valid_thought_level?(session, "high")
  end

  test "failed setter writes retire only their correlation without reusing native IDs" do
    state = state_with_sessions()
    state = %{state | pending_requests: %{999 => %{type: :session_read, acp_id: 998, meta: %{}}}}

    Enum.reduce(61..69, state, fn acp_id, previous ->
      request = %{
        "id" => acp_id,
        "method" => "session/set_model",
        "params" => %{"sessionId" => "first", "modelId" => "two"}
      }

      {:pending_and_write, data, pending} = ZCode.translate_outbound(request, previous)
      native_id = wire(data)["id"]
      failed = ZCode.outbound_write_failed(request, :write_too_large, pending)
      assert failed.pending_requests == previous.pending_requests
      assert failed.sessions == previous.sessions
      assert failed.next_id == previous.next_id + 1

      assert {[], [], ^failed} =
               Mapper.reduce_message(%{"id" => native_id, "result" => %{}}, failed)

      failed
    end)
  end

  test "client timeout cancellation retires a setter and ignores its late native result" do
    state = state_with_sessions()

    request = %{
      "id" => 70,
      "method" => "session/set_model",
      "params" => %{"sessionId" => "first", "modelId" => "two"}
    }

    {:pending_and_write, data, pending} = ZCode.translate_outbound(request, state)
    native_id = wire(data)["id"]
    cancel = %{"method" => "$/cancel_request", "params" => %{"requestId" => 70}}
    {:ok, :skip, cancelled} = ZCode.translate_outbound(cancel, pending)
    assert cancelled.pending_requests == %{}
    assert cancelled.next_id == pending.next_id
    assert cancelled.sessions == state.sessions

    assert {[], [], ^cancelled} =
             Mapper.reduce_message(%{"id" => native_id, "result" => %{}}, cancelled)
  end

  test "a default model cannot override a later native per-session selection on prompt" do
    state = state_with_sessions()
    state = %{state | model: "provider/initial"}

    request = %{
      "id" => 55,
      "method" => "session/prompt",
      "params" => %{"sessionId" => "first", "prompt" => [%{"type" => "text", "text" => "hello"}]}
    }

    {:ok, data, _state} = ZCode.translate_outbound(request, state)
    refute Map.has_key?(wire(data)["params"], "runtimeModel")
    refute Map.has_key?(wire(data)["params"], "modelSelection")
  end

  test "explicit prompt model strings use the session catalog and current native field" do
    state = state_with_sessions()

    for model <- ["two", "provider/two"] do
      request = %{
        "id" => 80,
        "method" => "session/prompt",
        "params" => %{"sessionId" => "first", "prompt" => "hello", "model" => model}
      }

      {:ok, data, updated} = ZCode.translate_outbound(request, state)

      assert wire(data)["params"] == %{
               "sessionId" => "first",
               "content" => "hello",
               "modelSelection" => %{
                 "providerId" => "provider",
                 "modelId" => "two",
                 "options" => %{"reasoningLevel" => "high"}
               }
             }

      assert updated.sessions["first"].model_ref == state.sessions["first"].model_ref
      assert updated.sessions["first"].thought_level == state.sessions["first"].thought_level
      assert updated.sessions["second"] == state.sessions["second"]
    end

    other = %{
      "id" => 81,
      "method" => "session/prompt",
      "params" => %{"sessionId" => "first", "prompt" => "hello", "model" => "other"}
    }

    assert {:error, "Unknown modelId: other", ^state} = ZCode.translate_outbound(other, state)
  end

  test "typed prompt selection preserves an explicit supported reasoning choice" do
    state = state_with_sessions()

    ref = %{
      "providerId" => " provider ",
      "modelId" => "two",
      "options" => %{"reasoningLevel" => " low "}
    }

    request = %{
      "id" => 82,
      "method" => "session/prompt",
      "params" => %{"sessionId" => "first", "prompt" => "hello", "model" => ref}
    }

    {:ok, data, _state} = ZCode.translate_outbound(request, state)

    assert wire(data)["params"]["modelSelection"] == %{
             "providerId" => "provider",
             "modelId" => "two",
             "options" => %{"reasoningLevel" => "low"}
           }

    refute Map.has_key?(wire(data)["params"], "runtimeModel")

    state = Sessions.update(state, "first", &Map.put(&1, :thought_level, "unsupported"))

    request =
      put_in(request, ["params", "model"], %{"providerId" => "provider", "modelId" => "two"})

    {:ok, data, _state} = ZCode.translate_outbound(request, state)
    assert wire(data)["params"]["modelSelection"]["options"]["reasoningLevel"] == "low"
  end

  test "invalid explicit prompt selections cannot write or enter the prompt queue" do
    for active <- [nil, 900] do
      state =
        state_with_sessions()
        |> Sessions.update("first", &Map.put(&1, :active_prompt_acp_id, active))

      ref = %{
        "providerId" => "provider",
        "modelId" => "two",
        "options" => %{"reasoningLevel" => "extreme"}
      }

      request = %{
        "id" => 83,
        "method" => "session/prompt",
        "params" => %{"sessionId" => "first", "prompt" => "hello", "model" => ref}
      }

      assert {:error, "Unsupported ZCode model reasoning level: \"extreme\"", ^state} =
               ZCode.translate_outbound(request, state)

      for invalid <- [
            42,
            Map.put(ref, "extra", true),
            Map.put(ref, "providerId", " "),
            Map.put(ref, "options", nil),
            put_in(ref, ["options", "reasoningLevel"], "")
          ] do
        invalid_request = put_in(request, ["params", "model"], invalid)

        assert {:error, "Invalid ZCode prompt model selection", ^state} =
                 ZCode.translate_outbound(invalid_request, state)
      end
    end
  end

  test "queued prompt overrides retain their typed selection when the preceding turn completes" do
    state =
      state_with_sessions() |> Sessions.update("first", &Map.put(&1, :active_prompt_acp_id, 900))

    request = %{
      "id" => 84,
      "method" => "session/prompt",
      "params" => %{"sessionId" => "first", "prompt" => "queued", "model" => "two"}
    }

    {:messages, _notices, queued} = ZCode.translate_outbound(request, state)
    queued = Sessions.update(queued, "first", &Map.put(&1, :thought_level, "low"))

    completed = %{
      "method" => "session/event",
      "params" => %{
        "type" => "turn.completed",
        "sessionId" => "first",
        "payload" => %{"resultType" => "success"}
      }
    }

    {_messages, [data], updated} = Mapper.reduce_message(completed, queued)

    assert wire(data)["params"]["modelSelection"] == %{
             "providerId" => "provider",
             "modelId" => "two",
             "options" => %{"reasoningLevel" => "high"}
           }

    assert wire(data)["params"]["content"] == "queued"
    refute Map.has_key?(wire(data)["params"], "runtimeModel")
    assert updated.sessions["first"].active_prompt_acp_id == 84
    assert updated.sessions["second"] == state.sessions["second"]
  end

  test "legacy catalogs with no reasoning metadata do not invent a prompt reasoning level" do
    {:ok, state} = ZCode.init(cwd: "/tmp")
    state = Sessions.put(state, "old", Sessions.empty("old", state))

    request = %{
      "id" => 85,
      "method" => "session/prompt",
      "params" => %{"sessionId" => "old", "prompt" => "hello", "model" => "provider/explicit"}
    }

    {:ok, data, _state} = ZCode.translate_outbound(request, state)

    assert wire(data)["params"]["modelSelection"] == %{
             "providerId" => "provider",
             "modelId" => "explicit"
           }

    explicit =
      put_in(request, ["params", "model"], %{
        "providerId" => "provider",
        "modelId" => "explicit",
        "options" => %{"reasoningLevel" => "custom"}
      })

    {:ok, data, _state} = ZCode.translate_outbound(explicit, state)
    assert wire(data)["params"]["modelSelection"]["options"]["reasoningLevel"] == "custom"
  end
end
