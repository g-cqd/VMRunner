---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0018
---
# 0021 — A small, fast, hard-to-misread CI and a provenance-attested release

Done: merge queue, cache hygiene, tag-triggered release with attestation, Scorecard, dependency review, templates.
Under way: collapse the repeated jobs into one lane matrix, run the analyzers through `vmr` so the lock is the single source
of truth, skip heavy lanes for documentation-only changes, and add the documentation check.

## Owed

Push and apply the ruleset; a Developer ID build (the virtualization entitlement under Developer ID is unverified);
pinned SwiftLint; an allocation and benchmark regression gate.
