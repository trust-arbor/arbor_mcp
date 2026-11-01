# MCP implementation assurance

ArborMCP uses requirement contracts, pinned official conformance and independent
interop together. A successful harness run alone does not establish complete
implementation of a specification. The [feature matrix](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/MCP_COVERAGE_MATRIX.md)
describes supported behavior; the generated [requirement evidence](MCP_REQUIREMENTS.md)
records the narrower claims and named tests behind it.

Run the commands below from a repository checkout. The assurance tooling and
test peers are intentionally excluded from Hex packages.

## Requirement review

`scripts/mcp_requirements.json` records immutable sources, sections, roles,
profiles, implementation locations, evidence cases and limitations. Review
normative prose, schemas and incorporated references together. Requirements can
be expressed without uppercase MUST/SHOULD words, so keyword extraction is not a
complete inventory. Optional features acquire obligations when adopted.

Keep client, MCP server, IdP, authorization-server and host responsibilities
separate. Initial SSO, enterprise policy, tenant mappings, replay storage and
access-token issuance are not supplied by a JWT validation helper. Record an
unimplemented or host-owned obligation explicitly rather than counting a nearby
passing test as its implementation.

The register includes scoped core and inherited OAuth/ID-JAG requirement bundles,
in addition to Auth and the Tasks prose/schema dispositions. Each source declares the exact
revision and adopted sections; a complete **scoped inventory** means those
responsibilities have been mapped, not that every clause has executable proof.
The generated register separates remaining library work, scoped support/evidence,
external responsibilities and unadopted profiles. A supported scope is an API
implementation claim backed by named assertions, not exhaustive clause qualification.
Every open work item has a concrete action and closure condition; closing it requires
executable evidence. Legacy revision inventories remain outside this scope.
Tasks maps every prose section and exported schema type in
`scripts/mcp_tasks_requirement_sources.json`. The client APIs expose task state,
updates and cancellation; hosts drive polling, persist task IDs and deduplicate
user/model input across polls and restarts. The bundled ETS store is process-local,
so restart durability requires host-provided storage.
The [source review](MCP_SOURCE_REVIEW.md) records the page/section dispositions.

## Executable evidence

Each registered case names an assertion and its file. ExUnit tests carry matching
`:assurance` labels. The formatter records actual test completion; the checker
rejects missing labels, unknown or duplicate cases, skipped/failed tests,
unexpected files and reports collected from different implementation inputs.
A supported row requires code and executable evidence definitions (or an explicit
open evidence work item during review). Definitions
alone are not passing results: CI retains the execution artifact separately.

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_mcp_*.py' -v
python3 -B scripts/check_mcp_assurance.py --run
```

After a reviewed register change, regenerate its public report:

```sh
python3 -B scripts/check_mcp_assurance.py --write-docs
```

Tests should exercise positive behavior and forbidden alternatives: an invalid
issuer must not receive credentials; a malformed exchange result must not reach
the next token endpoint; rejected input must not advance stored state. When
fixing a defect, first demonstrate that the regression fails on the old behavior.
Tags and assertions still need human review: a label cannot establish that its
test faithfully implements the normative requirement.

## Independent interoperability

Install the locked peers with Node.js 24 or newer, then execute their evidence:

```sh
npm ci --prefix test/interop --ignore-scripts --no-audit --no-fund
python3 -B scripts/check_mcp_assurance.py --run --kind independent_fixture --kind interop --output tmp/mcp-assurance/interop.json
```

The independent Node OAuth fixture uses locked `jose` cryptography to verify
client assertions, issuer/audience/client bindings, expiry and assertion IDs.
It issues and verifies ID-JAGs and resource access tokens. Both orchestrators
exercise OIDC, refresh-token and SAML-transition inputs against it. Its SAML
subject is an opaque test token; it does not validate XML, run a SAML SSO service
or qualify a vendor IdP. It is labelled `independent_fixture` accordingly.

The pinned TypeScript SDK 2.4.0 lane uses its Basic/JWT client-credentials
providers and OIDC enterprise helpers against Elixir HTTP peers. Arbor validates
SDK assertions and grants and issues the ID-JAG consumed by the SDK helper.
HTTPS identities map explicitly to a loopback fixture transport. These are Auth
helper interoperability tests, separate from the existing core MCP transport
lanes. SDK SAML, refresh-subject and confidential IdP JWT qualification is not
claimed by this lane. Qualify a peer's actual capabilities before adding a claim.


Automatic resource authorization and refresh reject unsupported/null/non-string
access-token types and empty tokens before persistence or Bearer use. Bearer
matching is case-insensitive. Generic token-exchange helpers retain their token
representations, including ID-JAG's `N_A`; the access-token check runs only after
the final resource grant or refresh.

## Real authorization-server interoperability

The separately pinned Keycloak 26.8.1 lane is `real_provider` evidence, distinct
from both `independent_fixture` and SDK `interop`. With Docker available:

```sh
python3 -B scripts/check_mcp_assurance.py --run --kind real_provider --output tmp/mcp-assurance/real-provider.json
```

The test starts the official image by digest, creates an ephemeral realm and
registrations, and exercises Basic/JWT discovery, signed/resource-bound tokens,
real introspection and an authenticated Arbor client/server request. It also
rejects wrong secrets and missing/invalid bearer credentials. Startup/assertion
failures fail the lane; there is no credential-dependent skip or mock fallback.
The provider runs only on loopback HTTP with fake local credentials. Its CA/TLS,
production deployment, tenant administration and every provider profile are not
certified. The dedicated CI job retains `mcp-real-provider` receipts/logs and
cleans only its labelled containers; image upgrades require a reviewed rerun.

Keycloak's experimental ID-JAG receiver is documented against draft-01 and its
issuer is not implemented. This real-provider lane therefore qualifies only
client credentials. The enterprise draft-04 client roles retain official, SDK
OIDC and verifying independent-peer evidence. The latter now fetches CIMD and
inline/URL JWKS and rejects document identity/key mismatches under an explicit
logical HTTPS-to-loopback transport mapping.

Existing confidential-IdP, JWT assertion and ID-JAG tests have named register
cases; host duties are not marked implemented merely because a fixture enforces
its own policy. Green matrix symbols describe the stated library role. Broad
mixed-role bundles list external duties separately without implying a known
missing client API; their exact evidence and limits remain in the register.

## Official conformance and drift

Core evidence reuses the official harness assertions. `conformance.sh modern`
preserves its actual per-scenario `checks.json` files and validates their exact
IDs, names, counts and outcomes against `scripts/mcp_core_checks.json`. The
checkout-bound receipt maps 73 scenarios to the register; INFO wire traces do
not count as assertions. Two legacy-only initialize/initialized header checks
remain visibly skipped in the modern profile and are exercised by the separate
legacy gate. Missing/new assertions, failures, warnings and other skips fail.
The fixture now exercises resource/prompt headers and real filtered catalog
changes instead of leaving those official assertions dormant.

The weekly workflow selects scenarios from the running harness's own inventory,
including newly added client scenarios. A newer, unreviewed harness produces an
explicit exploratory receipt with no qualified requirement case IDs; it must still
execute every applicable scenario without failures, warnings or new skips. The
release gate continues to require the exact reviewed harness/assertion inventory.

Client scenarios run separately to isolate concurrently launched OAuth fixtures.
Their upstream assertions are unchanged. Existing local tests fill specific
framing, pagination, schema and subscription gaps without duplicating the core
harness. The only new Auth contracts cover missing/malformed S256 metadata,
which the upstream scenarios do not test.

The official harness and SDK versions remain pinned in PR/release CI. Run the
extension gate independently of core conformance:

```sh
./scripts/conformance.sh extensions
```

`scripts/mcp_extension_checks.json` records the reviewed check inventory. The
execution checker rejects missing/new checks, failures, warnings and unreviewed
skips, even if the harness exits successfully. Its one permitted upstream Tasks
notification stub is visible and does not count as notification qualification.
Informational wire traces never count as assertion passes.

The harness's `--requirements` mode is a release-frozen scenario set, not an
exhaustive normative inventory. Extension scenarios are unscored there. Keep our
strict extension gate and local contracts even when running that mode.

The [upstream monitors](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/EXTENSION_SYNC.md) compare core prose/schemas, extension
sources, SDK/harness releases and the complete available scenario inventory.
Collection errors fail; source drift produces reviewable reports with stable
deduplication keys. Review each change as editorial, inapplicable or behaviorally
relevant, update affected requirements/tests, then advance pins in a reviewed
PR. The read-only workflows never acknowledge a change or upgrade a dependency
automatically. Artifact retention is finite; committed pins, requirement records
and `scripts/mcp_upstream_reviews.json` provide the durable review history.
