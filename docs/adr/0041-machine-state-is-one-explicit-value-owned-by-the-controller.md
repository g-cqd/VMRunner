---
status: accepted
date: 2026-10-22
---
# 0041 — A machine's state is one explicit value, owned by its controller, and late reports are ignored by run

## Context

The state of one machine lived in six places: the controller's virtual machine reference (`nil` or not), a copy of the
framework's own state kept by a key-value observation that hopped to the main actor, a suspend flag nothing reset, the
runtime limit's timer, the network stack, and the library's job table; the view model's phase was derived from some of
them and the toolbar from others. No type said which transition is legal, so an action in the wrong state reached the
framework, which answered with its own error text, and a report that arrived late (the guest stopped, a call finished, the
timer fired) was matched against the machine by object identity at best.

The owner saw it: Pause did nothing visible and the button stayed "Pause", Shut Down seemed to do nothing, and a second
Pause raised an invalid-transition alert. The audit (`docs/research/machine-states-2026-10.md`) found the cause in the
design, not in one line. The framework documents no key-value observation of `VZVirtualMachine.state`, so a user interface
that waits for it can wait forever; the controller dropped its reference to a machine it could not stop; and several
sequences (a force stop during a start, a double click on Suspend, a restore that fails after a force stop) left a machine
running, an image deleted, or a run torn down by the report of the run before it.

## Decision

1. **One value.** `MachineState` (stopped, starting with its phase, running, shutting down, pausing, paused, resuming,
   suspending, stopping) is the whole state of a machine's run. The interface reads it and nothing else decides what is
   offered: a button is enabled by the table, a step in progress is named, and a paused machine is dimmed and labelled over
   the display.
2. **One pure function.** `MachineState.transition(on:)` maps a state and an event to the next state and the effects to
   perform, or to a refusal (a request this state does not allow, with a reason in plain words, or none when it only repeats
   what is under way) or an ignore (a late report nobody waits for). It touches no framework, file, clock or task, and the
   tests run every state against every event.
3. **The controller owns it.** `VMController` is the only writer of the state. It applies an event, performs the effects, and
   feeds the outcome of each framework call back as the next event; it never copies the framework's state. The framework
   sits behind `GuestMachine` and `MachineFactory`, so the controller runs against a fake in tests.
4. **Every report carries its run.** Releasing a machine ends its run and bumps a number; the guest's reports, the runtime
   limit and every framework call carry the number they began with and are dropped when it is old. What a late completion
   brought up after its run ended is stopped.
5. **One way out.** Every way a run ends (the guest stops, an error, a force stop, a failed start, a suspend, quitting)
   goes through the one `release` effect: the network stack is stopped, the runtime limit cancelled, the disposable copy
   discarded, suspend support cleared, the latency activity ended and the machine let go, which detaches it from the view.
6. **A force stop never drops a machine it could not stop.** When the framework cannot stop a machine that is starting,
   pausing or saving, the state becomes stopping and the stop follows the call in flight. Asked twice, the force stop gives
   up waiting and releases the machine; the late completion is stale.

## Consequences

An illegal action is refused before it reaches the framework, with a message a person can read, and a repeated click is
silent. The user interface no longer depends on any framework announcement, so what it shows is what the controller did.
A start, a restore, a pause or a suspend that is still in flight when the user force stops can no longer finish into the
next run. The cost is one more state ("shutting down") that the interface shows for a request the guest may never answer,
and a Force Stop during a start that waits for the start (or for a second request) instead of dropping the machine.

## What this does not decide

The framework's behaviour in the transitional states is not verified without a guest: whether `canStop` is true while a
machine starts is unknown, and the design works either way. The saved memory image is still written in place, so a crash
(not a quit) in the middle of a suspend can leave a partial image that a later restore rejects and falls back from; writing
it under a temporary name and renaming it is a separate change. The setup job's states (running, failed, unwinding) stay in
the library's job table; only their overlap with a new job is fixed here.
