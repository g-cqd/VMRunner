---
status: pending
blocked-by: []
date: 2026-10-21
decision: ADR-0019
---
# 0029 — A confined, fail-closed module for private API

Study: `docs/research/private-apis-2026-10.md`. `PrivateInterfaces` with a capability registry, contract tests per OS build,
a canary and a leak check; first capabilities are the platform PMU setter and the Seatbelt apply call.

2026-10-25: ADR-0059 starts the module with the PMU capability alone, for Windows on ARM (roadmap 0015). The module calls the
Objective-C runtime itself and imports no interop package; the Seatbelt capability is not part of that start. On macOS 27.0.1
(build 26A434) the setter has encoding `v20@0:8B16`, the getter `B16@0:8`, and the value read back follows the value set.

## Done when

The module exists, a lint test keeps private lookups out of every other target, both capabilities validate on this host (or
report themselves off with a reason), and the Hardened preset disables them.

## Owed upstream

2026-10-25: nothing is owed while the interop package is not imported (ADR-0059). The list applies if it ever is.

Tags for the interop package, OS gating, per-feature switches, redacted logging, `dlsym` support and contract tests against
the virtualization classes.
