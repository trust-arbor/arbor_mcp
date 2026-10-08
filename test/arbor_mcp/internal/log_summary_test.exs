defmodule Arbor.RPC.LogSummaryTest do
  use ExUnit.Case, async: true

  alias Arbor.RPC.LogSummary

  test "summaries never render nested values" do
    secret = "sentinel-super-secret"

    for term <- [
          %{"access_token" => secret},
          {:error, secret},
          [secret],
          secret
        ] do
      summary = LogSummary.describe(term)
      refute summary =~ secret
    end
  end

  test "fingerprints are stable without rendering identifiers" do
    identifier = "private-request-id"
    fingerprint = LogSummary.fingerprint(identifier)

    assert fingerprint == LogSummary.fingerprint(identifier)
    refute fingerprint =~ identifier
    assert byte_size(fingerprint) == 16
  end
end
