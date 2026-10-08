defmodule Arbor.MCP.SpecSync.FileMapperTest do
  use ExUnit.Case, async: true

  alias Arbor.MCP.SpecSync.FileMapper

  describe "github_to_local/1" do
    test "maps the nested 2026-07-28 documentation layout" do
      assert FileMapper.github_to_local("docs/specification/2026-07-28/basic/patterns/mrtr.mdx") ==
               "2026-07-28/BaseProtocol/Patterns/Mrtr.md"

      assert FileMapper.github_to_local(
               "docs/specification/2026-07-28/basic/transports/streamable-http.mdx"
             ) == "2026-07-28/BaseProtocol/Transports/StreamableHttp.md"

      assert FileMapper.github_to_local(
               "docs/specification/2026-07-28/basic/authorization/client-registration.mdx"
             ) == "2026-07-28/BaseProtocol/Authorization/ClientRegistration.md"

      assert FileMapper.github_to_local(
               "docs/specification/2026-07-28/server/utilities/caching.mdx"
             ) == "2026-07-28/ServerFeatures/Utilities/Caching.md"
    end

    test "maps nested index files to overview documents" do
      assert FileMapper.github_to_local(
               "docs/specification/2026-07-28/basic/transports/index.mdx"
             ) == "2026-07-28/BaseProtocol/Transports/Overview.md"
    end

    test "keeps root and schema mappings compatible" do
      assert FileMapper.github_to_local("docs/specification/2026-07-28/index.mdx") ==
               "2026-07-28/Specification.md"

      assert FileMapper.github_to_local("docs/specification/2026-07-28/deprecated.mdx") ==
               "2026-07-28/Deprecated.md"

      assert FileMapper.github_to_local("schema/2026-07-28/schema.json") ==
               "2026-07-28/schema.json"
    end
  end

  describe "doc_files_for_version/1" do
    test "provides a complete offline fallback for the 2026-07-28 tree" do
      files = FileMapper.doc_files_for_version("2026-07-28")

      assert length(files) == 31
      assert "docs/specification/2026-07-28/basic/versioning.mdx" in files
      assert "docs/specification/2026-07-28/server/discover.mdx" in files
      assert "docs/specification/2026-07-28/server/utilities/caching.mdx" in files
    end
  end
end
