---
status: accepted
date: 2026-10-22
---
# 0053 — The helper hosts the filtered network and takes policy changes on a private pipe

## Context

The user-mode network and its policy are library targets (ADR-0047), so the headless helper can run the stack the app runs.
A guest driven through a console (ADR-0052) is the way to test that stack against a real guest, which roadmap 0030 asks for
and which no unit test replaces: the first real run found a defect no test had (an echo reply delivered once per recent
ping), and showed that the stack never evaluates URL rules. A real run needs three things the helper lacked: the network
itself, a way to change the policy while the guest runs, and a way to read what the stack did.

## Decision

1. **The helper builds the same stack, from the same policy.** A descriptor with `network: filtered` names a policy file
   (the JSON the app stores for a `NetworkPolicy`, or none for the default policy) and a deny action (`reset` or `drop`).
   The helper reads the file, makes the stack with the library's own factory and attaches its socket pair to a virtio card.
   The few lines that attach it are the app's own with the framework's name for them; nothing about the policy, the floor or
   the stack's configuration is reimplemented, and nothing in the helper can lift the floor.
2. **What the stack does is reported as events** in the helper's line-delimited JSON: one `flow` event per step of a
   connection or lookup, worded by the library (`FlowEvent.eventLine`) so the helper and the app's log say the same thing;
   a `vpn` event when the guest-VPN verdict changes; and `statistics` events with the stack's counters, every five seconds
   while they change and once more when the machine ends.
3. **The policy changes through a named pipe, not a network port.** With `--commands` the helper reads command lines from
   standard input; `vmr guest start` makes the input a named pipe (mode 0600, in the run directory, which is 0700) that the
   helper holds open for reading and writing. `policy [keep|terminate]` reads the descriptor's policy file again and applies
   it, cutting the open flows the new policy no longer allows unless `keep` is given; `statistics` reports the counters.
   Every command is answered by an event, and a line that is not a command is answered as a rejection. `vmr guest policy`
   replaces the policy file, writes the command and waits for the answer.
4. **Only the standard sandbox level may host the stack,** because the stack opens host sockets and resolves names; the
   strict level and the App Sandbox helper's missing network entitlement are unchanged (ADR-0016). The policy file is a
   path the helper only reads. A guest booted from a kernel and a ramdisk ran under the generated Seatbelt profile at the
   standard level with the stack hosted: DHCP, DNS, TCP and ping worked and its flow events were reported.

## Consequences

A guest on the filtered network can be started, driven through its console, given a new policy and read back, from a
terminal and with no window. The roadmap 0030 rows that a terminal can drive were run this way (see
`docs/research/filtered-network-on-a-real-guest-2026-10.md`).

The helper's log grows with the guest's connections; it is a log of a test run, bounded by the run-time limit, not a store.
The five-second counters lag a command by up to five seconds; a `statistics` command is exact.

URL prefix rules are stored and validated but the stack never evaluates them, so the help must not promise them (found by
the real run; fixed in the help, not in the stack).

## What this does not decide

Enforcing URL rules, which needs the stack to read HTTP and so a proxy of some kind. A control channel for the console and
the machine's state (roadmap 0005). Live policy changes under the Seatbelt engine (the run there had no command pipe), and
the App Sandbox engine. Rows of roadmap 0030
that need a window or the Mac's own network changes: suspend and resume, display, snapshots, a VPN on the Mac, a change of
network path.
