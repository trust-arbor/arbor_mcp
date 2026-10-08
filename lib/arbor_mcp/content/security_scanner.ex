defmodule Arbor.MCP.Content.SecurityScanner do
  @moduledoc """
  Security scanning utilities for MCP content.

  This module handles all security-related content analysis including
  malware detection, sensitive data scanning, and threat analysis.
  Extracted from the original Content.Validation module.
  """

  alias Arbor.MCP.Content.Protocol

  @typedoc "Security scan type"
  @type scan_type ::
          :malware
          | :sensitive_data
          | :injection_attacks
          | :suspicious_patterns
          | :file_signatures
          | atom()

  @typedoc "Security threat level"
  @type threat_level :: :safe | :low | :medium | :high | :critical

  @typedoc "Security scan result"
  @type scan_result :: %{
          threat_level: threat_level(),
          threats: [threat()],
          metadata: map()
        }

  @typedoc "Detected threat"
  @type threat :: %{
          type: atom(),
          severity: threat_level(),
          description: String.t(),
          location: String.t() | nil,
          confidence: float()
        }

  @doc """
  Scans content for security threats.

  ## Examples

      case SecurityScanner.scan_security(content, [:malware, :sensitive_data]) do
        {:ok, %{threat_level: :safe}} -> 
          process_content(content)
        {:ok, %{threat_level: level, threats: threats}} -> 
          handle_security_threats(level, threats)
        {:error, reason} -> 
          handle_scan_error(reason)
      end
  """
  @spec scan_security(Protocol.content(), [scan_type()]) ::
          {:ok, scan_result()} | {:error, String.t()}
  def scan_security(content, scan_types) when is_list(scan_types) do
    threats = Enum.flat_map(scan_types, &perform_scan(content, &1))
    threat_level = calculate_threat_level(threats)

    {:ok,
     %{
       threat_level: threat_level,
       threats: threats,
       metadata: %{
         scanned_at: DateTime.utc_now(),
         scan_types: scan_types
       }
     }}
  rescue
    e -> {:error, "Security scan failed: #{Exception.message(e)}"}
  end

  @doc """
  Detects sensitive data in content.
  """
  @spec detect_sensitive_data(Protocol.content()) :: [threat()]
  def detect_sensitive_data(%{type: :text, text: text}) do
    patterns = [
      # Credit card patterns
      {~r/\b(?:\d[ -]*?){13,19}\b/, "credit_card", "Possible credit card number"},

      # Social Security Numbers
      {~r/\b\d{3}-\d{2}-\d{4}\b/, "ssn", "Possible Social Security Number"},

      # API keys and tokens
      {~r/\b[A-Za-z0-9_\-]{40,}\b/, "api_key", "Possible API key or token"},

      # Email addresses
      {~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, "email", "Email address"},

      # Phone numbers
      {~r/\b\+?1?\s*\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}\b/, "phone", "Phone number"},

      # AWS keys
      {~r/AKIA[0-9A-Z]{16}/, "aws_key", "Possible AWS access key"},

      # Private keys
      {~r/-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/, "private_key", "Private key detected"}
    ]

    Enum.flat_map(patterns, fn {pattern, type, description} ->
      case Regex.scan(pattern, text) do
        [] ->
          []

        matches ->
          Enum.map(matches, fn [match | _] ->
            %{
              type: :"sensitive_data_#{type}",
              severity: severity_for_data_type(type),
              description: description,
              location: "Found: #{String.slice(match, 0, 10)}...",
              confidence: confidence_for_pattern(type, match)
            }
          end)
      end
    end)
  end

  def detect_sensitive_data(_), do: []

  @doc """
  Scans for injection attack patterns.
  """
  @spec scan_injection_attacks(Protocol.content()) :: [threat()]
  def scan_injection_attacks(%{type: :text, text: text}) do
    patterns = [
      # SQL injection
      {~r/(\bUNION\b.*\bSELECT\b|\bOR\b.*=|\bAND\b.*=|--|\#|\/\*|\*\/)/i, "sql_injection",
       "Possible SQL injection attempt"},

      # XSS attempts
      {~r/<script[^>]*>|javascript:|onerror=|onload=/i, "xss", "Possible XSS attempt"},

      # Command injection
      {~r/[;&|`]\s*(rm|del|format|drop)\s/i, "command_injection", "Possible command injection"},

      # Path traversal
      {~r/\.\.\/|\.\.\\/, "path_traversal", "Possible path traversal attempt"}
    ]

    detect_patterns(text, patterns, :injection_attack)
  end

  def scan_injection_attacks(_), do: []

  @doc """
  Scans for malware signatures.
  """
  @spec scan_malware(Protocol.content()) :: [threat()]
  def scan_malware(%{type: type, data: data}) when type in [:image, :audio] do
    # Check file signatures
    signatures = detect_file_signatures(data)

    Enum.flat_map(signatures, fn sig ->
      if suspicious_signature?(sig) do
        [
          %{
            type: :malware_signature,
            severity: :high,
            description: "Suspicious file signature detected: #{sig}",
            location: "File header",
            confidence: 0.7
          }
        ]
      else
        []
      end
    end)
  end

  def scan_malware(_), do: []

  @doc """
  Analyzes content for suspicious patterns.
  """
  @spec analyze_suspicious_patterns(Protocol.content()) :: [threat()]
  def analyze_suspicious_patterns(%{type: :text, text: text}) do
    patterns = [
      # Obfuscated code
      {~r/eval\s*\(|exec\s*\(|base64_decode/i, "obfuscated_code", "Possible obfuscated code"},

      # Suspicious URLs
      {~r/https?:\/\/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/, "suspicious_url",
       "URL with IP address instead of domain"},

      # Hidden iframes
      {~r/<iframe[^>]*style\s*=\s*["'][^"']*display\s*:\s*none/i, "hidden_iframe",
       "Hidden iframe detected"}
    ]

    detect_patterns(text, patterns, :suspicious_pattern)
  end

  def analyze_suspicious_patterns(_), do: []

  # Private helper functions

  defp perform_scan(content, :malware), do: scan_malware(content)
  defp perform_scan(content, :sensitive_data), do: detect_sensitive_data(content)
  defp perform_scan(content, :injection_attacks), do: scan_injection_attacks(content)
  defp perform_scan(content, :suspicious_patterns), do: analyze_suspicious_patterns(content)
  defp perform_scan(_, _), do: []

  defp detect_patterns(text, patterns, threat_type) do
    Enum.flat_map(patterns, fn {pattern, subtype, description} ->
      if Regex.match?(pattern, text) do
        [
          %{
            type: :"#{threat_type}_#{subtype}",
            severity: :medium,
            description: description,
            location: find_pattern_location(pattern, text),
            confidence: 0.8
          }
        ]
      else
        []
      end
    end)
  end

  defp find_pattern_location(pattern, text) do
    case Regex.run(pattern, text) do
      [match | _] ->
        index = :binary.match(text, match) |> elem(0)
        "Position #{index}"

      _ ->
        nil
    end
  end

  defp detect_file_signatures(data) when byte_size(data) >= 8 do
    # Check common file signatures
    case data do
      <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>> -> ["PNG"]
      <<0xFF, 0xD8, 0xFF, _::binary>> -> ["JPEG"]
      <<"GIF87a", _::binary>> -> ["GIF87"]
      <<"GIF89a", _::binary>> -> ["GIF89"]
      <<0x42, 0x4D, _::binary>> -> ["BMP"]
      _ -> ["unknown"]
    end
  end

  defp detect_file_signatures(_), do: ["unknown"]

  defp suspicious_signature?("unknown"), do: true
  defp suspicious_signature?(_), do: false

  defp severity_for_data_type("credit_card"), do: :critical
  defp severity_for_data_type("ssn"), do: :critical
  defp severity_for_data_type("private_key"), do: :critical
  defp severity_for_data_type("aws_key"), do: :high
  defp severity_for_data_type("api_key"), do: :high
  defp severity_for_data_type("email"), do: :low
  defp severity_for_data_type("phone"), do: :low
  defp severity_for_data_type(_), do: :medium

  defp confidence_for_pattern("credit_card", number) do
    # Simple Luhn check would go here
    if String.length(String.replace(number, ~r/\D/, "")) in 13..19, do: 0.9, else: 0.5
  end

  defp confidence_for_pattern("ssn", _), do: 0.8
  defp confidence_for_pattern("aws_key", _), do: 0.95
  defp confidence_for_pattern("private_key", _), do: 1.0
  defp confidence_for_pattern(_, _), do: 0.7

  defp calculate_threat_level([]), do: :safe

  defp calculate_threat_level(threats) do
    max_severity =
      threats
      |> Enum.map(& &1.severity)
      |> Enum.max_by(&severity_value/1)

    max_severity
  end

  defp severity_value(:critical), do: 5
  defp severity_value(:high), do: 4
  defp severity_value(:medium), do: 3
  defp severity_value(:low), do: 2
  defp severity_value(:safe), do: 1
end
