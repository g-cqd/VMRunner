---
status: accepted
date: 2026-10-21
---
# 0022 — Performance is a ratchet against a committed baseline, on figures that are stable

## Context

ADR-0008 counts allocations on the measuring thread, and the unit tests hold the policy decision and the network stack to
allocation ceilings. Those ceilings are set by hand in a debug build, nothing holds a throughput figure, and ADR-0018 left a
benchmark and allocation regression gate undecided. Wall-clock time on a shared machine is a poor thing to fail a build on,
so the question is which figures can be gated and how a deliberate change to them is accepted.

## Decision

1. A benchmark is a Swift Testing suite named `...Benchmarks`, tagged `.bench`, that measures and records instead of
   asserting. It appends its figures to the file named by `VMR_BENCH_OUTPUT`, one JSON object per line, through TestKit's
   `recordBenchmark`. Swift Testing cannot exclude a tag from a run, so the suites also carry a trait that skips them unless
   that variable is set: a plain `swift test` does not run them.
2. `swift run vmr check bench` is a full-only step. It runs the benchmark suites alone, one at a time, in an optimized build
   in `.build-bench` (`-enable-testing`, so that they can import the app), and compares the figures with
   `.vmr-bench.json`, committed beside `.vmr.json`. An entry has a value, a direction (lower or higher is better), a
   tolerance (the fraction it may move the wrong way) and whether it is enforced. A figure that moved the wrong way by more
   than its tolerance fails the step; a figure that improved by more than its tolerance passes and prints the command that
   re-records it; an enforced figure missing from the run or from the baseline fails.
3. `swift run vmr bench record` runs the same suites and rewrites the values, keeping the tolerance and enforcement of an
   entry that exists and taking a new figure's own suggestion. A change that is meant to move a figure is committed with
   the re-recorded baseline.
4. What is enforced: allocation counts exactly, and retired instructions per unit of work (`ProcessProbe`) within 3%.
   Wall-clock rates are recorded and reported, and never fail the step.
5. TestKit gains a window mode for the allocation counter (`AllocationWindow`): one thread is counted while another opens
   and closes the window. The window and `mallocDelta` share one measurement lock, held across the calls, so they never
   overlap. The hook still allocates nothing and uses no thread-local variable (ADR-0008).
6. In CI the step is a separate job that is advisory (`continue-on-error`, not a need of `CI passed`) until its runs on the
   hosted runners are stable; it then becomes required.

## Evidence

Ten consecutive runs of the benchmark suites on one machine that other work was using: the wall-clock rates of the two
digests and of the policy decision spread by 63% to 78% between the slowest and the fastest run, retired instructions per
unit spread by 0.2% to 0.8%, and every allocation count was identical. Ten further consecutive `vmr check bench` runs against
the recorded baseline passed, with the rates within 2% of it. The first set is the reason the rates are reported and not
enforced: a quiet machine makes them look stable, a busy one does not.

Allocation counts depend on the build: one policy decision for `example.com` allocates 53 times unoptimized and 5 times
optimized. The unit-test ceilings stay as guards of the debug build and are now about 10% above the exact counts; the
baseline holds the optimized counts.

## Consequences

The step needs a second full build, an optimized one with the tests, in `.build-bench`. The baseline is recorded on one
machine, and the figures may differ on another CPU or operating system release, which is why the CI job does not block
yet. Retired instructions are counted for the whole process, so the suites must run alone, which the step arranges.

## What this does not decide

When the CI job becomes required; whether a throughput figure can be enforced on dedicated hardware; benchmarks on other
platforms.
