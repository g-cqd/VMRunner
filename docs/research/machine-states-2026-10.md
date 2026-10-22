---
date: 2026-10-22
question: "Which states, events and transitions does a machine have, which exist only by accident, and which interleavings break them?"
feeds: [roadmap 0040, ADR-0041]
---
# The states of a machine: what existed, what was racy, and what replaces it

**Status: audited from the code and pinned by tests; a first real-guest run (2026-10-22) is in roadmap 0040.** Every claim marked *test* was reproduced
with a fake framework machine and a test clock against the controller as it was before the rules (the commit that added
the seam recorded 17 expectations as known issues, each failing on the old logic), and now passes. Claims about what
Virtualization.framework does are from its documentation and SDK headers; claims about what it does in a transitional
state are *unverified* until the owner runs a real guest.

## The owner's report, and what the code says about it

The bundled release app: (1) clicking Pause changed nothing visible and the button stayed "Pause"; (2) Shut Down had no
visible effect; (3) a second Pause raised an invalid-transition alert, and still nothing showed the machine as paused.

| # | Suspect | Evidence | Verdict |
|---|---|---|---|
| a | The interface mirrors the framework's state through a key-value observation, and the mirror does not update | `VMController.observe` copied `machine.state` from `machine.observe(\.state)` through `Task { @MainActor }`. The SDK header (`VZVirtualMachine.h`, `state`: "Execution state of the virtual machine.") and the documentation page for `state` say nothing about key-value observing; `canStart`, `canStop`, `canPause`, `canResume`, `canRequestStop` carry no such statement either. A second Pause that the framework refuses as invalid means the machine was paused while the interface still said running | Consistent with the report and the only path by which `isPaused` (`controller.state == .paused`) could stay false. *Test:* with a fake that never announces a state, the old controller's `state` stays `.stopped` after a pause. Whether the observation fires on a real machine is *unverified*; the new design does not need it |
| b | `forceStop` skips `stop()` when `canStop` is false but still drops the machine | `forceStop` called `stop()` only `if machine.canStop` and `tearDown()` after, dropping the reference and detaching the view. The documentation of `stop` says it works on a running or paused machine; `canStop` is not documented for a starting, pausing or saving one | Real. A machine that was starting, pausing or restoring was released unstopped and the view went back to the settings form while it could come up behind it. *Test* (restore finishing after a force stop: machine left running, limit armed) |
| c | A guest that ignores the power request looks like "no effect" | `requestStop` only wrote an error to `errorMessage`; nothing in the state or the screen changed when the request succeeded | Real. A request that the guest never answers was invisible; a request refused for a paused machine was the framework's text. Shut Down is now a visible state |
| d | Buttons are enabled by no table | Pause and Shut Down were enabled in every active state; Resume only by `state == .paused` | Real, see the table below |

## Where the state lived

The state of a run was the product of: `virtualMachine` (set synchronously in `attach`), a copy of the framework's state
(`state`), `canSuspend` and `suspendUnavailableReason` (written at start, never cleared), `deadline`, `network` and
`activeBundle` (cleared by `tearDown`), the runtime limit's timer, the saved-state file (`hasSavedState`), and, for the
interface, the library's `jobs[id]` and `config.isProvisioned`. `MachineModel.phase` read three of them.

Implicit states, and how they could be told apart:

| State | Marker before | Defect |
|---|---|---|
| Idle | `virtualMachine == nil` | `canSuspend` still true |
| Starting, restoring | `virtualMachine != nil`, `state` copied once at attach (so `.stopped`) until an announcement | Suspend, Pause, Shut Down enabled; `isActive` true while `state == .stopped` |
| Running | `state == .running` | |
| Shutdown asked | none | invisible; the request's only trace is the framework's own state |
| Pausing, resuming | the framework's transient state, if announced | Pause shown again while resuming |
| Paused | `state == .paused` | Shut Down enabled (the framework refuses it) |
| Suspending | none: a task awaiting inside `suspend(to:)` | a second Suspend ran the same steps again |
| Force stopping | none: `virtualMachine` still set during `await stop()` | |
| Released | `tearDown()` | called from five places, one of them unguarded by run |

## Events and what handled them

| Event | Source | Handler before | Guard before |
|---|---|---|---|
| Start | toolbar, menu, `--start`, approval dialog | `library.startMachine` → `Task { controller.start }` | `virtualMachine == nil` (sound: `attach` runs before the first suspension) |
| Pause, Resume | toolbar, menu | `virtualMachine?.pause()` / `resume()` | none |
| Shut Down | toolbar, menu, runtime limit | `virtualMachine?.requestStop()` | none |
| Force Stop | toolbar, menu, limit grace | `stop()` if `canStop`, then `tearDown()` | none |
| Suspend | toolbar, menu | `library.suspendMachine` → `controller.suspend(to:)` | `virtualMachine != nil && canSuspend` |
| Guest stopped, stopped with error | delegate, hop to the main actor | `tearDown()` | identity of the machine (an `ObjectIdentifier`, which can be reused once the object is freed) |
| Framework state changed | key-value observation | copy | identity |
| Runtime limit | timer | `requestStop()`, then `forceStop()` after 30 s | none: the callbacks were not tied to a run |
| Quit | app delegate | alert if any machine is active; flush and sweep | the controllers were told nothing |
| Delete, duplicate | menu | `delete` refused silently when active; `duplicate` unguarded in the library | |
| Setup, cancel, retry | job view, library | `beginSetup`, `cancelJob`, completion handler | `jobs[id]?.isRunning`; completion cleared `jobs[id]` whatever job was there |

## The hypotheses of roadmap 0040, each reduced to an interleaving

| Hypothesis | Interleaving | Verdict | Evidence |
|---|---|---|---|
| Start called twice | two clicks | Not a bug | the guard held because `attach` runs before the first suspension |
| Start while a stop is pending | Shut Down, then Start | Not a bug | Start was refused as `virtualMachine` stayed set; the stop was invisible, now it is a state |
| Force stop, start again, first start fails late | Force Stop while starting; Start; first `start()` throws | **Real, high.** The catch called `tearDown()` for whatever run was current: it released the second run (stack, limit, disposable copy of a running machine) and left its machine running unseen | *test* `aStartAbandonedByAForceStopCannotTouchTheRunThatReplacedIt` |
| Force stop during a restore | Force Stop while restoring; restore fails | **Real, high.** The fallback booted a cold machine after the user had force stopped | *test* `aForceStopDuringARestoreThatFailsDoesNotBootTheMachineAnyway` |
| Restore finishes after a force stop | as above, restore succeeds | **Real, high.** The runtime limit was armed for a released machine, whose 30-second force stop would later hit the next run; the machine ran on unseen and its image was gone | *test* `aRestoreThatFinishesAfterAForceStopIsStoppedAndArmsNothing` |
| Pause, then stop | pause in flight; Force Stop; pause fails | **Real, low.** The failure was shown as an alert about a machine that was gone | *test* `aPauseThatFailsAfterAForceStopRaisesNoAlert...` |
| Suspend twice | double click on Suspend | **Real, high.** The second call failed and deleted the image the first had written; the machine stopped "suspended" with no image | *test* `suspendingTwiceKeepsTheImageTheFirstSuspendWrote` |
| Suspend during start or restore | Suspend while restoring | **Real, medium.** It failed with the framework's text and deleted the image being restored | *test* `suspendingWhileARestoreIsRunning...` |
| `canSuspend` flips | the flag was written at start and never cleared; a cold boot with an image it could not use left the image | **Real, medium.** A stale flag after stop; and an image that no longer matched the disk survived a cold boot and could be restored into a changed disk later | *tests* `suspendIsNotOfferedOnceTheMachineStops`, `aColdBootDoesNotLeaveAMemoryImage...` |
| Guest stop after a force stop and after the next start began | late `guestDidStop` | Mostly sound, one weak spot | the identity check held while the old object lived; an `ObjectIdentifier` can equal a later object's once the first is freed. Now a run number |
| Failed start after the network began | `start()` throws after `beginNetwork` | Not a bug on that path | `tearDown()` stopped the stack; the bug was the unguarded catch above |
| Failed restore | restore throws | Sound apart from the force stop case | fell back to a cold boot with a notice |
| Quit mid-suspend | quit while the image is written | **Real, low.** A partial image stayed on disk, and the controllers were told nothing: the network stacks and the disposable copies were left to the process ending | *test* `quittingMidSuspendRemovesThePartialImage...` |
| Startup sweep while a disposable machine runs | a second window runs the load task again | **Real, high for disposable machines.** `discardAllEphemeral()` deleted the copy a running machine used | *test* `loadingAgainDoesNotDiscardTheDisposableCopyOfARunningMachine` |
| Delete while stopping | confirm Delete during a stop | Refused silently (the machine was still active); now it says why | |
| Duplicate while running | menu disabled it; the library did not | **Real, medium.** An APFS clone of a disk the guest is writing | *test* `aRunningMachineCannotBeDuplicatedOrDeleted` |
| Setup: cancel then Resume Setup | Cancel; Resume Setup before the install unwinds | **Real, medium.** A second run on the same bundle; the old run's completion then removed the new job from the table | *test* `resumingASetupRightAfterCancellingWaitsForTheCancelledRunToUnwind` |
| Pause, Shut Down in the wrong state | Shut Down while paused; Pause twice | **Real.** The framework's error text reached the user | *tests* `pausingAMachineThatIsAlreadyPausedSaysSoInPlainWords...`, `aPausedMachineCannotBeAskedToShutDown...` |
| `--start` | launch argument | Sound; a machine that is mid-setup or unprovisioned is skipped without a word | not changed |

Not examined, because they need a guest: whether the framework calls `guestDidStop` after a successful `stop()`, whether
`canStop` is true while a machine starts, and whether the key-value observation fires.

## After: the states and the moves

States: `stopped`, `starting` (preparing, restoring, booting), `running`, `shuttingDown`, `pausing`, `paused`, `resuming`,
`suspending`, `stopping`. The machine is always in one; the controller is the only writer. Effects in *italics* wait for the
framework and report their outcome as the next event. Every other pair of state and event is refused (a request) or
ignored (a report) and changes nothing; the tests list 83 legal moves and check all 241 other pairs.

| Event | From → to, effects |
|---|---|
| start | stopped → starting(preparing), *prepare* |
| prepared | preparing → restoring (*restore*) when an image exists and can be used, else booting (discard image, *boot*) |
| boot succeeded | booting → running (record first boot, show notice, arm limit) |
| restore succeeded | restoring → running (arm limit) |
| restore failed | restoring → preparing (cold only): discard image, release the attempt, prepare again |
| start failed | starting → stopped: release, report |
| pause | running, shuttingDown → pausing, *pause* |
| pause succeeded, failed | pausing → paused; → running with the reason |
| resume | paused → resuming, *resume*; succeeded → running; failed → paused with the reason |
| shut down | running, shuttingDown → shuttingDown, ask the guest (again if asked again); if the framework refuses the request, back to running with the reason |
| runtime limit reached | running → shuttingDown, ask the guest; ignored otherwise (a paused guest cannot answer; the grace period still forces it) |
| force stop | any live state → stopping, *stop* (or the stop follows the call in flight); preparing or stopping → stopped, release |
| stop completed | stopping → stopped: release, report a failure |
| guest stopped, stopped with error | any active state → stopped: release (discard the image when suspending), report the error unless stopping |
| suspend | running, shuttingDown, paused → suspending, *pause if running, save, restrict, stop* |
| suspend succeeded, failed | → stopped: release; → paused or running with "Couldn't suspend: …", image removed |
| quit | any → stopped: release (discard the image when suspending) |
| a call finishes while stopping | the stop goes ahead (*stop*); a failed start or restore ends in stopped, release |

Refusals and their words: repeating what is under way is silent; "The machine is already paused."; "The machine isn't
paused."; "The machine isn't running."; "A paused machine can't be asked to shut down. Resume it first, or use Force
Stop."; "The machine is *starting/pausing/resuming/suspending/stopping*. Try again when it has finished."; and the
machine's own reason when its configuration cannot be saved.

## What the owner should check

Start, stop, force stop (also during a start and during a pause), guest shutdown (also a guest that ignores the power
button), pause and resume, suspend and restore, disposable discard, quit while running and quit while suspending, rapid
repeated clicks on every toolbar button. The questions a real guest answers: that the Paused layer and the "Pausing…" and
"Shutting down…" badges show; that Shut Down is greyed while paused; that a force stop during a start ends with the
window back on the settings form and the machine not running (look in Activity Monitor for a stray
`com.apple.Virtualization.VirtualMachine`); and whether a second window, opened from the Dock, leaves a running disposable
machine's disk alone.
