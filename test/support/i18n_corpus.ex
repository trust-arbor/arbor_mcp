defmodule Arbor.MCP.Test.I18nCorpus do
  @moduledoc """
  Non-ASCII payloads every transport must carry byte-exact.

  One corpus, reused by the stdio, HTTP, and in-process transport
  tests, so a regression in any one path shows up against the same data.
  """

  @bom <<0xEF, 0xBB, 0xBF>>

  @strings [
    {"latin1 range", "café"},
    {"cjk", "日本語"},
    {"astral emoji", "🪁"},
    {"joiner sequence", <<"👨", 0x200D::utf8, "👩", 0x200D::utf8, "👧">>},
    {"combining marks, decomposed", <<"e", 0x0301::utf8>>},
    {"right-to-left with bidi controls", <<0x202B::utf8, "شكرا", 0x202C::utf8>>},
    {"line separator", <<"a", 0x2028::utf8, "b">>},
    {"mixed", "café 日本語 🪁"}
  ]

  @doc "Labeled strings, each a distinct class of non-ASCII content."
  @spec strings() :: [{String.t(), String.t()}]
  def strings, do: @strings

  @doc "Every corpus string joined, for a tool that generates its own text."
  @spec all_text() :: String.t()
  def all_text, do: Enum.map_join(@strings, " ", &elem(&1, 1))

  @doc """
  A JSON document with every non-ASCII character written as a `\\u` escape,
  astral characters as surrogate pairs, as some SDKs emit.
  """
  @spec surrogate_escaped_json(map()) :: String.t()
  def surrogate_escaped_json(map), do: Jason.encode!(map, escape: :unicode_safe)

  @doc "A multibyte payload padded to exactly `bytes` bytes, for limit tests."
  @spec multibyte_of_size(pos_integer()) :: String.t()
  def multibyte_of_size(bytes) when bytes >= 4 do
    emoji = "🪁"
    reps = div(bytes, byte_size(emoji))
    padding = String.duplicate("x", bytes - reps * byte_size(emoji))
    String.duplicate(emoji, reps) <> padding
  end

  @doc "The UTF-8 byte-order mark."
  @spec bom() :: binary()
  def bom, do: @bom

  @doc "A JSON-RPC line whose string content is not valid UTF-8."
  @spec invalid_utf8_frame() :: binary()
  def invalid_utf8_frame,
    do: ~S({"jsonrpc":"2.0","method":"notifications/) <> <<0xE9>> <> ~S("}) <> "\n"
end
