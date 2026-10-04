# Per-member batch work admission prerequisite

This isolated MCP candidate adds conservative work permits for legacy JSON-RPC arrays. It is based on canonical `1ba2630e772d1ebee752e6eaae40d5db77795412` and includes the five qualified caller-identity source/test prerequisites. It does not wire the output ledger, change callback state-commit order, or converge stdio/HTTP output.

## Count contract

The data lane holds at most `max_concurrency + max_queue` work permits. A decoded legacy array reserves one permit for **each member**, including requests, notifications, invalid values, and members that will later be cancelled. A non-array envelope reserves one permit. An empty invalid array also reserves one permit so invalid-envelope processing has bounded count capacity.

One envelope keeps one token, one reservation, and a set of permit positions. A single `:ets.insert_new(table, records)` atomically claims its complete set. Insufficient free capacity or a conflicting concurrent claim retains no partial set. Allocation uses available positions, including holes left by earlier envelopes; it makes at most 512 contention attempts and checks the original reservation deadline. Capacity exhaustion returns the existing `:server_busy` admission error before callbacks.

All member permits remain held while the existing edge promotes individual members through that reservation. `release_step` does not release a member's permit early. Normal settlement, explicit discard, scope cancellation, expiry, producer/owner death, or runtime retirement releases the complete set. One token-and-producer-matched ETS deletion removes all permit records atomically; a repeated release cannot delete positions subsequently reused by another token. Byte credit is released idempotently through the existing `ByteBudget` ledger. Count deletion and byte-credit cleanup are separate operations, with conservative intermediate accounting.

Legacy member order, grouped response order, notification omission, future-ID cancellation semantics, and validation error shapes remain unchanged. Modern arrays that reach protocol validation still reject all members before callbacks. Admission capacity applies before protocol validation, so an over-capacity array receives the ordinary overload result. The existing BEAM legacy golden now configures three work positions for its three-member array rather than allowing that array to bypass a one-position limit.

## Byte contract and ownership

The existing serialized input envelope, dispatch context, and retained options are charged **once**. An array additionally charges the serialized permit records and its new `{slot, slots, work_count}` reservation metadata once. Member payloads are not copied or charged separately per member. The complete count claim is rolled back if the aggregate byte claim fails; its payload cannot reach the edge or callbacks through a failed admission.

Fixed single-envelope VM bookkeeping remains bounded by count under the existing non-array byte contract. Permit records exist between count admission and the byte claim and are count-bounded; abandoned records are reaped. These limits describe logical serialized retained input/options/array permit data, not allocator/RSS, producer-owned input, ETS transient copies, callback state, callback output, or accumulated batch replies. Output aggregation and pressure measurement remain separate release prerequisites.

The candidate retains the qualified producer/caller/lifetime-owner distinction. Atomic checkout transfers monitoring to the lifetime owner; a former producer may exit without terminating accepted edge-owned work. Dead unconfirmed producers are deduplicated by token and reaped as complete permit sets. Generation/scope retirement and the existing shutdown guard continue to own runtime cleanup.

This slice does not repair the separate existing fixed confirmation wait or caller-wait budget refresh. Absolute confirmation/caller-wait handling is being qualified separately; it must preserve the reservation's original deadline when combined with this count claim.

## Observability

`Runtime.stats/1` keeps Scheduler `active` and `queued` as callback/envelope counts. Admission reports:

| Field | Meaning |
| --- | --- |
| `reserved` | All claimed permit positions across data and both control lanes, including unconfirmed claims. |
| `reserved_envelopes` | Distinct claimed tokens across those lanes. |
| `admitted_work` | Claimed data-lane work positions, including every held array member. |
| `admitted_envelopes` | Distinct claimed data-lane tokens. |
| `confirmed_work` | Data work permits held by confirmed reservation records. |
| `confirmed` | Confirmed reservation/envelope records across all lanes. |
| `pending_bytes` | Existing byte-ledger use across the three lanes, including the array permit charge. |

Stats are observations of separate ledger operations, not an atomic snapshot of every runtime component.

## Qualification and remaining integration

The focused qualification starts the application and ExUnit directly, without the repository test helper's global OS-port cleanup. It runs the existing runtime/caller-identity cases plus 14 batch cases. The current Elixir 1.19.5/OTP 28.4.1 run passed **86 tests**, warnings-as-errors application compilation, full formatting, and strict Credo with no new filters.

The new cases cover exact-full count capacity, rejected partial count admission, permit holes, observed byte edges and rollback, 60 concurrent producers while Admission is suspended, token-only confirmation messages, dead-candidate reaping and readmission, producer-to-owner handoff, owner death, unbound expiry, future-member and whole-scope cancellation, notification-only arrays, invalid members, empty arrays, and modern rejection.

The final focused suite passed 86 tests on Elixir 1.17.3/OTP 27.0.1, Elixir 1.19.5/OTP 28.4.1, and Elixir 1.20.3/OTP 29.0.5. All three passed warnings-as-errors application compilation and full formatting. The older isolated full-application run had one failure in a ModernStdio child fixture that did not inherit the private dependency paths; no batch cases failed. The integrated candidate includes the independently qualified fixture correction and passed 104 combined cases on minimum/current toolchains. Output preparation before state commit, aggregate batch output accounting, runtime-owned writers, accepted-output EOF drain, HTTP/store scope convergence, and same-runner throughput/mailbox pressure remain separate prerequisites.
