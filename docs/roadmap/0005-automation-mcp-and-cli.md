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

## Built so far: the control service (ADR-0056), 2026-10-23

- `ControlProtocol` (library): strict JSON-RPC 2.0, one request per line (batches refused, notifications neither run nor
  answered), the methods `machines.list`, `machines.state`, `machines.start` and `machines.stop`, capability tokens (256
  random bits shown once, stored as SHA-256 digests in a 0600 file, compared in constant time, revocable), the checks in
  order (token, capability, the token's machines, the machine's agent access), the connection (the peer's user checked
  with `getpeereid` before anything is read; 64 KiB per request, 10 s to send one, 120 s to answer, 64 per connection), the
  listener (the console's private-socket code, at most 4 clients) and a minimal client that the tests drive end to end
  over a socket pair and over a socket under `/tmp`.
- The app: a Settings switch for the service, off by default, with its help; the managed key `AllowControlService`, which
  keeps it and every machine's agent access off; a per-machine `agentAccess` switch, off by default, forced off by the
  Isolated and Hardened profiles, with its line in the exposure summary and its help; the token list in Settings (make,
  show once, revoke) with its help; the socket and the token file in `Control/` of the data folder (0700); every refusal
  of a token, a capability or a machine's access logged without the token. Start, suspend and stop in the library can now
  be awaited and say what came of them, and the menus use the same path.
- Not yet verified: the service in the running app, a real client, and a real machine started through it. The owner's run
  is the next step; ADR-0056 stays proposed until then.

## Remaining

1. The owner's run of the control service in the app (Settings switch, a token, `machines.list`, a start and a stop
   through it, the log of refusals), then accepting ADR-0056 or changing it.
2. A command-line client of the control service in the tooling, on the library's client.
3. The MCP server over stdio on top of it, with `exec` using `ConsoleSession`.
4. Screenshots (window capture), then keyboard and mouse input, each behind its capability.
5. Choosing a token's machines in Settings (the store and the checks already support it), and token expiry.
6. Opening the console in the user's terminal application: an app-wide preferred application with a per-machine
   override. It needs the console client inside the app's bundle first.
7. A guest agent over vsock for `exec` without a getty, and for macOS guests.
8. The App Sandbox helper cannot bind the console socket outside its container (tried, see the sandboxing study); decide
   whether a socket inside the container is worth supporting.
9. Recording.
