---
status: done
blocked-by: []
date: 2026-10-21
decision: ADR-0008
---
# 0018 — A test clock, probes, gates and a per-thread allocation counter

Vendored test support; allocation ceilings on the policy decision; zero-allocation guards in the network stack.

An allocation window (`AllocationWindow`) counts one thread's allocations while another thread opens and closes the window,
for the loop test that runs the loop on a thread of its own. It shares the measurement lock with `mallocDelta`, so the two
never overlap.

Benchmarks are suites tagged `.bench` that report to a results file (`recordBenchmark`, `measureRate`) and are skipped unless one
is named; the gate that reads them is in roadmap 0021 and ADR-0022. The allocation ceilings of the policy decision were
tightened to about 10% above the exact per-thread counts.
