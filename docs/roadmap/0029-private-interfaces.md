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

2026-10-25: the module exists as `Sources/PrivateInterfaces` with the PMU capability: a registry entry with the verified
builds (Darwin 26, macOS 27), the method contract, a read-back of the value set and a kill switch, a fake resolver for the
fail-closed paths and a contract test that skips where the selectors are absent. A test in `DevToolsTests` keeps the
runtime's lookup functions out of every other target. Policy (the Hardened and Isolated postures, the managed key) is not
part of the module.

2026-10-25: the policy is in the app. `PrivateCapabilityPolicy.decide` turns a private interface off when the machine matches the
Isolated or Hardened profile, when the managed key `AllowPrivateInterfaces` is forced to anything but true, or when the developer
default `DisablePrivateInterfaces` is on, and it names the first of those in that order. The exposure summary lists each private
interface a machine would use, and the help has a topic for them. No guest uses one yet.

## Done when

The module exists, a lint test keeps private lookups out of every other target, both capabilities validate on this host (or
report themselves off with a reason), and the Hardened preset disables them.

## Owed upstream

2026-10-25: nothing is owed while the interop package is not imported (ADR-0059). The list applies if it ever is.

Tags for the interop package, OS gating, per-feature switches, redacted logging, `dlsym` support and contract tests against
the virtualization classes.
