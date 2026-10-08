# Runtime diagnostics in v2

> **Implementation history.** This page records the runtime-diagnostics implementation checkpoint. Host-owned
> Logger configuration is now implemented and documented in
> [Configuration](CONFIGURATION.md#logging). The final paragraph below records
> the logging gate at this earlier checkpoint, not its current implementation
> status. Release qualification remains separate.

Runtime diagnostic status replaces handler options, initialized state, admitted
requests, prepared output and store payloads with a fixed component name and
aggregate collection counts. GenServer failure reports use the same formatter
and omit recent event payloads. The built-in task/replay stores, subscription
coordinator/listeners, session/resource stores, protocol edge and output
controllers apply this policy.

Native supervisors retain opaque constructor functions instead of printable
argument lists. Each function executes synchronously in the original initiating
caller. The actual OTP parent, child identity, restart policy, startup cutoff
and shutdown budget remain unchanged. No alternate construction process or
new lifetime is introduced.

Handler initialization still runs once in the native Scheduler under its
original initialization deadline. A raised, thrown, exited or returned handler
initialization error now becomes the fixed `:callback_error` reason inside
`:handler_init_failed`; the runtime cannot print the original error value or
handler arguments in its native startup reports. Invalid callback return shapes
still fail initialization.

A failed handler termination hook produces the fixed log message
`MCP handler termination failed` and permits the remaining cleanup to proceed.
The hook's exception value and initialized state are omitted. Termination hooks
remain subject to the original finite runtime shutdown budget. A borrowed stdio
input device's returned error closes input with the fixed `:stdin_error` reason;
its arbitrary error value does not enter the runtime's shutdown reports.

This policy covers the library's supported runtime paths and default diagnostic
reports. Host-selected process names and child IDs, module/function names and
stack locations remain diagnostic metadata. A custom handler or adapter controls
its own logging and processes. Trusted BEAM inspection such as `:sys.get_state/1`
still exposes actual state; explicit `:sys.log/2` debug buffers remain raw in
the debug section of `:sys.get_status/1`, outside its formatted diagnostic
section. Constructor functions retain their arguments for restart. Formatting
is not a restriction on trusted in-VM introspection.

The runtime does not modify VM logger filters to implement redaction. Regression
cases explicitly enable SASL reporting in their isolated test VM so native
supervisor and startup reports participate in the privacy checks. Replacing the
older application/launcher stdio logger configuration remains a separate release
gate until those entry points have their own host logging migration.
