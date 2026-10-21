---
status: accepted
date: 2026-10-21
---
# 0008 — Test support is vendored and allocation counting is per thread

## Context

Deterministic tests of time-dependent and concurrent code need a controllable clock, event probes and gates. Performance
guards need to count heap allocations.

## Decision

1. A small test-support target (`TestKit`) provides a test clock, a continuation registry, an event probe, async gates
   and latches, a process probe and an allocation counter that hooks libmalloc's logger. It is linked by test targets
   only. The hook is private API and is acceptable only for test code.
2. The counter counts only on the measuring thread, identified with `pthread_self()`. A process-wide counter absorbed the
   allocations of suites running in parallel; a thread-local variable was avoided because its first access can allocate
   and re-enter the hook.
3. Allocation guards take the minimum over several attempts and report nothing where counting is unavailable, as under a
   sanitizer.

## Evidence

Two rendezvous tests hung about one run in four: a waiter took its baseline when it first ran, and the test parked the
next sleeper without waiting for the waiter to register. They now wait for registration; 100 consecutive runs passed.
The parallel-suite interference was visible as failing ceilings in 5 of 5 runs before the per-thread change and as 0 of
15 after it.

## Consequences

The kit is excluded from SwiftLint, the clone detector and the dead-code analyzer: its internals repeat by design and its
public surface is used only by tests.

## What this does not decide

Whether the kit becomes its own package.
