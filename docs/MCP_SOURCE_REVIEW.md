# MCP core and inherited source review

Review date: 2026-11-01. This review maps adopted source scopes to requirement
bundles and reuses existing assertions. It does not certify every normative clause,
every optional profile, a deployed host or a third-party identity provider.

A source marked `complete` means its stated **inventory scope** has dispositions:
supported behavior, partial evidence, host duties and unadopted profiles are mapped.
It does not mean implementation or executable qualification is complete. The register
contains 119 requirement bundles, 212 named local/peer/provider cases and mappings to all 73
existing official modern core scenarios.

## Core revision

The reviewed revision is `2026-07-28` at `d0e246ea3c69eafaa2806bc4cd28025703ba2c2b`. All prose pages and the
canonical JSON schema below were fetched at that commit and verified against Git
blob IDs. Illustrative PNGs have no independent protocol obligations. Legacy/future
revision inventories remain outside this review; their sources are monitored.

Each row maps a whole page to requirement bundles, including prose without uppercase
obligation words and schema-defined shapes. A bundle can group related clauses;
its evidence qualifies only the named assertions, not everything on the page. The
generated schema reference repeats the canonical schema rather than adding a test.

| Page | Requirement disposition | SHA-256 |
|---|---|---|
| [architecture/index.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/architecture/index.mdx) | CORE.SAFETY | `9037b342a1f23c056a564a48dda15b70e511dda6d09e96ab0e86f6f9086f9cc3` |
| [basic/authorization/authorization-server-discovery.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/authorization/authorization-server-discovery.mdx) | CORE.AUTH_DISCOVERY | `2d80118a0187d16f0122e64e6092c49f13d901c650f69712dce1a241a08cfb1d` |
| [basic/authorization/client-registration.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/authorization/client-registration.mdx) | CORE.AUTH_REGISTRATION | `912365f0c2b859269d25a3e868580d3f222dd94c80dbc5c3b18024bec1e7daff` |
| [basic/authorization/index.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/authorization/index.mdx) | CORE.AUTH_DISCOVERY, CORE.AUTH_REGISTRATION, CORE.AUTH_SCOPE, CORE.AUTH_ISSUER, CORE.AUTH_RESOURCE, CORE.AUTH_TOKEN, CORE.AUTH_REFRESH, CORE.AUTH_SECURITY | `99e7eeaecad5381649e6dca98cb5b47f314bdda9f1d8cd989299e5fe143a913e` |
| [basic/authorization/security-considerations.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/authorization/security-considerations.mdx) | CORE.AUTH_SECURITY | `9b62204a9ff17eb1de8c270975759f0d0c191a3534b8d1ba3939e5948ed08f3f` |
| [basic/index.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/index.mdx) | CORE.JSONRPC, CORE.RESULT, CORE.ERRORS, CORE.STATELESS, CORE.SCHEMA, CORE.REFS, CORE.METADATA, CORE.META_NAMES, CORE.ICONS | `03586b10e3214c55478293f1199fffb0bbf95bbef5df3d6a8378e860697bd63f` |
| [basic/patterns/cancellation.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/patterns/cancellation.mdx) | CORE.CANCELLATION | `396030784a4af9b734a1c8d4faed13b31077e4a3a1f03c9c1f2048ec52794ba4` |
| [basic/patterns/index.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/patterns/index.mdx) | CORE.JSONRPC, CORE.MRTR_SERVER, CORE.MRTR_CLIENT, CORE.SUBSCRIPTIONS | `9e08dd8b295cacc59bd4e233e9e1d6bfcc149695c265d95a18e2fddc9ad3968d` |
| [basic/patterns/mrtr.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/patterns/mrtr.mdx) | CORE.MRTR_SERVER, CORE.MRTR_CLIENT, CORE.MRTR_STATE | `a8671eb2a0d292c0dcbae19666ff4fc3d97f294ce8107e9f38259cc5a02a066b` |
| [basic/patterns/progress.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/patterns/progress.mdx) | CORE.PROGRESS | `9f55aca08920c633f3a2a35e0c77533db08d3fd19ced43918ea7c57aa5f85409` |
| [basic/patterns/subscriptions.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/patterns/subscriptions.mdx) | CORE.SUBSCRIPTIONS | `8333cbc3280cad293e96b4a20c3200face8e185ebf58f1c4a51c35bb96654abd` |
| [basic/transports/index.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/transports/index.mdx) | CORE.STDIO, CORE.HTTP, CORE.HEADERS, CORE.CANCELLATION, CORE.ERA | `59cc01897f5efadc1d412007a47df4f19b30725cdeaf264bbaf25e6b6b0aeb51` |
| [basic/transports/stdio.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/transports/stdio.mdx) | CORE.STDIO, CORE.STDIO_LIFECYCLE | `6fd49766c40dc093d1f5993ab584bad0a06cbb496c2d3019c50f8fe3c8171e57` |
| [basic/transports/streamable-http.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/transports/streamable-http.mdx) | CORE.HTTP, CORE.HTTP_SECURITY, CORE.HEADERS, CORE.CUSTOM_HEADERS, CORE.HTTP_CANCEL | `22574bf11e004068493787203ce92be1162107cad717bcb805a15780d4fa69c9` |
| [basic/versioning.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/basic/versioning.mdx) | CORE.VERSION, CORE.ERA | `bc02f271700bdecd88034f2d7801eb09110a71d65876487378d94e48dfeb90dc` |
| [changelog.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/changelog.mdx) | CORE.ERA, CORE.SAMPLING, CORE.ROOTS, CORE.LOGGING | `b327e576f4c96b34e92f338f8ffefc35e13d0e953ab76bdb3aab342d104c8e53` |
| [client/elicitation.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/client/elicitation.mdx) | CORE.ELICITATION, CORE.ELICITATION_POLICY | `74351d1081681695536e59a55588a67ed66a76db6057846c263ce2f465fab4c2` |
| [client/roots.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/client/roots.mdx) | CORE.ROOTS | `016aea34d76ccce86a82509dbf2699833bb8547bde5b3f4a8eb086dfd26a9ba2` |
| [client/sampling.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/client/sampling.mdx) | CORE.SAMPLING | `32fe2bb69f5a7caa85a6b9501f465cb1fb888d0c669cd13b23a071071a029df1` |
| [deprecated.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/deprecated.mdx) | CORE.ERA, CORE.SAMPLING, CORE.ROOTS, CORE.LOGGING | `6ec5fc903d1be37e5ab0afda2acd7765aaf2909b90a2dca405e1aaea8936225b` |
| [index.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/index.mdx) | CORE.SAFETY | `c8151ab8d7f26ab46785fd34b23f7197db1a98ca8318967faa01e401909667b5` |
| [schema.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/schema.mdx) | CORE.SCHEMA_SURFACE | `bdfb232898c79aefc8ae29571c1ac99a19d482f4bf35c177bcfe9a89d86e8514` |
| [server/discover.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/discover.mdx) | CORE.VERSION, CORE.METADATA | `3fe1f5b5f1528014216b1e49cc3363b3c689c36bcb80a6957ddca6a04cea409c` |
| [server/index.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/index.mdx) | CORE.TOOLS, CORE.RESOURCES, CORE.PROMPTS, CORE.COMPLETION | `9c34c72960816e613caa449a2e716233e815196321011742f5cbc9b620539bef` |
| [server/prompts.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/prompts.mdx) | CORE.PROMPTS | `85e550635bbbbaa90dff8738f98808c62987e8cfce1d75305b55ca43f3c546de` |
| [server/resources.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/resources.mdx) | CORE.RESOURCES, CORE.RESOURCE_POLICY | `10538119019af5f49a2fbc55d5818725175863115dfb273e79ed7f65a18aaf0c` |
| [server/tools.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/tools.mdx) | CORE.TOOLS, CORE.TOOL_POLICY | `65ae4ba35373803023b5dedbe3b7b5726f84acc8391ad6ef64386b4fbec46abf` |
| [server/utilities/caching.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/utilities/caching.mdx) | CORE.CACHE | `ca416e94b40c067de638bb101541969f2b956b33e9695761032ddc06245d514d` |
| [server/utilities/completion.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/utilities/completion.mdx) | CORE.COMPLETION | `1965c563aadb99e141131444caa81ff1860ed82bab314b286c40a0f0ba839f99` |
| [server/utilities/logging.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/utilities/logging.mdx) | CORE.LOGGING | `4e77ec3257e07ad69bfd6ed902771f14d6498b60fe6c9c325b8ff4bfc35647a6` |
| [server/utilities/pagination.mdx](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/docs/specification/2026-07-28/server/utilities/pagination.mdx) | CORE.PAGINATION | `c4c7b674ae9ce16c012b5da35559d35768f6b7a508ceb5d2d71393a9f46afd2b` |
| [schema/2026-07-28/schema.json](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/d0e246ea3c69eafaa2806bc4cd28025703ba2c2b/schema/2026-07-28/schema.json) | CORE.SCHEMA_SURFACE | `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203` |

## Inherited references

Only the stated adopted sections are inventoried. Core incorporates CIMD draft00;
Enterprise references draft01 section 6.2. Core separately references OAuth 2.1 draft14
section 4.3 for refresh confidentiality, preserving its draft13 baseline elsewhere.

| Reference | Reviewed scope and exclusions | Requirement bundles |
|---|---|---|
| [IDJAG](https://www.ietf.org/archive/id/draft-ietf-oauth-identity-assertion-authz-grant-04.txt) | Draft-04 sections 3 through 9: bearer client exchange and helper behavior, IdP/resource-AS/host duties, and explicitly unadopted SAML subject mapping, rich authorization and DPoP. Appendices and IANA registration instructions are context, not library assertions. | IDJAG.CLAIMS, IDJAG.SUBJECT, IDJAG.EXCHANGE, IDJAG.IDP_POLICY, IDJAG.GRANT, IDJAG.RENEWAL, IDJAG.SAML, IDJAG.METADATA, IDJAG.TRUST, IDJAG.OPTIONAL |
| [RFC6749](https://www.rfc-editor.org/rfc/rfc6749.txt) | Sections 2.2, 3.3, 4.4, 5.1 and 5.2 as used by client credentials, enterprise exchange and OAuth errors. Other grant types and AS operation are outside this dependency scope. | RFC6749.IDENTITY, RFC6749.RESPONSES |
| [RFC6750](https://www.rfc-editor.org/rfc/rfc6750.txt) | Sections 2.1, 3 and 5 for HTTP bearer token transmission, challenges and token handling. Query/form token transmission is not adopted. | RFC6750.HEADER, RFC6750.STORAGE |
| [RFC7523](https://www.rfc-editor.org/rfc/rfc7523.txt) | Sections 2, 3 and 5 for JWT client authentication and authorization grants. Issuer trust, replay and issuing policy are separated from signature helpers. | RFC7523.CLIENT, RFC7523.GRANT, RFC7523.POLICY |
| [RFC8414](https://www.rfc-editor.org/rfc/rfc8414.txt) | Sections 2, 3 and 6 for AS metadata publication/discovery/validation. Signed metadata is not adopted. | RFC8414.DISCOVERY, RFC8414.SECURITY |
| [RFC8693](https://www.rfc-editor.org/rfc/rfc8693.txt) | Sections 2.1, 2.2 and 4 for enterprise token exchange. Arbitrary delegation chains are not adopted. | RFC8693.REQUEST, RFC8693.RESPONSE, RFC8693.DELEGATION |
| [RFC8707](https://www.rfc-editor.org/rfc/rfc8707.txt) | Section 2 and security considerations for single-resource MCP token requests. Multiple-resource token issuance remains host policy. | RFC8707.RESOURCE |
| [RFC9207](https://www.rfc-editor.org/rfc/rfc9207.txt) | Sections 2.1 through 2.4 for metadata advertisement and authorization response issuer validation. | RFC9207.ISS |
| [RFC9728](https://www.rfc-editor.org/rfc/rfc9728.txt) | Sections 2 through 5 and 7 for protected-resource metadata discovery, validation, challenges and resource binding. Signed metadata is not adopted. | RFC9728.RESOURCE, RFC9728.SECURITY |
| [OAUTH21](https://www.ietf.org/archive/id/draft-ietf-oauth-v2-1-13.txt) | Draft-13 sections 1.5, 2, 3, 4.1, 4.2, 4.3, 5 and 7 in the adopted authorization-code, confidential client-credentials and bearer profiles; AS issuance and deployment duties remain host-owned. | OAUTH.CLIENT, OAUTH.PKCE, OAUTH.CC, OAUTH.REFRESH, OAUTH.BEARER, OAUTH.DEPLOYMENT |
| [OAUTH21_REFRESH](https://www.ietf.org/archive/id/draft-ietf-oauth-v2-1-14.txt) | Draft-14 section 4.3, explicitly referenced by core refresh-token confidentiality guidance. Other draft-14 changes are not adopted over draft-13. | OAUTH.REFRESH14 |
| [CIMD00](https://www.ietf.org/archive/id/draft-ietf-oauth-client-id-metadata-document-00.txt) | Draft-00 sections 3 through 6 for core client metadata documents and their host/AS requirements. This is the revision incorporated by core 2026-07-28. | CIMD.CORE, CIMD.SECURITY |
| [CIMD01](https://www.ietf.org/archive/id/draft-ietf-oauth-client-id-metadata-document-01.txt) | Draft-01 section 6.2 only, incorporated by Enterprise for optional private_key_jwt client metadata. Other draft-01 changes are not silently adopted. | CIMD.JWT |
| [RFC7591](https://www.rfc-editor.org/rfc/rfc7591.txt) | Sections 2 and 3 and security considerations for optional legacy DCR requests, responses and error handling. Registration management is not adopted. | DCR.REQUEST, DCR.RESPONSE |
| [OIDC_DISCOVERY](https://openid.net/specs/openid-connect-discovery-1_0.html) | Provider configuration discovery and validation sections 3 and 4 as an alternative to RFC8414; initial user SSO and full OIDC Relying Party behavior are host-owned. | OIDC.METADATA |
| [OIDC_REGISTRATION](https://openid.net/specs/openid-connect-registration-1_0.html) | Section 2 application_type and redirect registration constraints inherited by optional DCR. Other OIDC registration profiles are not adopted. | OIDC.APP_TYPE |

## Evidence and responsibilities

The official modern core scenarios remain the first choice for wire assertions.
Raw results are checked by scenario, check ID, check name, status and count,
including unexpected skips. Fixture catalog mutation uses normal registry and
publication APIs; the header scenario invokes resource and prompt operations.
Client cases run separately to isolate observed concurrent-fixture interference.
No upstream assertions or library deadlines were relaxed.

The modern header scenario cannot send legacy `initialize` or
`notifications/initialized`; those two exact skips remain visible and do not
qualify modern behavior. Separate legacy conformance exercises those methods.
INFO wire observations never count as passing assertions.

Existing local assertions supply bounded framing, metadata, pagination, dialect,
subscription and OAuth policy evidence. Five new S256 discovery contracts cover
the automatic-code-flow gap found here; the PKCE-pair compliance test is reused.

Initial OIDC/SAML SSO, XML/NameID validation, tenant and subject resolution,
authenticated AS client binding, assertion replay consumption, issuance policy,
consent/browser UI, durable storage and deployment TLS/access policy remain host,
IdP or AS duties. `IdJagHandler` returns validated claims for further checks; it
does not authenticate the token-endpoint caller or authorize/issue tokens. Hosts
adopting DPoP/cnf, actor delegation, RAR or multiple-resource grants must enforce
those profiles before issuance. A parsed and signed JWT does not authorize them.

## Everything 2.1.0 qualification

`UPSTREAM-2026-11-01-001` is assessed. The [2.1.0 changes](https://www.npmjs.com/package/@modelcontextprotocol/server-everything/v/2.1.0)
cover credential-like environment masking, fetch address/redirect policy, HTTP
failure handling, elicitation summary fields, resource-link documentation and PNG
validity. They require no change to Arbor MCP wire semantics. All 29 existing
legacy/modern HTTP interop tests pass with the new exact pin. This qualifies those
operations and cleanup paths, not every optional Everything or Auth feature.
Package-lock and tooling pins advance together; the monitor never repins.

## Tasks source disposition

The pinned Tasks prose and TypeScript schema are preserved in
`docs/mcp-specs/2026-07-28/extensions/`. The manifest
`scripts/mcp_tasks_requirement_sources.json` binds their hashes, every top-level
section and every exported schema type to requirement dispositions. CI rejects
changed snapshots, missing sections/types and unmapped bundles. These are
inventory checks, not execution results. Existing negotiation, store, validation
and HTTP notification tests plus a public-client HTTP input/cancel cycle supply
named evidence. The official notification scenario remains a stub; independent
Tasks SDK interop is not qualified. Hosts drive polling and durable task-ID/input
tracking; ETS alone does not survive a process/node restart.
