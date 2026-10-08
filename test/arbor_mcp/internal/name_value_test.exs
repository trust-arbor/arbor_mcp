defmodule Arbor.MCP.Internal.NameValueTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.Internal.NameValue

  test "normalizes maps and lists into name/value lists" do
    assert NameValue.list(%{PATH: "/bin"}) == [%{"name" => "PATH", "value" => "/bin"}]

    assert NameValue.list([%{name: :TERM, value: :dumb}, {"HOME", "/tmp"}]) == [
             %{"name" => "TERM", "value" => "dumb"},
             %{"name" => "HOME", "value" => "/tmp"}
           ]
  end

  test "normalizes maps and lists into maps" do
    assert NameValue.map([%{"name" => :TERM, "value" => :dumb}, {:HOME, "/tmp"}]) == %{
             "TERM" => "dumb",
             "HOME" => "/tmp"
           }
  end

  test "converts normalized values into charlist pairs" do
    assert NameValue.charlist_pairs(%{TERM: :dumb}) == [{~c"TERM", ~c"dumb"}]
  end

  test "preserves list order and duplicate names for charlist pairs" do
    assert NameValue.charlist_pairs([{"x-test", "a"}, {"x-test", "b"}]) == [
             {~c"x-test", ~c"a"},
             {~c"x-test", ~c"b"}
           ]
  end
end
