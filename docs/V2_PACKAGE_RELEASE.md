# Coordinated package preparation

This is a source-preparation and installation policy, not a release approval.
The current literal version is `2.0.0-rc.1`. No tags or packages are published
by the preparation or archive-consumer scripts.

## Versions, dependencies and tags

| Source stage | Four literal versions | Internal dependency floor |
|---|---|---|
| Development | `2.0.0-dev` | `~> 2.0.0-dev` |
| Release candidate | `2.0.0-rc.N` | `~> 2.0.0-rc.N` |
| Stable | `2.0.0` | `~> 2.0` |

Prerelease floors explicitly admit the coordinated prerelease and subsequent
compatible releases. An RC floor excludes earlier development snapshots. Stable
requirements exclude prereleases and preserve compatibility with later 2.x
releases. Wrong major versions are rejected. External security floors and optional
listener dependency requirements are preserved during version preparation.
Optional transitive constraints do not necessarily select the host's listener
versions: declare the qualified Ranch 1.8.1 or Bandit 1.12.5/Thousand Island 1.5.0
host dependencies in [HTTP listeners](./HTTP_LISTENERS.md).

Publish `arbor_rpc` first, then `arbor_acp`, then `arbor_mcp`, then the optional
`arbor_acp_adapters` bundle. The MCP source tag is `v<version>`. The ACP monorepo
uses `arbor_rpc-v<version>`, `arbor_acp-v<version>` and
`arbor_acp_adapters-v<version>` at the same coordinated source commit. ExDoc source
links include the corresponding tag and `packages/<app>/` path. Until the tags
exist, local development documentation has prospective source links.

Versions must be literals in the shipped `mix.exs`. A release environment override
alone is insufficient: installed source must retain the same version after that
environment disappears. Prepare separate reviewable source copies:

```sh
python3 scripts/prepare_release.py \
  --mcp-source /path/to/arbor_mcp \
  --acp-source /path/to/arbor_acp \
  --version 2.0.0-rc.1 \
  --output /path/to/new-release-preparation
```

The script rejects overlapping input/output trees, existing output destinations
and unsupported versions. It records source checksums, input commits, prepared
Mix checksums, tags and dependency order. It changes literal versions and
internal requirements in the copies, and updates the package README version marker. It does not author release notes, waive
qualification gates or create Git commits/tags. Review and apply those literal
changes to the final repositories; final tagged commits and rebuilt archives must
agree before publication.

## Standalone documentation and source archives

Each ACP package has its own dev-only, non-runtime ExDoc dependency. From the
monorepo root, generate docs for a package independently:

```sh
cd packages/arbor_acp
ARBOR_V2_LOCAL=1 MIX_ENV=dev mix deps.get
ARBOR_V2_LOCAL=1 MIX_ENV=dev mix docs --warnings-as-errors
```

Use `packages/arbor_rpc` or `packages/arbor_acp_adapters` for the other projects.
The local override is for unpublished workspace dependencies. Build each Hex
source archive with `ARBOR_V2_LOCAL`, `ARBOR_V2_DEPS`, `ARBOR_RPC_PATH` and release
version overrides unset. These overrides must never appear in published package
requirements. ExDoc is excluded from consumer runtime dependencies.

ArborRPC ships reviewed `c_src/subprocess_helper.c` and its Mix compiler. It
excludes host-generated `priv/native` binaries; no prebuilt helper is promised.
Source installation on macOS/Darwin and Linux requires a C17 compiler, including
transitive installation through MCP or ACP for HTTP-only or BEAM-only use. `CC`
selects one compiler executable, with fixed compiler arguments and no shell
command. Assembled releases must include the helper built for their target;
runtime lookup uses installed `:code.priv_dir(:arbor_rpc)` and invokes no compiler.
Windows native subprocess operations are explicitly unsupported. Other
unsupported platforms also fail explicitly for subprocess opening; framing use
starts no helper. Advertise only the platform/architecture matrix actually
qualified from the final source and archives. Broader native pressure/lifecycle
and runtime/API qualification remain release gates; Windows implementation is
not a requirement for this release.

Run the four-package consumer against one archive per package:

```sh
python3 scripts/check_archive_consumer.py /path/to/four-archives \
  --expected-version 2.0.0-rc.1 --report /path/to/qualification.json
```

It verifies Hex checksums, exact shipped source hashes, metadata/literal version
agreement, internal version policy and documentation tags before installation.
It then compiles the archives, checks installed `.app` versions and package
boundaries, exercises MCP/ACP and native cleanup, and repeats the probes in a
compiler-free assembled release. `--metadata-only` performs just the first phase.
`--expected-version` validates; it never selects a package version. Offline local
qualification may explicitly set `ARCHIVE_CONSUMER_EXTERNAL_DEPS` to independent
external source copies; CI must also qualify normal Hex resolution.

RC publication enables downstream migration testing before stable qualification
finishes. Publish the coordinated RC only after source/API checks, supported
toolchain CI, archive inspection and installed/release rehearsals pass for the
selected payloads. Record known limits and outstanding sustained qualification
in the [RC notes](guides/V2_RELEASE_CANDIDATE.md). Verify normal registry
installation as each dependency becomes available.

Stable publication additionally requires the accepted continuous 48-hour run,
performance acceptance and all remaining release gates. Rebuild archives from
the final tagged source, and verify their installed versions and dependency
ranges; an RC or a passed short rehearsal does not qualify the stable release.
