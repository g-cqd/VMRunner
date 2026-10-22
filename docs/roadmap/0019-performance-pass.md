---
status: done
blocked-by: []
date: 2026-10-21
decision: ADR-0007
---
# 0019 — Measure and remove latency and memory on the paths that matter

Done: debounced settings writes, allocation-free packet paths, the runtime limit's timer (`RuntimeLimit`, on an
injected clock and tested on `TestClock`), the display-resize debounce (`Debouncer`) and the launch poll (`poll`) on
the same seam, the help-search index built once instead of per query, the network tests on the shared per-thread
allocation counter with tightened ceilings, and a benchmark gate for checksum throughput and the policy decision
(ADR-0022). What remains (a reusable hashing read buffer, merged digest loops, a table-driven CRC) is roadmap 0033.
