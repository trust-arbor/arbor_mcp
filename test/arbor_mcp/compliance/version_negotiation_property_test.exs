defmodule Arbor.MCP.Compliance.VersionNegotiationPropertyTest do
  @moduledoc """
  Property-based tests for Arbor.MCP.Protocol.VersionNegotiator.

  These tests use PropCheck to verify the correctness of the version
  negotiation logic under a wide range of generated inputs. It covers:

  - Successful negotiation with compatible client/server versions.
  - Failed negotiation with incompatible versions.
  - Correct handling of supported and unsupported version strings.
  - Robustness against invalid inputs (e.g., non-list arguments).
  - Correctness of the server capabilities payload generation.

  The version comparison logic is tested implicitly by verifying that
  negotiation always selects the highest compatible version.
  """
  use ExUnit.Case, async: true
  use PropCheck

  alias Arbor.MCP.Internal.VersionRegistry
  alias Arbor.MCP.Protocol.VersionNegotiator
  alias Arbor.MCP.Server.ResultNormalizer
  alias Arbor.MCP.TestSupport.LegacyInitialize

  @supported_versions VersionNegotiator.supported_versions()

  # ===========================================================================
  # Generators
  # ===========================================================================

  # Generates a single, valid, supported protocol version string.
  def supported_version_gen, do: oneof(Enum.map(@supported_versions, &return/1))

  # Generates a version string that is not in the supported list.
  # This includes malformed strings and valid but unsupported date-based versions.
  def unsupported_version_gen do
    unsupported_gen =
      oneof([
        return("2023-01-01"),
        return("invalid-version-format"),
        return(""),
        # Generate a random string that is unlikely to be a supported version
        utf8()
      ])

    such_that(v <- unsupported_gen, when: v not in @supported_versions)
  end

  # Generates a list of client-supported version strings.
  #
  # ## Options
  #
  #   * `:ensure_supported` - Controls the presence of supported versions:
  #     - `:always` (default): Guarantees at least one supported version is in the list.
  #     - `:never`: Guarantees no supported versions are in the list.
  #     - `:maybe`: The list may or may not contain supported versions.
  def client_versions_gen(opts \\ []) do
    ensure_supported = Keyword.get(opts, :ensure_supported, :always)

    versions_gen =
      oneof([
        supported_version_gen(),
        unsupported_version_gen()
      ])

    case ensure_supported do
      :always ->
        # Use `let` to combine generators, ensuring at least one supported version.
        # The resulting list is shuffled to ensure the supported version is at a random position.
        let {supported_v, rest} <- {supported_version_gen(), list(versions_gen)} do
          Enum.shuffle([supported_v | rest])
        end

      :never ->
        # Generate a non-empty list containing only unsupported versions.
        non_empty(list(unsupported_version_gen()))

      :maybe ->
        # Generate a non-empty list that may or may not contain supported versions.
        non_empty(list(versions_gen))
    end
  end

  # ===========================================================================
  # Properties
  # ===========================================================================

  property "negotiation succeeds when a compatible version exists" do
    forall client_versions <- client_versions_gen(ensure_supported: :always) do
      # The version comparison logic (`v1 >= v2`) is implicitly tested here.
      # By finding the `Enum.max` of compatible versions, we are checking that
      # the negotiator correctly identifies and selects the "newest" version.
      compatible_versions = Enum.filter(client_versions, &(&1 in @supported_versions))
      expected_best_version = Enum.max(compatible_versions)

      case VersionNegotiator.negotiate(client_versions) do
        {:ok, result} -> result == expected_best_version
        _ -> false
      end
    end
  end

  property "negotiation fails when no compatible version exists" do
    forall client_versions <- client_versions_gen(ensure_supported: :never) do
      VersionNegotiator.negotiate(client_versions) == {:error, :no_compatible_version}
    end
  end

  property "negotiation with an empty list of versions fails" do
    # This is a specific edge case not covered by the main generators.
    VersionNegotiator.negotiate([]) == {:error, :no_compatible_version}
  end

  property "negotiation with non-list input fails" do
    forall invalid_input <- such_that(t <- term(), when: not is_list(t)) do
      VersionNegotiator.negotiate(invalid_input) == {:error, :no_compatible_version}
    end
  end

  property "all supported versions are recognized as supported" do
    forall version <- supported_version_gen() do
      VersionNegotiator.supported?(version)
    end
  end

  property "unsupported versions are not recognized as supported" do
    forall version <- unsupported_version_gen() do
      !VersionNegotiator.supported?(version)
    end
  end

  property "non-string inputs are not considered supported versions" do
    forall invalid_input <- such_that(t <- term(), when: not is_binary(t)) do
      !VersionNegotiator.supported?(invalid_input)
    end
  end

  property "canonical initialization retains capabilities for every supported version" do
    forall version <- supported_version_gen() do
      result = LegacyInitialize.result(version)

      result["protocolVersion"] == version and
        result["serverInfo"]["name"] == "Arbor.MCP" and
        result["capabilities"] ==
          ResultNormalizer.stringify_keys(VersionRegistry.capabilities_for_version(version))
    end
  end
end
