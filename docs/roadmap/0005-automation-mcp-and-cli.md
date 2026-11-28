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

## Built so far: the command-line client and the MCP server, 2026-10-23

- The library's client keeps one buffer for its answers, so several requests can be sent before the first answer is read,
  and refuses an answer nested more than 8 levels deep or longer than 1 MiB unparsed. A caller makes one call per
  connection with its token, and first checks with `getpeereid` that the process serving the socket runs as the same
  user, so a token is never sent to another user's socket.
- `vmr control status | list | state | start | stop` in the tooling: the socket from `--socket`, otherwise
  `Control/control.sock` in the data folder (`VMRUNNER_DATA_DIR` when it is set); the token from `--token-file`, a file
  of the user's that no one else may read or write, or from `VMR_CONTROL_TOKEN`, never from an argument, which `ps` shows
  to every user; a machine named by its id or its name; human output or `--json`; exit statuses documented in
  `vmr control --help` and CONTRIBUTING.
- `AgentBridge` (library) and `vmr control mcp`: an MCP server over stdio (protocol 2025-11-25, and 2025-06-18) with four
  tools, `machines_list`, `machines_state`, `machines_start` and `machines_stop`, each one call of the control service
  with the token. A tool result is the service's JSON as text; a refusal is a tool error that names the control error
  code. Messages are read strictly: one JSON-RPC 2.0 object per line, no batch, no null id, at most 1 MiB and 16 levels
  deep. The app does not link it. The protocol itself is AemiMCP's `MCPSyncServer`, configured this strictly (ADR-0056,
  update 2026-11-28).
- Tested end to end against the library's own service on sockets under `/tmp`, with machines held in memory: the real
  `vmr` binary for each subcommand, and an MCP session piped into `vmr control mcp`. Not yet run against the app or with
  an MCP client application.

## Built so far: the console client filters the guest's output, 2026-10-24

- `ConsoleOutputFilter` (in `GuestConsole`): a streaming filter for what a guest prints, its state kept between reads and
  bounded (a CSI sequence of at most 256 bytes, a control string given up after 4 KiB, then text again). It passes text,
  well-formed UTF-8, line feed, carriage return, tab, backspace and the bell, and the CSI sequences a boot log, a login
  prompt and a shell's line editing use: colours and attributes, cursor movement, erasing in the line or the display (not
  the scrollback), inserting, deleting and erasing characters. It removes, whole, window titles, the clipboard,
  hyperlinks, every query that makes the terminal answer, every mode change, resets, C1 controls in both forms and every
  other sequence or control string.
- `vmr guest console` filters by default; `--raw` passes the guest's output unchanged after a warning on standard error.
  The filter is on the client's relay only: the bridge and `ConsoleSession` still see the raw bytes, which the exec
  markers and the prompt detection need.
- The client puts the terminal back however the session ends: its settings after a detach, the end of input, an error,
  or SIGHUP, SIGINT, SIGQUIT, SIGPIPE or SIGTERM (received through dispatch sources, so no code runs in signal context;
  exit status 128 plus the signal); a colour reset after a filtered session, and after a raw one the modes a guest's
  programs most often leave on. A crash of the client itself is not covered: `stty sane` restores the terminal.
- Tested with a table of 127 rows (each also cut at every byte), random input, a hand-written boot and login log,
  the relay on socket pairs, raw mode on a pseudo-terminal pair and a signal sent to the test process. Not yet tried in a
  terminal application, nor against a real guest. A guest can still redraw the visible screen: cursor movement and
  erasing pass, so what the screen shows is not proof of what ran. The filter assumes a terminal that reads UTF-8 (C1
  controls are removed in both forms only there).

## Remaining

1. The owner's run of the control service in the app (Settings switch, a token, `vmr control status` and `list`, a start
   and a stop through `vmr control` and through an MCP client, the log of refusals), then accepting ADR-0056 or changing
   it.
2. `exec` through `ConsoleSession` as a control method and an MCP tool, behind a capability of its own.
3. Screenshots (window capture), then keyboard and mouse input, each behind its capability.
4. Choosing a token's machines in Settings (the store and the checks already support it), and token expiry.
5. Opening the console in the user's terminal application: an app-wide preferred application with a per-machine
   override. It needs the console client inside the app's bundle first, and that client must use the console output
   filter by default.
6. A guest agent over vsock for `exec` without a getty, and for macOS guests.
7. The App Sandbox helper cannot bind the console socket outside its container (tried, see the sandboxing study); decide
   whether a socket inside the container is worth supporting.
8. Recording.
9. `package` access for `ControlProtocol` and `AgentBridge` now that the tooling links them (CONTRIBUTING, "Code rules").
10. Window size: the console's guest side never learns the size of the person's terminal, and a serial port has no way to
   carry it. Forwarding it waits for the guest agent over vsock.
11. A screen model of the console (the text a full-screen program shows) for a read-screen tool and for waiting on text,
   built on the parser of the console's output filter rather than a second one. A later piece of work.
