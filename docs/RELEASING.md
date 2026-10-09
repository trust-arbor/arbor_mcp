# Releasing the Arbor packages

The published RC train is ArborMCP `2.0.0-rc.2` and ArborRPC, ArborACP and
Adapters `1.0.0-rc.1`. The original four `2.0.0-rc.1` candidates are retired;
their tags and archives remain available. ExMCP `1.6.0` is independently
maintained. Stable promotion follows the gates below.

## Versions, dependencies and tags

| Package | Published candidate | First stable | Dependencies |
| --- | --- | --- | --- |
| ArborMCP | `2.0.0-rc.2` | `2.0.0` | RPC `~> 1.0.0-rc.1` |
| ArborRPC | `1.0.0-rc.1` | `1.0.0` | None of the other Arbor packages |
| ArborACP | `1.0.0-rc.1` | `1.0.0` | RPC `~> 1.0.0-rc.1` |
| ArborACP adapters | `1.0.0-rc.1` | `1.0.0` | ACP and RPC `~> 1.0.0-rc.1` |

A package's own version does not determine its dependency requirements. RC
requirements explicitly include the tested dependency prerelease; stable
requirements use the dependency's compatible major/minor line (`~> 1.0` for
these first stable dependencies). Keep security floors and optional listener
ranges intact. Runtime-owned constructors enforce their separately qualified
versions; mounted listeners use the host application's graph.

Publish RPC, then ACP, then MCP and Adapters. MCP/RPC use `v<version>` tags in
their own repositories. ACP and Adapters use separate package-qualified tags
(`arbor_acp-v<version>` and `arbor_acp_adapters-v<version>`) in the ACP workspace.
Versions can diverge even though those two packages share a repository.
ExDoc links follow each owning package's tag; prospective tags remain invalid
until created. Preserve all old tags, archives and publication receipts.

Versions and dependency requirements are literals in shipped `mix.exs` files.
Prepare separate reviewable copies with explicit versions for each package:

```sh
python3 scripts/prepare_release.py \
  --mcp-source /path/to/arbor_mcp \
  --acp-source /path/to/arbor_acp \
  --rpc-source /path/to/arbor_rpc \
  --mcp-version 2.0.0-rc.2 \
  --rpc-version 1.0.0-rc.1 \
  --acp-version 1.0.0-rc.1 \
  --adapters-version 1.0.0-rc.1 \
  --output /path/to/new-release-preparation
```

The script rejects overlapping trees, existing output directories and malformed
versions. It records input commits/checksums, independent versions, dependency
requirements, tags and publication order. Review release notes and apply the
literal changes before building final archives. Preparation creates no commits,
tags, publications or release qualification. Once replacements are published
and verified, retire the superseded candidates with replacement messages;
retirement preserves existing lockfile resolution and downloads.

## Standalone documentation and source archives

Each package has its own dev-only, non-runtime ExDoc dependency. From the ACP
workspace root, generate docs for each project independently with normal
Hex dependency resolution:

```sh
cd packages/arbor_acp
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix docs --warnings-as-errors
```

Use `packages/arbor_acp_adapters` for the optional bundle. Generate ArborRPC
documentation from the root of its separate checkout with
`MIX_ENV=dev mix deps.get` and `MIX_ENV=dev mix docs --warnings-as-errors`.
Local source overrides are optional development settings. Build each Hex
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
  --expected-package-version arbor_mcp=2.0.0-rc.2 \
  --expected-package-version arbor_rpc=1.0.0-rc.1 \
  --expected-package-version arbor_acp=1.0.0-rc.1 \
  --expected-package-version arbor_acp_adapters=1.0.0-rc.1 --report /path/to/qualification.json
```

It verifies Hex checksums, exact shipped source hashes, metadata/literal version
agreement, internal version policy and documentation tags before installation.
It then compiles the archives, checks installed `.app` versions and package
boundaries, exercises MCP/ACP and native cleanup, and repeats the probes in a
compiler-free assembled release. `--metadata-only` performs just the first phase.
`--expected-package-version APP=VERSION` validates each package independently;
it never changes a literal. The legacy `--expected-version` asserts one uniform
version and is unsuitable for this release graph. Offline local
qualification may explicitly set `ARCHIVE_CONSUMER_EXTERNAL_DEPS` to independent
external source copies; CI must also qualify normal Hex resolution.

CI checks out RPC independently from ACP and builds its archive at the RPC
repository root. The HTTP consumer's source-selection receipt records separate
MCP and RPC commits. To associate those two archives with their exact sources:

```sh
python3 scripts/check_archive_source_selection.py \
  --archives /path/to/mcp-and-rpc-archives \
  --mcp-source /path/to/arbor_mcp --rpc-source /path/to/arbor_rpc \
  --version 2.0.0-rc.2 --rpc-version 1.0.0-rc.1 --output /path/to/source-selection.json
```

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

## Stable qualification checklist

- Associate every tested source, version, dependency lockfile, archive and owning
  tag with the final selected package graph. Recheck later changes separately.
- Pass supported/latest BEAM CI, warnings-as-errors, formatting, strict docs and
  source/package boundary checks in each repository.
- Run MCP legacy compliance, modern external conformance and pinned official-SDK
  interoperability; run ACP SDK, unchanged adapter goldens and reviewed
  credential-free CLI lifecycle checks. Live model turns need separate evidence.
- Qualify Cowboy, Bandit, Phoenix mounts, stdio/native ACP, combined packages and
  installed releases; check lowest/newest declared dependency contracts.
- Exercise isolation, cancellation, pressure, persistence/recovery, cross-runtime
  crash/restart/shutdown, diagnostic privacy and cold-restart rollback on the
  final source. Advertise only the verified platform/architecture matrix.
- Test real downstream applications and vendor workflows. Define long-lived
  peer turnover within documented request-ID/capacity limits. Keep those finite
  limits and original deadlines during the rehearsal.
- Accept the measured latency/throughput costs; further optimization is deferred.
- Complete the accepted continuous **48-hour final-candidate soak**. A previous
  harness run stopped at the persistent-peer cap after about 50 minutes; no
  completed qualifying soak is recorded. Retain failures and typed cleanup
  evidence rather than treating process death as physical cleanup.
- Resolve normally from Hex and verify installed versions, package boundaries,
  native helper lookup and compiler-free release operation.

See the [roadmap](ROADMAP.md) and [RC testing notes](guides/V2_RELEASE_CANDIDATE.md)
for current scope and remaining decisions. Preparation, CI and short rehearsals
create evidence; they do not publish or complete the continuous gate.

## Publication and verification

Review release notes, literal versions, compatible requirements and exact source
archives before creating fresh tags or publishing. Use the owning repository's
package tag and preserve previous versions/tags. Hex publication requires an
interactive user terminal for any 2FA prompt; codes belong only in Hex's prompts.

After publication, independently verify the registry version/requirements,
archive checksums, versioned HexDocs, ordinary Hex installation, assembled release
and GitHub release/tag. Retire a superseded candidate only after its replacement
installation is verified. If an attempt stops, inspect receipts and public state
before planning a continuation; never reuse a published version or tag.
