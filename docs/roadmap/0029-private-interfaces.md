---
status: pending
blocked-by: []
date: 2026-10-21
decision: ADR-0019
---
# 0029 — A confined, fail-closed module for private API

Study: `docs/research/private-apis-2026-10.md`. `PrivateInterfaces` with a capability registry, contract tests per OS build,
a canary and a leak check; first capabilities are the platform PMU setter and the Seatbelt apply call.

## Done when

The module exists, a lint test keeps private lookups out of every other target, both capabilities validate on this host (or
report themselves off with a reason), and the Hardened preset disables them.

## Owed upstream

Tags for the interop package, OS gating, per-feature switches, redacted logging, `dlsym` support and contract tests against
the virtualization classes.
