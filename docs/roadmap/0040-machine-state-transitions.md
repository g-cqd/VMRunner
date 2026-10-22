---
status: pending
blocked-by: []
date: 2026-10-22
---
# 0040 — Machine state transitions must be explicit, complete and tested

**Priority: very high, with roadmap 0037 to 0039.** The owner reports that the state transitions of a machine are buggy.
The symptoms are not yet written down; the audit starts from the code and the owner's repro steps are added here as they
arrive.

## What exists today

The state of one machine is spread over several places: the view model's phase (setting up, setup incomplete, running,
editing), the controller's own flags (active, can suspend, paused, stopping) derived from the framework's state and delegate
callbacks, the library's job table and its start, suspend and stop entry points, the runtime limit's timer, the disposable
machine's discard step, and the saved-state file's presence. No single type says which transitions are allowed, and the
delegate callbacks (stopped by the guest, stopped with an error) arrive on the framework's queue.

## Hypotheses to test

1. Actions can overlap: start while a stop is pending, suspend during start, stop during suspend, resume during pause, delete
   or duplicate while active, quitting mid-transition.
2. The delegate callbacks and the user's actions race: a guest shutdown after a force stop, an error after a suspend, a stop
   callback arriving after the next start has begun.
3. Failure paths leave state behind: a start that fails after the network stack began, a restore that fails and falls back,
   a disposable clone not discarded, a runtime limit still armed, the activity or display bound to a dead machine.
4. The view model's phase and the controller's activity disagree for a moment or for good (a running phase for a machine that
   stopped, an editing phase while it still runs).
5. Pause and resume, and saved-state suspend and restore, mix up the can-suspend decision and the file's presence.

## Done when

1. The legal states and transitions are one explicit type with a pure transition function (state, event, new state and the
   effects to perform), and the controller, the library and the view model drive and observe that one machine.
2. A table-driven test covers every state against every event (legal ones reach the expected state and effects, illegal ones
   are refused without side effects), plus sequences for the races above on the test clock and the fake framework seam.
3. Every failure path ends in a defined state with its resources released, checked by tests.
4. The owner confirms on a real guest: start, stop, force stop, guest shutdown, pause and resume, suspend and restore,
   disposable discard, quit while running, repeated rapid clicks; the transitions seen are in the diary.
