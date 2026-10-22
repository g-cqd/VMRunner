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
   running and while suspending, repeated rapid clicks; the transitions seen are in the diary. *Partly done on a Linux guest, see "Verified on a real guest"; the guest that handles a power request and the cases listed there remain.* Look for: the Paused
   layer and the Resume button after Pause; the "Pausing…", "Shutting down…" and "Stopping…" badges; Shut Down greyed while
   paused; a force stop during a start ending with the settings form back and no stray
   `com.apple.Virtualization.VirtualMachine` process; a second window opened from the Dock leaving a running disposable
   machine alone; a suspend then a restore, and a double click on Suspend leaving the image in place.

## Not verified, and left for later

- Whether the framework allows `stop()` while a machine starts, pauses or saves (the design works either way), whether it
  calls the delegate after a successful `stop()`, and whether the state observation ever fired: all need a guest.
- *Done:* the memory image used to be written in place, so a crash in the middle of a suspend left a partial image for a later
  restore to reject. It is now written under a temporary name beside the final one, flushed, and renamed over it
  (`VMBundle.commitSavedState`); a failure removes the temporary, and the next start sweeps one a crash left.
- *Done:* `--start` skipped a machine that was unprovisioned or mid-setup without a word. It now logs the reason (without the
  machine's name) and shows it in the library alert (`LaunchStart.decide`, tested as pure code). `VMLibrary.load()` also runs
  once now: a second window's load task used to replace the machines in memory with the files on disk, losing settings still
  waiting to be written.
- The latency activity (roadmap 0037) is held when the controller receives a prepared machine and ended where the machine is
  let go, so it is released on every path that releases the machine; the tests check it after every ending.

## Verified on a real guest (2026-10-22)

Same session and machine as roadmap 0038 (Alpine 3.24.2, Linux, scratch data folder, release app; the buttons were pressed and
read through the accessibility interface of the app's own process, and its window captured). Button state below is read from the
toolbar, not guessed.

| Transition | Observed |
|---|---|
| Pause | the button became **Resume**, the toolbar showed "Paused", **Shut Down went disabled**, Suspend and Force Stop stayed enabled; the picture was dimmed with a "Paused" layer and a Resume button over it; the sidebar dot turned orange. Three presses at once: one pause, no alert |
| Resume | back to Pause with everything enabled; three presses at once: one resume, no alert |
| Shut Down, guest that ignores it | Alpine never stopped. The toolbar and the layer over the display said "Shutting down…" (the layer carries a Force Stop button, the sidebar dot turned yellow) for as long as the request stood (20 s; seven minutes with three more requests on the same boot; the same again on a second boot); Shut Down stayed enabled to ask again |
| Shut Down, guest that handles it | **not obtained.** In Alpine's kernel the ACPI Power Button input device exists (`ACPI: button: Power Button [PWRB]`, `/dev/input/event2`), but a reader on it and `acpi_listen` (after installing `acpid`) saw no byte after the app's requests, so this guest never reacts to the framework's request whatever userspace does. The app calls `requestStop()` (code), and the framework returns no error; why no event arrives was not found (a kernel without the generic event device is the first suspect). The other way a guest ends on its own, `poweroff` typed in the guest, was tried: the app returned to Start within 2 s and the framework's helper process was gone |
| Force Stop | from running, from paused, from "Shutting down…" and 0.4 s after pressing Start: each time the buttons went through the stopping step (Pause, Suspend and Shut Down disabled, Force Stop enabled) to Start alone, the settings form returned, and no `com.apple.Virtualization.VirtualMachine` process of the run was left |
| Suspend | 2 s; `SavedState.vzvmsave` of 96 473 088 bytes, mode 0600, no temporary file left; Start restored it in about 1 s at the remembered size (`source saved state … remembered size used`); a marker written in the guest before the suspend was still there, and the screen showed the pre-suspend text; the image was removed by the restore. Three presses on Suspend at once: one image, no alert |
| Quit while running | Quit in the menu showed "1 virtual machine is still running." Cancel left the app and the machine as they were; Quit Anyway ended the process in under one second, the `total` latency line was written (so the quit path ran) and no framework helper was left. Ending the app with SIGTERM also left no helper |

No defect was found in the state machine on this guest, so no code changed for 0040. Not tried: quit while suspending, a disposable
machine, a second window, Pause while "Shutting down…", macOS guests.
