defmodule ExMCP.Server.Tools.ResponseNormalizerTest do
  use ExUnit.Case, async: true

  alias ExMCP.Server.Tools.ResponseNormalizer

  test "normalizes text responses" do
    assert ResponseNormalizer.normalize("hello") == %{content: [%{type: "text", text: "hello"}]}

    assert ResponseNormalizer.normalize(%{text: "hello"}) == %{
             content: [%{type: "text", text: "hello"}]
           }

    assert ResponseNormalizer.normalize(text: "hello") == %{
             content: [%{type: "text", text: "hello"}]
           }
  end

  test "preserves normalized maps and maps legacy structured content" do
    assert ResponseNormalizer.normalize(%{structuredContent: %{answer: 42}}) == %{
             content: [],
             structuredOutput: %{answer: 42}
           }

    assert ResponseNormalizer.normalize(%{content: [], resourceLinks: []}) == %{
             content: [],
             resourceLinks: []
           }
  end

  test "normalizes error responses" do
    assert ResponseNormalizer.normalize_error("failed") == %{
             content: [%{type: "text", text: "failed"}],
             isError: true
           }

    assert ResponseNormalizer.normalize_error(:badarg) == %{
             content: [%{type: "text", text: ":badarg"}],
             isError: true
           }
  end

  describe "unsupported terms never reach the client verbatim" do
    test "non-map results become a fixed error without the term" do
      secret = %{token: "sk-live-SECRET", pid: self()}
      result = ResponseNormalizer.normalize({:ok, secret})

      assert result.isError == true
      assert [%{type: "text", text: text}] = result.content
      refute text =~ "SECRET"
      refute text =~ "sk-live"
    end

    test "error reasons: binaries, atoms and messages pass; other terms are replaced" do
      assert %{content: [%{text: "boom"}], isError: true} =
               ResponseNormalizer.normalize_error("boom")

      assert %{content: [%{text: ":timeout"}]} = ResponseNormalizer.normalize_error(:timeout)

      assert %{content: [%{text: "bad arg"}]} =
               ResponseNormalizer.normalize_error(%ArgumentError{message: "bad arg"})

      %{content: [%{text: text}], isError: true} =
        ResponseNormalizer.normalize_error({:db_error, %{password: "hunter2"}})

      refute text =~ "hunter2"
    end
  end
end
