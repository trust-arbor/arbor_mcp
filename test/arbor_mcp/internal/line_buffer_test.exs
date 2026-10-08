defmodule Arbor.RPC.Internal.LineBufferTest do
  use ExUnit.Case, async: true

  alias Arbor.RPC.Internal.LineBuffer

  test "drains complete newline-delimited JSON messages" do
    buffer = ~s({"id":1}\n[{"id":2}]\n)

    assert LineBuffer.drain_json(buffer) == {
             [%{"id" => 1}, [%{"id" => 2}]],
             [],
             ""
           }
  end

  test "keeps partial trailing data" do
    buffer = ~s({"id":1}\n{"id":)

    assert LineBuffer.drain_json(buffer) == {
             [%{"id" => 1}],
             [],
             ~s({"id":)
           }
  end

  test "ignores blank and non-json-looking lines" do
    buffer = "debug log\n\n  not json\n{\"id\":1}\n"

    assert LineBuffer.drain_json(buffer) == {
             [%{"id" => 1}],
             [],
             ""
           }
  end

  test "reports invalid json-looking lines" do
    buffer = "{bad}\n{\"id\":1}\n"

    assert LineBuffer.drain_json(buffer) == {
             [%{"id" => 1}],
             [{:invalid_json, "{bad}"}],
             ""
           }
  end
end
