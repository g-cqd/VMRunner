# REVIEWED-J — pre-dispatch review of chain J (local control service), cards J01 to J12

Reviewed on `main` at `a9ae6d0` in a scratch worktree (removed afterwards). Method: every card applied in order exactly as
written (code, tests, the `ConsoleSocket` keyword table, Package.swift, .vmr.json, docs), built and tested per card, then
`swift run vmr check` on the whole tree: 8/8 PASS, run twice (before and after the edits below). The socket suites were run
20 times each plus 15 runs of the three suites together under ten busy loops: 0 failures out of 95 runs. Security properties
were attacked with probe tests written in the scratch copy only (not part of any card). No machine was started, no real data
directory or ~/Library path was opened, nothing listened outside a /tmp unix socket.

## Verdicts

| Card | Verdict | Edits to the card |
|---|---|---|
| J01 | ready | 0 |
| J02 | ready after the edits listed | 3 (a crash found: nesting bound) |
| J03 | ready | 0 |
| J04 | ready after the edits listed | 3 |
| J05 | ready after the edits listed | 9 (3 lint, 6 for "turning the service off cuts connections off") |
| J06 | ready after the edits listed | 5 |
| J07 | ready | 0 |
| J08 | ready | 0 |
| J09 | ready | 0 |
| J10 | ready after the edits listed | 1 |
| J11 | ready | 0 |
| J12 | ready after the edits listed | 4 |
| INDEX-J | edited | 2 |

Total: 27 edits (25 in cards J02, J04, J05, J06, J10, J12; 2 in INDEX-J). Anchors: every anchor of every card matched
`a9ae6d0` (the 12 `ConsoleSocket` replacements, all `Package.swift`, `.vmr.json`, `HelpTopic`, `Security`, `SettingsView`,
`VMRunnerApp`, `Storage`, `Log`, roadmap and ADR anchors). Formatting by `swift-format` changed nothing that mattered.

## Defects found and the edits made

### Crash found by attack (J02, high)

A same-user client with no token could kill the whole app with a 3 KB line: `{"a":` repeated 500 times and closed. The
system JSON parser recurses with the nesting and overflows the 512 KB stack of a Swift concurrency worker thread (where the
connection parses) well below its own depth limit of 512. The peer check does not help (same user) and the parse runs before
any token check. Reproduced end to end through `ControlConnection.serve`: the test process died. Depth 400 passed, 500 died;
arrays were caught by the parser's own limit, objects were not.

J02 edits (3): `RPCMessage.parse` first refuses any line whose nesting of `{` and `[` outside strings exceeds 8
(`deepestNesting`; a request needs 2) with Invalid Request, without parsing; new `static func nesting(of:)`; two new tests
(`linesNestedTooDeeplyAreRefusedWithoutBeingParsed` for objects and arrays at depths 9, 100, 600, 20 000 and an unfinished
line; `bracketsInsideStringsDoNotCountAsNesting`). After the edit the same probe answers -32600 and the process lives.
`ControlClient.receive` still parses the service's answers without such a bound (the service is trusted there); listed as a
follow-up in INDEX-J.

### Turning the service off left open connections working (J05 and J06, medium)

`ControlListener.stop()` closed the listening socket but a connection already open kept being served: up to 64 requests,
each with up to 10 s of idle allowance, so a client keeping a connection alive kept full control after the user switched the
service off (or the organisation denied it). Confirmed by a probe: after `stop()` and
`waitUntilStopped()` the socket file was gone and the open connection still answered `machines.list`.

J05 edits (6 of its 9): `ControlConnection.serve(_:while:)` takes an `isOpen` closure (default always open), asked once a
request has been read; when it says no the connection closes without answering or running it; the test `Rig` takes `isOpen`
and passes it; new test `aConnectionTheListenerHasClosedGetsNoAnswerAndItsRequestIsNotRun` (a `machines.start` that must not
reach the machines); the Test paragraph names it. J06 edits: the accept loop passes `{ !flag.isSet }`; `stop()` doc says what
now happens; new test `aClientConnectedWhenTheListenerStopsGetsNoMoreAnswers`. Both new tests were mutation-checked (they fail
with the old behaviour). A request already running when `stop()` is called still completes and is answered; the in-flight
start cannot be recalled (same as the 120 s timeout rule).

### A stated bound with no test (J06)

"A client that stops reading is dropped after 2 s" had no test (the J05 tests use blocking socket pairs, on which a write
simply blocks; only accepted sockets are non-blocking and use the stall wait). J06 edit: `Rig.connection` takes a
`machineCount`; new test `aClientThatStopsReadingIsDroppedRatherThanWaitedFor` (600 machines, so the answer exceeds the socket
buffers; one bounded real wait of 0.5 s on a thread of its own, then it expects the server to have closed the connection).
Mutation-checked: with a 60 s stall it fails. J06's 5 edits: the serve call, the `stop()` doc, `Rig.connection`, the two new
tests, the Test paragraph.

### Lint and compile errors (the orchestrator could not build)

- J04: `FakeMachines.swift` did not compile (`no macro named '_sourceLocation'`): added `import Testing` (the card's stop
  condition pre-authorised it; the card now has it in the code and the stop-condition text says so). `ControlCall.read`
  returned `Result<ControlCall, RPCError>`: SwiftLint `prefer_self_in_static_references` fails the gate; now `Result<Self, RPCError>`.
  (3 edits.)
- J05: two `ControlClient` signatures (`connect(to:)`, `connectedPair()`) hit the same rule: `-> Self`, `(client: Self, ...)`.
  `withDeadline(..., sleep: {...}) { 42 }` in a test hit `multiple_closures_with_trailing_closure`: the operation is now passed
  in parentheses. (3 of the 9 edits.)
- J10: `ControlService.swift` needs `import os` (member import visibility: `privacy:` and `Logger` methods not found). 1 edit.
- J12: one over-long line wrapped; the diary's row 5 said "closed, closed, -32005" although an oversize request is answered
  -32600 and then closed (reworded, and now names the dropped non-reader); a new row for the nesting bound and the
  cut-off connection (so the existing "NOT RUN" row becomes 9); the Cleanup paragraph's second sentence ("the chain's worktree
  and branch are removed by the integrator") names the workflow and was dropped. 4 edits. The card's own grep (step 4) still
  prints nothing.
- INDEX-J (2): owner-run step 6 now also checks that an already connected client gets no answer after the switch is turned
  off; two further follow-ups added (the write stall bound applies to each write, not to the whole answer, so a reader that
  drains one byte every 2 s can hold one of the four places while a large answer goes out; `ControlClient` parses with no
  nesting bound).

## Per card

- **J01 (ADR).** Applies, docs gate passes. Text consistent with the cards. After the J02/J05/J06 edits decisions 5 and 6
  remain true as written (the nesting bound and the cut-off are consequences, not new decisions); the ADR could say "a client
  connected when the service is turned off is closed at its next request" in a later amendment.
- **J02.** Compiles; 12 then 14 tests; strict reading verified (batch, notification, ids, params, extra members, answer on one
  line even for an id with newline, U+2028 and CR). Probes: 99999999999999999999 and 1e2 ids are Invalid Request (not
  integers), a NUL-filled line is a Parse error, a duplicate `token` key takes the last. Layering test passes.
- **J03.** Compiles, tests pass. Secret from `SystemRandomNumberGenerator`; store holds digests only (checked in the file),
  file 0600 also under `umask 0o777` and `umask 0` (probe), comparison loops over every byte and every stored digest without
  an early exit (read). One residual: `Data.write(.atomic)` makes a temp file with the process umask before the rename and the
  chmod; the content is only digests of 256-bit secrets and the folder is 0700, so no exposure. A `setAttributes` failure after
  a successful write leaves file and memory out of step (file ahead); not worth a card.
- **J04.** Order verified: method and params, token, capability, token machines, machine existence, agent access. A token
  without a machine in its scope gets -32001 for every id, existing or not (probe with a closed machine, another machine and a
  random id: identical). An unscoped token can tell "exists but agent access off" (-32003) from "unknown" (-32002); the ids are
  random 122-bit UUIDs and closed machines are never listed, so this is not enumerable; an owner may prefer one code.
  `noRefusalCarriesTheTokenThatWasPresented` cannot fail by construction (`ControlDenial` has no token field); it is a
  regression guard for someone adding one, and is described as such by the card.
- **J05.** Compiles after the edits above. Peer check: runs before the first read; a `nil` answer fails closed (probe: bytes
  written before `serve`, the client sees EOF, one denial recorded with a nil user, the machines untouched). Revoked token: an
  open connection gets -32001 on its next request (probe). Bounds, by probe: 64 KiB+ with and without newline, one byte
  every 100 ms against a 400 ms read limit closes at 0.43 s after 4 bytes, a half request then close does not hang, pipelined
  bytes are carried correctly. `getpeereid` duplicates `ConsoleSocket.peerIsCurrentUser` (the injectable form is needed). The
  `ConsoleSocket.swift` diff is exactly 12 changed lines. Flake: 20 runs clean.
- **J06.** Compiles after the edits. Probes: a socket file left by a crashed run (bound then closed) is replaced and served;
  a live listener is refused (`socketInUse`); a regular file in the way is refused and kept; a 0755 folder is refused; a path
  over 103 bytes is a refusal (`pathTooLong`), no fallback; socket mode 0600 and folder 0700 under `umask 0o777`; 30 clients past
  the limit are each closed with no message and, after a place is freed, the next is served; `stop()` ends the loop and removes
  the socket (the `done` signal is the last statement of the thread); dropping the listener without `stop()` also releases the
  thread and the socket within a tenth of a second. 20 runs clean, 15 under load clean.
- **J07.** Applies and passes; summary 102 characters. Profile matrix and Posture detection behave as written.
- **J08.** Applies and passes; docs gate passes with the ADR-0013 note and roadmap 0013 change; summary 105 characters.
- **J09.** Applies and passes. Behaviour change worth knowing: `suspendAndWait` clears the controller's `errorMessage` before
  suspending, which the old `suspendMachine` did not, so an earlier error banner can disappear when the user suspends.
- **J10.** Compiles after `import os`; the app target builds; `DependencyPolicyTests` passes with the new link. Tests 19 + 7
  pass; 20 runs of the service tests clean; `/tmp` has no `vmrs-` leftovers. The folder is created 0700 by
  `AppPaths.createPrivateDirectory` (hostile umask probe equal). A too-long data folder: the service stays off and Settings
  shows the console's message. Policy is read when the switch is applied (launch and toggle) and `VMLibrary` clamps at load,
  add and change, exactly like the other managed keys: a profile pushed while the app runs takes effect at the next launch.
- **J11.** Applies and passes. Note: opening Settings creates `Control/` (0700) and reads `tokens.json` even while the switch
  is off (the card only avoids this under the organisation's lock); harmless, inside the app's own data folder.
- **J12.** Applies; the commit count check (11) fits J01 to J11; docs gate passes; the card's grep is empty.

## Risks (accepted, to know)

- The 120 s answer deadline leaves the started operation running by design; four connections can each hold a long start.
- Refusals for malformed params, unknown methods, timeouts and library refusals are answered but not logged (decision left to
  the owner, as INDEX-J says).
- A start already running when the service is turned off is not recalled.
- Every `Thread` per read/write is created per call (cheap at four connections; revisit before a command-line client loops).
- `Log.control` strings checked: summary is public, token and machine ids are `.private`, no call can hold a secret.

## Owner decisions needing attention

1. Defaults of INDEX-J (framing per line, token in every request, notifications ignored, the limits, no fallback socket path,
   no prompt on agent start, exposure level low, managed key semantics, token scope hidden in Settings, coverage bundle): all
   implemented as written and consistent with the ADR. The coverage bundle (decision 13) is one `.vmr.json` edit and passes.
2. Departure: listener inside the library (decision 12). Reviewed favourably: it let the whole protocol, the stop behaviour and
   the bounds be attacked without the app, and it found the two defects above. Cost: `ControlProtocol` links `GuestConsole`
   and the console's socket helper becomes `package` (12 keyword edits, no behaviour change; `GuestConsoleTests` pass).
   The rename of the helper stays a follow-up.
3. Departure: `public` API instead of `package`. Needed only because the dead-code gate roots public declarations while
   `ControlClient` (and parts of the listener API) has no production caller until the command-line client; with `package` the
   gate would flag them. It widens the library's visible surface to everything in the table; acceptable as it is the
   console's own precedent. The owner may prefer `package` plus accepted deadwood lines when the client lands.
4. Whether -32002 and -32003 should be one code for an unscoped token (the oracle in J04 above).
5. Whether the nesting limit (8) and the cut-off on stop (new) are acceptable additions to ADR-0056; both tighten, neither
   changes a decision.

## What only the owner's run can confirm

Everything in INDEX-J's owner-run list, in particular: Settings renders the new section and the lock states; the real data
folder shows `Control/` 0700, `control.sock` 0600, `tokens.json` 0600 with no `vmrc_` text; `log show` displays the refusals
with the public summary and private ids; a real start answers when the machine runs and a forced stop when it stopped;
quitting with the service on removes the socket or the next start does; the managed key under a real configuration profile;
`sudo -u nobody nc -U` is refused; a client already connected is cut off when the switch is turned off (new step 6); behaviour
on macOS 15 (the build here used the macOS 27 SDK and the package floor of 26).

## Cleanup

The scratch worktree `/tmp/review-j`, the probe sources and logs, and the leftover `/tmp/control-*` folders from the one
probe run that crashed the test process were removed. Nothing was created in the repository, its `.git` aside from the
worktree registration (removed with `git worktree remove --force`).
