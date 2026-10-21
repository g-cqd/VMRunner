---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0007
---
# 0019 — Measure and remove latency and memory on the paths that matter

Done: debounced settings writes, allocation-free packet paths, the runtime limit's timer (`RuntimeLimit`, on an
injected clock and tested on `TestClock`), the display-resize debounce (`Debouncer`) and the launch poll (`poll`) on
the same seam. Owed: a precomputed help-search index, checksum throughput profiled with the process probe, the network tests' own
allocation counter replaced by the shared one, and tighter policy-decision ceilings.
