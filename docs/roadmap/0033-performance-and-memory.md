---
status: pending
blocked-by: []
date: 2026-10-22
decision: ADR-0022
---
# 0033 — Performance and memory leftovers

Study: `docs/research/reusable-code-survey-2026-10.md`. The per-packet paths already allocate nothing and SHA-256 runs near
2 GiB/s, so the remaining work is small and every item is gated by `vmr check bench`.

## Done when

1. One reusable read buffer for checksum hashing in the app and in the tooling (roadmap 0019 owed it); one chunk size.
2. One table-driven hex encoder replaces the two copies; the digest loops share a generic over `HashFunction`.
3. A table-driven CRC-24, only while that file is touched.
4. The Regex-based listing and checksum parsers are profiled with the bench harness first; replaced by byte scanners only if
   they cost measurable time.

Not done on purpose: SIMD C kernels, a JSON library for `config.json`, `~Escapable` byte views (they need an experimental
compiler feature), pooled allocators (the fixed-slot rings already allocate nothing), any package dependency for these.
