---
status: in-progress
blocked-by: []
date: 2026-10-22
---
# 0035 — Contribute reusable components to the owner's shared utility library

Study: `docs/research/reusable-code-survey-2026-10.md`. Work happens on branches of that library's repository, prepared as
patches for review; this repository keeps its own copy of anything that gates installer trust (ADR-0001: the app links system
frameworks only).

## Contributions, in order

1. Configurable Base64 decoding and encoding (alphabet, padding, trailing bits, whitespace, line length, typed errors), with a
   strict canonical preset for signature-bearing armor and the lenient behaviour kept as the default. In progress.
2. The async probes and support utilities: clock-injectable timeouts, count-only probes with diagnostics, registration marks,
   the confirmed fixes from roadmap 0031. This repository then syncs its vendored copy from there.
3. The per-thread allocation window and the retired-instruction benchmark recorder.
4. Packet header parsing, internet checksum arithmetic and the fixed-slot rings (after roadmap 0032 isolates them).
5. The clock-injected debounce and poll helpers.

## Done when

Each contribution is a reviewed patch series with tests, and this repository either consumes it by an exact pin (if the
dependency fits ADR-0001) or syncs its copy and records the version.
