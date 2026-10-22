---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0052
---
# 0005 — A local control surface for AI agents and scripts

Study: `docs/research/automation-2026-10.md`. A local socket plus MCP over stdio, per-client capability tokens, screenshots through
ScreenCaptureKit window capture, recording, and a serial or vsock terminal, each isolated from the host.

## Done when

An agent can start a machine, read its state, take a screenshot and type into the guest through a token that grants only
those capabilities, with tests for the capability checks.

## Built so far: the console (ADR-0052)

- `GuestConsole` (library): `ConsoleBridge` serves a guest's serial port on a private local socket (one client, a replay
  of the last 64 KiB, output dropped rather than holding the guest back), and `ConsoleSession` waits for a prompt, logs
  in and runs a command between markers, returning its output and exit status.
- The headless helper takes `console.socket` in its descriptor and reports `consoleReady`; a kernel boot with an initrd
  needs no disk.
- `vmr guest fetch | start | exec | console | stop`: the owner-authorised real-guest runs of `CONTRIBUTING.md`, on a signed
  Alpine netboot image in a scratch directory. Measured results are in the study's "Built" section.
- The app: a per-machine `serialConsole` switch for Linux guests (off by default, forced off by Isolated and Hardened),
  its line in the exposure summary, an editor toggle and a help topic.
- The Alpine ISO of the app's catalog boots with `console=ttyAMA0`, so its console stays silent until the guest boots with
  `console=hvc0`, as an authorised real-guest run found on 2026-10-22; the help topic, ADR-0052 and the study say how.

## Remaining

1. The control service in the app: JSON-RPC over a local socket, peer-credential check, per-client capability tokens, and
   the per-machine agent policy; list, state, start and stop first.
2. The MCP server over stdio on top of it, with `exec` using `ConsoleSession`.
3. Screenshots (window capture), then keyboard and mouse input, each behind its capability.
4. Opening the console in the user's terminal application: an app-wide preferred application with a per-machine
   override. It needs the console client inside the app's bundle first.
5. A guest agent over vsock for `exec` without a getty, and for macOS guests.
6. The App Sandbox helper cannot bind the console socket outside its container (tried, see the sandboxing study); decide
   whether a socket inside the container is worth supporting.
7. Recording.
