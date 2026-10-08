defmodule Arbor.MCP.Content.Validation.Security do
  @moduledoc false
  # Security scanning implementations extracted from Content.Validation.

  alias Arbor.MCP.Content.Validation.Helpers

  def perform_scan(content, scan_type) do
    case scan_type do
      :malware -> scan_malware(content)
      :xss -> scan_xss(content)
      :sql_injection -> scan_sql_injection(content)
      _ -> :safe
    end
  end

  def detect_sensitive(content) do
    text = Helpers.extract_text(content)

    sensitive_patterns = [
      {:credit_card, ~r/\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b/},
      {:ssn, ~r/\b\d{3}-\d{2}-\d{4}\b/},
      {:email, ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/},
      {:phone, ~r/\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/},
      {:api_key, ~r/\b[A-Za-z0-9]{32,}\b/}
    ]

    detected =
      sensitive_patterns
      |> Enum.filter(fn {_type, pattern} -> Regex.match?(pattern, text) end)
      |> Enum.map(fn {type, _pattern} -> type end)

    case detected do
      [] -> :ok
      types -> {:sensitive, types}
    end
  end

  defp scan_malware(content) do
    text = Helpers.extract_text(content)

    malicious_patterns = [
      "eval(",
      "document.write",
      "<iframe",
      "javascript:",
      "vbscript:",
      "onload=",
      "onerror="
    ]

    detected = Enum.find(malicious_patterns, &String.contains?(text, &1))

    if detected do
      {:threat, "Potentially malicious pattern detected: #{detected}"}
    else
      :safe
    end
  end

  defp scan_xss(content) do
    text = Helpers.extract_text(content)

    xss_patterns = [
      ~r/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/mi,
      ~r/javascript\s*:/i,
      ~r/on\w+\s*=/i
    ]

    detected = Enum.find(xss_patterns, &Regex.match?(&1, text))

    if detected do
      {:threat, "Potential XSS attack detected"}
    else
      :safe
    end
  end

  defp scan_sql_injection(content) do
    text = Helpers.extract_text(content)

    sql_patterns = [
      ~r/union\s+select/i,
      ~r/or\s+1\s*=\s*1/i,
      ~r/drop\s+table/i,
      ~r/insert\s+into/i,
      ~r/delete\s+from/i
    ]

    detected = Enum.find(sql_patterns, &Regex.match?(&1, text))

    if detected do
      {:threat, "Potential SQL injection detected"}
    else
      :safe
    end
  end
end
