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

## Owed

Push and apply the ruleset; a Developer ID build (the virtualization entitlement under Developer ID is unverified);
pinned SwiftLint; an allocation and benchmark regression gate.
