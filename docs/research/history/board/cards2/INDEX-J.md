# INDEX-J — Chain J: the local control service, first step (roadmap 0005 "Remaining" item 1; ADR-0052 → new ADR-0056)

Base: `main` at `a9ae6d0`. Every anchor of every card was read on that commit with `grep -nF`; a later card anchors on text
the earlier cards of this chain leave as the card says. Locate by text, never by line number.

Files: COMMON.md (in `../cards/`), this index, J01.md to J12.md (one card each, one commit each).

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/j-control -b chain/j-control a9ae6d0
```
`WT = ~/Developer/g-cqd/VMRunner-chains/j-control`, branch `chain/j-control`. One chain, cards strictly
in order, **one build at a time** (the gate takes 3 to 10 minutes). Every card leaves the branch green with
`swift run vmr check` (8/8 PASS). haiku (effort low) executes each card; sonnet (effort medium) reviews every card before
dispatch and the whole chain before merge; opus merges after the gate on the merged tree.

## How to read the code blocks of a card

Most blocks start at the left margin. A fenced block nested in a list item is indented by the list's indentation: remove
exactly the indentation of the block's opening fence from every line of the block. An `old` text is the file as the
previous cards left it after `swift-format`. "Insert after X" means a new line directly below the line(s) X, X unchanged.

## Rules for chain J (they override COMMON where they differ)

Standing owner rules, every card:
- **No outside project named** in prose, docs, comments or commit messages (say "the shared utility library", "another
  virtualization app"); no distribution plans; no board or card ids (`J04`, `X17`...) anywhere in the repository.
- **Every commit atomic, signed (`-S`), builds, and `swift run vmr check` is 8/8 PASS before it.** No push, amend or rebase.
- macOS 15 is the API floor the owner states (Package.swift declares macOS 26; the cards use nothing newer than macOS 15:
  `Mutex`, CryptoKit, `Thread`, `AsyncStream`). Swift 6.4, strict memory safety: every unsafe call is marked `unsafe` on the
  expression; warnings are errors; SwiftLint is strict (its warnings fail): `type_body_length` 300, `function_body_length`
  60, `cyclomatic_complexity` 12, `function_parameter_count` 6, lines under 140 columns. Swift Testing only.
- **Agents never start a virtual machine and never open the app's real data directory** (`~/Library/Application
  Support/VMRunner`, the app's preferences). Tests use a scratch directory; socket tests use a short private (0700) folder
  under `/tmp` that the test removes (a socket path holds at most 103 bytes, the usual temporary folder is too long).
- **Compile errors in a card's code**: the orchestrator could not build. Fix a compile, format or lint error *minimally*
  without changing behaviour or what a test checks (a missing `try`/`await`/`unsafe`, `public import`, an explicit type, a
  `self.`, a renamed local, a line wrapped under 140 columns) and list every such fix in the report with the compiler line. A
  fix that would change behaviour, an API named in a later card, or a test's expectation: STOP and report (COMMON "Stop rule").
- Diary: the next free number for 2026-10-23 at the time of J12 (`ls docs/diary | grep 2026-10-23`; none existed at
  `a9ae6d0`, so `2026-10-23-01.md` unless another merge took it). ADR: 0056 (0055 is held by another chain; check
  `ls docs/adr | grep -E '^005[5-9]'` in J01 and stop if 0056 exists).

Never-touch list: COMMON's list holds, with these exceptions, only for the files and lines each card names:
- `Package.swift` (J02: two targets; J10: the app's and its tests' dependencies);
- `.vmr.json` (J02: one coverage bundle added; nothing else);
- `Sources/GuestConsole/ConsoleSocket.swift` (J05: access keywords only, `package` and `Sendable`, no behaviour);
- `Sources/VMRunner/Model/Security.swift` (J07: the `agentAccess` lines only);
- `Tests/DevToolsTests/ModuleBoundaryTests.swift` (J02), `Tests/DevToolsTests/DependencyPolicyTests.swift` (J10).

## Order, dependencies and files

| Card | What | Needs | Files (new = N) | Size | Risk |
|---|---|---|---|---|---|
| J01 | ADR-0056 (proposed): the design of this chain | — | `docs/adr/0056-...md` (N) | ~90 doc | low |
| J02 | `ControlProtocol` library target: JSON-RPC 2.0 parse/encode (strict, batch refused), `LineBuffer`, `ControlLimits`; layering test; coverage bundle | J01 | `Package.swift`, `.vmr.json`, `Sources/ControlProtocol/JSONRPC.swift` (N), `LineBuffer.swift` (N), `ControlLimits.swift` (N), `Tests/ControlProtocolTests/JSONRPCTests.swift` (N), `LineBufferTests.swift` (N), `Tests/DevToolsTests/ModuleBoundaryTests.swift` | ~420 | medium |
| J03 | Capabilities, 256-bit secrets, SHA-256 digests, constant-time compare, the token store (0600 file, revoke, limits) | J02 | `Sources/ControlProtocol/ControlToken.swift` (N), `ControlTokenStore.swift` (N), `Tests/ControlProtocolTests/TestSupport.swift` (N), `ControlTokenTests.swift` (N) | ~330 | low |
| J04 | Dispatcher: method names, params, token → capability → machine scope → agent access; denials reported without the token; the `ControlMachines` protocol | J03 | `Sources/ControlProtocol/ControlMachines.swift` (N), `ControlDispatcher.swift` (N), `Tests/ControlProtocolTests/FakeMachines.swift` (N), `ControlDispatcherTests.swift` (N) | ~430 | medium |
| J05 | Connection over a descriptor: peer uid check (injected), bounded reads, per-request deadline, answers; the client; `ConsoleSocket` made `package` | J04 | `Sources/GuestConsole/ConsoleSocket.swift`, `Sources/ControlProtocol/LineIO.swift` (N), `ControlConnection.swift` (N), `ControlClient.swift` (N), `Tests/ControlProtocolTests/ControlConnectionTests.swift` (N) | ~470 | **high** |
| J06 | Listener: private socket via the console's rules, accept loop on a thread, connection limiter, stop | J05 | `Sources/ControlProtocol/ControlListener.swift` (N), `Tests/ControlProtocolTests/ControlListenerTests.swift` (N) | ~230 | **high** |
| J07 | Per-machine `agentAccess`: config, profiles, posture, exposure, editor section, help topic, tests | J01 | `VMConfig.swift`, `Security.swift`, `SmallSections.swift`, `ConfigEditor.swift`, `HelpTopic.swift`, `Help/HelpContent+Automation.swift` (N), `Tests/VMRunnerTests/AgentAccessTests.swift` (N), `ModelTests.swift` | ~230 | low |
| J08 | App-wide switch `runsControlService` (Settings), managed key `AllowControlService` (locks, clamps agent access), help, ADR-0013 and roadmap 0013 notes | J07 | `PreferencesDomain.swift`, `ManagedPreferences.swift`, `SettingsView.swift`, `SmallSections.swift`, `HelpTopic.swift`, `HelpContent+Automation.swift`, `HelpContent+AppSnapshots.swift`, `PreferencesDomainTests.swift`, `ManagedPreferencesTests.swift`, ADR-0013, roadmap 0013 | ~170 | low |
| J09 | Awaitable `startAndWait` / `suspendAndWait` returning a result; `startMachine` / `suspendMachine` use them | — | `Sources/VMRunner/Model/VMLibrary.swift`, `VMLibrary+Commands.swift` (N), `Tests/VMRunnerTests/LibraryCommandTests.swift` (N) | ~200 | medium |
| J10 | The app's service: `stopAndWait`, the adapter, `ControlService` (socket in `Control/`, store, log), wiring at launch/quit/Settings | J06, J08, J09 | `Package.swift`, `DependencyPolicyTests.swift`, `Storage.swift`, `Log.swift`, `VMLibrary+Commands.swift`, `Model/LibraryControlMachines.swift` (N), `Engine/ControlService.swift` (N), `VMRunnerApp.swift`, `SettingsView.swift`, `Tests/VMRunnerTests/ControlServiceTests.swift` (N) | ~420 | **high** |
| J11 | Token management in Settings (create, show once, list, revoke), help topic, model tests | J10 | `ViewModels/ControlTokensModel.swift` (N), `Views/Settings/ControlTokensSection.swift` (N), `SettingsView.swift`, `HelpTopic.swift`, `HelpContent+Automation.swift`, `Tests/VMRunnerTests/ControlTokensModelTests.swift` (N) | ~230 | low |
| J12 | Docs: roadmap 0005 (dated "Built so far", trimmed "Remaining"), ADR-0056 note, study note, diary | J01-J11 | `docs/roadmap/0005-...md`, `docs/adr/0056-...md`, `docs/research/automation-2026-10.md`, `docs/diary/2026-10-23-NN.md` (N) | ~110 doc | low |

Dispatch order: J01 → J12 in number order. J07, J08 and J09 do not use the library and could run before J02 if the library
cards are held; J10 needs all of J02 to J09. Sizes over 300 lines are mostly tests and code given verbatim (J02, J04, J05,
J10): each new library type has no production caller until a later card, so its API is `public` (a root for the dead-code
gate, as in `GuestConsole`), and the app cards each wire a production use in the same commit.

## Owner decisions (each card implements the default; ADR-0056 records them)

1. **ADR-0056 status: `proposed`** until the owner's run below. The chain never marks it accepted.
2. **Framing: one JSON-RPC request per line (newline-delimited UTF-8 JSON).** Alternative: `Content-Length` headers.
3. **The token travels in every request** (`params.token`), checked per request, so a revocation applies to the next request
   on an open connection. Alternative: a first `session.authenticate` call per connection.
4. **Notifications (no `id`) are neither run nor answered.** Alternative: run them silently.
5. **`machines.stop` asks the guest to shut down and answers at once (`shuttingDown`); `"force": true` cuts the power and
   answers once stopped.** `machines.start` answers once the machine runs or the start failed.
6. **Limits:** 64 KiB per request, 4 concurrent connections (the next is closed at once, no message), 64 requests per
   connection, 10 s to send a whole request, 2 s for a client that stops reading, 120 s to answer (then -32005 "timed out";
   the start goes on), 32 tokens, names of 64 characters.
7. **Socket and tokens live in `<data dir>/Control/`** (`control.sock`, `tokens.json`); a path too long for a local socket
   (an unusual data dir) makes the service refuse to start and Settings says why; no fallback to a temporary folder.
8. **An agent's start never prompts:** unapproved host paths refuse it (like `--start`).
9. **Exposure line level `.low`**: "Agent access: a script or AI agent with a control token can see this machine and start
   or stop it while the control service is on in Settings."
10. **Managed key `AllowControlService`** (anything but `true` keeps the service off, turns agent access off on every machine
    and locks both controls); **app setting `runsControlService`** (forced like the other app settings: its value locks).
11. **Token machine scope**: the store and the checks support it; Settings does not offer it in this chain.
12. **Library layout (orchestrator's call, deviating from "thin socket server in the app")**: the listener lives in the
    library next to the connection so both are tested end to end without the app; the app keeps a thin `ControlService`
    (placement, switch, adapter, log). `ControlProtocol` links `GuestConsole` for the socket calls (`ConsoleSocket` becomes
    `package`); a neutral rename of `ConsoleSocket` (ADR-0042) is a follow-up. API `public` (dead-code roots), not `package`.
13. **Coverage:** `ControlProtocolTests` joins `coverage.testBundles` in `.vmr.json` (J02). Say no and J02 drops that edit.

## Owner-run list (never dispatched to an agent: it opens the real app and starts a real machine)

After the merge, in a built app (`swift run vmr build-app`), run against a scratch data directory as CONTRIBUTING requires
for real runs (never the owner's own library), with one Linux machine set up in it:
`mkdir -m 700 /tmp/vmr-owner && VMRUNNER_DATA_DIR=/tmp/vmr-owner build/VMRunner.app/Contents/MacOS/VMRunner` (its settings
then live in a domain of their own; the socket is `/tmp/vmr-owner/Control/control.sock`).
1. Settings → Automation: turn on "Let scripts and AI agents control machines". Settings shows "Listening at <path>".
   `ls -ld /tmp/vmr-owner/Control` shows `drwx------`; `ls -l` of `control.sock` shows `srw-------`; `tokens.json` (after
   step 2) `-rw-------` and holds no `vmrc_` text (`grep -c vmrc_ tokens.json` prints 0).
2. Settings → Control tokens: create "owner-test" with List machines and Read state only; copy the token shown once; close
   and reopen Settings: the token is listed, its secret is not shown.
3. `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"machines.list","params":{"token":"<token>"}}' | nc -U "<socket>"`:
   an empty `machines` list while no machine allows agent access. Turn on the machine's "Allow agent access" (editor,
   Automation): the list shows it with `"state":"stopped"`. The machine's "What this machine can reach" shows the line.
4. `machines.start` with that token: error -32001. Create a token with Start and Stop; `machines.start` (owner-authorised
   real-guest start): the answer comes when the machine runs, `"state":"running"`; `machines.stop` with `"force":true`.
5. `log show --last 10m --predicate 'category == "control"'`: each refusal is there, with no `vmrc_` text.
6. Revoke the token; the next call with it: -32001. Turn the switch off: the socket file is gone within a second, and a client
   that was already connected gets no answer to its next request (its connection closes).
7. Optional, with a configuration profile forcing `AllowControlService` false: the switch and the machine's agent access
   are locked and off. Optional: `sudo -u nobody nc -U <socket>` is refused (the folder is 0700).
8. Quit the app while the service runs; the socket is removed, or the next start removes the stale one. Afterwards remove
   `/tmp/vmr-owner` and anything else the run created.
Record the run in roadmap 0005 and, if the owner accepts it, set ADR-0056 to `accepted`.

## What a sonnet pre-dispatch review should read hardest

J05 (threads, deadline, socket package access, the end-to-end tests' timing), J06 (accept-loop lifetime, stop/remove, the
limit test), J10 (MainActor adapter over a Sendable protocol, start/stop wiring, the too-long-path test, Package.swift and
the dependency-policy test), and J04 (whether every check is ordered so a refusal never leaks a machine's existence beyond
what decision 5 accepts, and that a denial can never hold a token).

## Next chain (not carded here)

`vmr control` (a command-line client in the tooling, over `ControlClient`), then the MCP server over stdio with `exec` through
`ConsoleSession`; then screenshots and input behind their capabilities (roadmap 0005).

Follow-ups found in the pre-dispatch reviews, deliberately not in this chain: `ControlClient` starts a fresh line buffer per
`receive()`, so a pipelining client would lose a second answer in the same read (make it keep its buffer before the
command-line client uses it); `ControlListener` takes `limits` separately from its connection's (one source would avoid a
mismatch); refusals for malformed params, unknown methods, timeouts and the library's own refusals are answered but not
logged (decide whether they should be). A client that reads one byte every two seconds can hold one of the four
places while a large answer drains (the 2 s stall bound applies to each write, not to the whole answer); a bound on the whole
answer would close that, and `ControlClient` trusts the service's answers (its parser has no nesting bound).
