---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0018
---
# 0021 — A small, fast, hard-to-misread CI and a provenance-attested release

Done: merge queue, cache hygiene, tag-triggered release with attestation, Scorecard, dependency review, templates.
Also done: one lane matrix, the analyzers run through `vmr` so the lock is the single source of truth, heavy lanes skipped for
documentation-only changes, and the documentation check.
Also done: SwiftLint is a pinned, checksum-verified release in `Scripts/analyzers.lock`, installed by `vmr` on first use
and never taken from `PATH` ([ADR-0020](../adr/0020-swiftlint-is-a-pinned-checksum-verified-release.md)); CI and the
contributing guide install nothing.

## Owed

Push and apply the ruleset; a Developer ID build (the virtualization entitlement under Developer ID is unverified);
an allocation and benchmark regression gate.
