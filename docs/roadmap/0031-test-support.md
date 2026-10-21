---
status: pending
blocked-by: []
date: 2026-10-22
---
# 0031 — Test support: confirm the suspected defects, then port the missing facilities

Study: `docs/research/test-support-comparison-2026-10.md`. The vendored test support (`Sources/TestKit`) diverged from the
shared utility library it came from, and from the owner's mobile app's newer copy. The shared library becomes the source of
truth: improvements land there first (roadmap 0035), then the vendored copy is synced.

## Done when

1. Each of the ten suspected defects in the study has a reproducing test that fails, or is recorded as refuted:
   the gated-batch holder leak when the body throws; non-atomic `advance(to:)`; stale heap slots after cancelled sleepers;
   the probe's own timeout sleeper counted by `sleeperCount`; the registration baseline hang in `waitForAdditionalSleepers`;
   `AllocationWindow`'s global watched thread; `UnsafeContinuation` sleepers that are never drained; the O(n²) snapshot in
   `AsyncEventProbe.record`; the default `sleep(for:)` race; the missing tests (probe, clock, process probe).
2. The facilities are ported in this order, each with its tests: `RegistrationMark`; a count-only probe with a label and the
   recorded events in its timeout message; `TaskProvider`, `TaskRole`, the live provider and a spy that tracks work and
   observations; a deallocation probe; `waitForObservedState`; a manual-completion service double; a scoped Swift Testing URL
   stub; the thread gate the documentation already mentions.
3. Production types that spawn raw `Task {}` take the provider (`Debouncer`, `RuntimeLimit`, `ConfigPersistence`,
   `VPNMonitor`, `VMLibrary`, `NetworkActivity`), and the `Task.yield()` loops in tests are gone.

Not ported: timer subclasses, XCTest-only helpers, the old global URL protocol stub, handshake gates that are production code.
