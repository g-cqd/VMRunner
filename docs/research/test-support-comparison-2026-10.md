---
date: 2026-10-22
question: "What does the vendored test support lack compared with the shared utility library and the owner's mobile app, and what is wrong in it?"
feeds: [roadmap 0031, roadmap 0035]
---
# Test support compared with its sources

Study, not a decision record. Everything comes from reading code and history; no test was run and nothing was changed.
Items marked *inferred* are reasoning from the code and need a reproducing test (roadmap 0031).

## Where the pieces come from

- The vendored test support is a copy of the shared utility library's test kit, with later work: a per-thread allocation
  window, a benchmark recorder, a tag for benchmarks. The clock, probes, gates, latch and continuation registry are the
  library's, differing by indentation and one accessor.
- The library also has a second family used by its app tier: a count probe (the successor of the mobile app's async probe), a
  task provider and spies, a task gate, an async semaphore, and a clock with a registration mark.
- The mobile app's newest test support is on its main development branch, not in the checked-out development worktree.
  It has a manual clock on `Mutex` with `CheckedContinuation`, an async probe with a count-only mode and rich timeout messages,
  a task provider seam with a spy that tracks work and observations, a deallocation probe, a wait on observed state, a
  service double whose requests are completed manually and out of order, and scripted transport doubles.
- Not found anywhere in the app: allocation counting, sanitizer-aware helpers, a deterministic executor, a repeat runner, a
  fake URL session. The "manual endpoint resolution" the owner named is read as the manually completed service double.

## Differences that matter

| Aspect | Vendored copy | Mobile app |
|---|---|---|
| Continuations | `UnsafeContinuation`: a never-resumed one hangs silently | `CheckedContinuation`: misuse is diagnosed |
| Wake order | Heap: deadline, then id | Insertion order, array scan |
| Waiting for sleepers | Throws on cancel; extra helpers | Non-throwing: a cancelled waiter looks satisfied |
| Probe timeout | Clock-injectable, returns the events | Real clock (60 s), richer message, count-only mode |
| Tests | Rendezvous only; none for probe or clock | 182 and 175 lines for clock and probe |
| Allocation counting | Per-thread window | None |

## Suspected defects in the vendored copy (all inferred)

1. The gated-batch helper starts a holder task and never opens the gate or cancels the holder when the body throws.
2. `advance(to:)` reads the time, releases the lock, then advances: two concurrent calls can overshoot.
3. Cancelled sleepers leave stale heap slots until a later wake passes their key; probe timeouts under a test clock are far
   deadlines that are never passed.
4. The probe's own timeout sleeper counts toward the clock's sleeper count and can satisfy a rendezvous early.
5. `waitForAdditionalSleepers` takes its baseline when it starts, so sleepers that registered first make it wait forever.
6. `AllocationWindow` stores the watched thread in a global before taking the serialising lock.
7. Parked sleepers are never drained at the end of a test.
8. `record` hands waiters a snapshot, so the next append copies the whole array (quadratic for long streams).
9. The default `sleep(for:)` reads the time and then sleeps until a deadline: an `advance` between them makes it past.
10. No tests for the probe, the basic clock behaviour or the process probe; documentation points at helpers that are not present.

## Recommended order

Close the gaps and add tests; registration marks; count-only probe with diagnostics; the task provider and spy, then adopt it in
the types that spawn raw tasks; deallocation probe; observed-state wait; manual-completion service double; a scoped URL stub.
Skip timer subclasses, XCTest-only helpers and the old global URL stub.

## Not verified

No defect was reproduced. The meaning of "manual endpoint resolution" is an interpretation. The task-immediate API's
availability on the shared library's deployment floor is from memory.
