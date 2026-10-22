---
status: in-progress
blocked-by: []
date: 2026-10-22
decision: ADR-0041
---
# 0040 — Machine state transitions must be explicit, complete and tested

**Priority: very high, with roadmap 0037 to 0039.** The owner reports that the state transitions of a machine are buggy.
The audit started from the code and the owner's first repro; the findings are in `docs/research/machine-states-2026-10.md`
and the design is ADR-0041. More repro steps are added here as they arrive.

## The owner's first symptoms (bundled release app)

1. Clicking **Pause** had no visible effect: the toolbar button stayed "Pause" and nothing on screen showed the machine as
   paused.
2. **Shut Down** had no visible effect.
3. Clicking **Pause again** later raised an alert about an invalid transition, and still nothing proved on screen that the
   machine was paused.

What the code says: the interface learned the framework's state from a key-value observation of
`VZVirtualMachine.state`, which neither the documentation nor the SDK header says is observable; a second Pause that the
framework refuses means the machine was already paused while the interface still said running. Shut Down was invisible when
it worked (nothing showed the request) and raised the framework's own text when the machine was paused. Pause, Shut Down
and Force Stop were enabled in every state, and the framework's error text reached the user. The new design does not use the
observation: the state follows the outcome of each call, the controls come from the table, a paused machine is dimmed and
labelled over the display with Resume on it, and "Pausing…", "Shutting down…" and "Stopping…" are shown while they last.
These sequences are regression tests (`MachineRunningTests`).

## What exists today

The state of one machine was spread over the view model's phase (setting up, setup incomplete, running, editing), the
controller's own flags (active, can suspend, paused) derived from the framework's state and delegate callbacks, the
library's job table and its start, suspend and stop entry points, the runtime limit's timer, the disposable machine's
discard step, and the saved-state file's presence. After this work, `MachineState` is one value moved by one pure function,
`VMController` owns it, and the view model and the interface read it (ADR-0041). The setup job (running, failed, unwinding
after a cancel) stays in the library's job table and no longer overlaps a new job.

## Hypotheses tested

1. Actions can overlap: start while a stop is pending, suspend during start, stop during suspend, resume during pause,
   delete or duplicate while active, quitting mid-transition. **Partly real**: a double Suspend deleted its own image, a
   Suspend during a restore deleted the image being restored, a running machine could be duplicated, a quit mid-suspend left
   a partial image. A start while a stop is pending and a double Start were already refused.
2. The delegate callbacks and the user's actions race. **Real**: a start that failed late released the run that replaced it,
   and a restore that failed after a force stop booted a cold machine anyway. A late guest-stopped callback was matched by
   object identity, which can be reused; every report now carries its run.
3. Failure paths leave state behind. **Real**: a restore finishing after a force stop armed the runtime limit and left the
   machine running unseen; a cold boot left a memory image it could not use; a second window's load task deleted the
   disposable copy of a running machine; suspend support was never cleared.
4. The phase and the controller's activity disagree. **Real**: the copy of the framework's state stayed `.stopped` while the
   controller was active, until an announcement came, if it did.
5. Pause and resume, and suspend and restore, mix up the can-suspend decision and the file's presence. **Real**, see 1 and 3.

## Done when

1. The legal states and transitions are one explicit type with a pure transition function (state, event, new state and the
   effects to perform), and the controller, the library and the view model drive and observe that one machine. *Done:*
   `MachineState.transition(on:)`, `VMController`, `MachineModel.state`.
2. A table-driven test covers every state against every event (legal ones reach the expected state and effects, illegal ones
   are refused without side effects), plus sequences for the races above on the test clock and the fake framework seam.
   *Done:* `MachineStateTests`, `MachineStartTests`, `MachineRunningTests`, `MachineStopTests`, `MachineSuspendTests`,
   `LibraryMachineTests`; each async suite passed 100 consecutive runs.
3. Every failure path ends in a defined state with its resources released, checked by tests. *Done:* one `release` effect,
   and a test that every way a run can end leaves nothing held and the machine startable again.
4. The owner confirms on a real guest: start, stop, force stop (also during a start and during a pause), guest shutdown
   (also a guest that ignores the power button), pause and resume, suspend and restore, disposable discard, quit while
   running and while suspending, repeated rapid clicks; the transitions seen are in the diary. *Open.* Look for: the Paused
   layer and the Resume button after Pause; the "Pausing…", "Shutting down…" and "Stopping…" badges; Shut Down greyed while
   paused; a force stop during a start ending with the settings form back and no stray
   `com.apple.Virtualization.VirtualMachine` process; a second window opened from the Dock leaving a running disposable
   machine alone; a suspend then a restore, and a double click on Suspend leaving the image in place.

## Not verified, and left for later

- Whether the framework allows `stop()` while a machine starts, pauses or saves (the design works either way), whether it
  calls the delegate after a successful `stop()`, and whether the state observation ever fired: all need a guest.
- The memory image is written in place; a crash in the middle of a suspend can leave a partial image, which a later restore
  rejects and falls back from. Writing it under a temporary name and renaming it is a separate change.
- An activity assertion or an input-latency monitor that another change hooks into a machine's start and stop belongs in
  the two places the controller has for it: the `armRuntimeLimit` effect (the machine is running) and `release` (it is gone).
