# Four-package source archive consumer

The CI workflow now builds the publishable source archives for `arbor_mcp`,
`arbor_rpc`, `arbor_acp` and `arbor_acp_adapters`, then installs all four into one
fresh application. Current CI checks out the RPC repository independently from
ACP; its Mix project is at the root of `trust-arbor/arbor_rpc`. The workflow pins
both external repositories, and the MCP archive comes from its checked-out commit.
The historical ACP-hosted checkpoint described below used
`0e4cfd1efdb7437eb6cf4c944ed6fa04553da7bb` for core, adapters and RPC.
Packaging runs without unpublished dependency
overrides. The consumer explicitly overrides only the four unpublished Arbor
packages with their extracted source archives. CI resolves external dependencies
through Hex.

The installer rejects absolute/traversing paths, links, and generated `priv`,
test, dependency and build entries. Source compilation must install the RPC
helper through the package compiler. The probe checks all four application and
module identities, adapter availability in the adapter bundle, absence of vendor
adapters in ACP core, and absence of the optional HTTP listener stacks.

Actual MCP runtime requests and ACP agent/client session and prompt operations
run together over the public memory transport. Stopping MCP leaves ACP usable;
disconnecting ACP leaves a sibling MCP runtime usable. This is application and
protocol lifetime evidence; it does not launch a vendor CLI adapter or qualify
an HTTP listener.

The native subprocess probe runs with no compiler discoverable in `PATH` and
an unusable `CC`. It requires the installed helper in `:code.priv_dir(:arbor_rpc)`,
exact CRLF/final stdout bytes, the child's nonzero exit status, a retained typed
cleanup receipt after process-group close, and idempotent close. The complete
probe runs first from the installed application and then from an assembled Mix
release with ERTS included. Source installation still requires a C17 compiler;
that is the current draft packaging assumption.

Local qualification at MCP `f3727f54b07a5626a17f53bb6ac0eac5c767adf5` and the ACP
pin passed all five installation/release steps on Elixir 1.17.3/OTP 27.0.1 and
Elixir 1.19.5/OTP 28.4.1. Each toolchain used independent copied external sources;
all four archive SHA-256 pairs matched across the two toolchains. The local
archive manifest and logs are kept outside the package under
`tmp/archive-consumer-qualification`. This named checkpoint predates the later
normalization/output integration; CI builds each later MCP commit anew.

Both consumer jobs preserve their qualified source archives as CI artifacts.
Neither this fixture nor its local qualification proves published Arbor Hex
version-range resolution, all platform support, final RC artifact identity, or
RC soak. Those remain release gates.
