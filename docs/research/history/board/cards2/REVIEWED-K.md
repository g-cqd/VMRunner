# REVIEWED-K — independent pre-dispatch review of chain K (K01 to K08)

Method: scratch worktree of `b51d258` under `/tmp` (detached; main checkout untouched), the cards applied in order with a script that
reads each `old`/`new`/create block straight from the card text (so no hand transcription), `swift-format` after each card, a
build and the card's own tests after each card, then the real built `vmr` driven with hostile input. Finally `swift run vmr check`
on the whole chain (cards as edited below): 8 of 8 `PASS` (format, swiftlint, docs, workflows, policy, build, test, analyzers;
arcleak, dolly and deadwood PASS). 7 card edits were made (listed at the end). The scratch tree, `/tmp` folders and logs were removed.

## Verdicts

| Card | Verdict | Why |
|---|---|---|
| K01 | ready after edits | One test could not fail (nesting); fixed. Design holds (see attacks). |
| K02 | ready after edits | `status` reported a token that was given but not checked as "no token given"; fixed with a test. |
| K03 | ready | Anchors, build, tests, 10 runs, no leftovers. |
| K04 | ready | Same. |
| K05 | ready after edits | An id above Int64 (for example 18446744073709551615) was answered with id -1; fixed with a test row. |
| K06 | ready after edits | Doc comment and Why overstated the 10 s output stall (true for a non-blocking output only) and hid the dropped last line; text corrected. |
| K07 | ready | No defect found; real-binary session test passes 10 runs. |
| K08 | ready after edits | One README line was incomplete, and the diary's decisions list lacked the dropped-last-line behaviour. |

Every anchor of every card matched exactly once (nothing to correct there). No compile error, no format or lint error, no warning
in any card's code as given. No outside project, board or card id, in the chain's added lines (grepped for names and `K0n`).

## Attacks and results

### K01 (client, caller)
- Every caller of the old struct compiles unchanged; the 63 tests of `ControlProtocolTests` and `ControlServiceTests` pass.
- The Mutex is held across the blocking read. `close()` and `send()` take no lock, so nothing deadlocks. But `close()` from another
  thread does NOT wake a receiver blocked in `poll`: measured, the receiver came back with `timedOut` only after its full timeout
  (3 s in the probe; up to 125 s with the default). So "stop" cannot interrupt a call in flight; the cards only use the client
  synchronously (one call per connection, no concurrent close), so this is harmless today. Anyone who adds a cancel must know it.
- Answers are matched by order, not id; callers send one request per connection, so no mismatch is possible.
- Caller order connect, `getpeereid`, send token: confirmed by the injected-uid test (nothing written, peer sees end of stream).
  I also tried a REAL foreign-uid socket (`/var/run/mDNSResponder`, owner uid 65, world-connectable): `ControlCaller` threw
  `peerIsAnotherUser`, and so did `vmr control list/status --socket /var/run/mDNSResponder --token-file ...` (exit 77, message
  "nothing was sent to it"). A peer-user lookup that fails (nil) is also refused (nil never equals the current user).
- Hostile service (own-uid unix server, real binary): junk line, 2 MiB without newline, 100000-deep nesting, immediate close, all
  end with exit 76 and the documented message, no crash, no hang.
- Defect fixed: the "too deeply" test used 2000 levels, which Foundation's parser refuses itself above 512, so it passed without
  the client's bound. Added a test with 9 levels (Foundation reads 9, only the client's bound refuses it).

### K02 (target, token)
- The token is never an argument: `--token X`, `--token=X` give "Unknown option" and exit 64. File refusals checked on the binary:
  mode 644 (77, with `chmod 600`), symlink (66), 5000-byte file (66), whitespace inside the token (64), wrong prefix (64), a missing
  file (66). Environment variable path and precedence (file wins) confirmed. No message repeats a token read from a file or the
  variable (checked for file, env and prefix errors).
- Residual: a token typed in a wrong place on the command line is echoed by ArgumentParser's own usage error
  ("Unexpected argument 'vmrc_...'" for a positional). That is the user's own terminal and the value was already typed; it cannot be
  fixed inside the cards. Worth one sentence if the owner cares.
- The checks and the read are two steps (`attributesOfItem`, then `Data(contentsOf:)`): a swap between them needs write access to
  the file's folder, which the cards already treat as the user's own. Acceptable; say so if a token file is ever put in a shared folder.
- `ps` reasoning: the token lives in the environment of `vmr` (or a file); argv holds only paths. `ps -E` shows an environment only
  to its owner and root. Statement in the help is correct.
- Default socket: `home/Library/Application Support/VMRunner/Control/control.sock`, built like `URL.applicationSupportDirectory +
  VMRunner` and `AppPaths.control` + `control.sock`; `VMRUNNER_DATA_DIR` handling (absolute, no `..`, standardized) mirrors
  `AppPaths.resolveRoot`. Equality was checked by reading, not by a run (DevTools cannot import the app). The tests' environment is a
  whitelist, so an exported `VMR_CONTROL_TOKEN` or `VMRUNNER_DATA_DIR` in the developer's shell cannot reach them; no test touches
  `~/Library`.
- Defect fixed: when a token was given but the check could not finish (foreign socket, timeout, bad answer), `status` printed "no
  token given ... not checked" and JSON `"token":"absent"`. Now `unchecked` ("a token was given but could not be checked").
  A test covers it (exit 69, JSON says `unchecked`, no token text).

### K03/K04 (fixture, list/state/start/stop)
- Both suites (`ControlMachineCommandTests`, `ControlCommandTests`) 10 runs each: 0 failures, 0 flakes, 0 leftovers (`/tmp/vmr-cf-*`,
  `/tmp/vmr-cc-*`, scratch temp folders). The MCP suite's scratch folder uses `TMPDIR`, also empty afterwards.
- Fixture lifetime: `stop()` on both the success and the error path; a thrown error in `start` removes the folder.
- Note: `ControlFixture` and the e2e helpers do not time-bound a hung `vmr` shorter than the helper's 420 s default; the client's own
  125 s limit ends it first.

### K05 (parsing)
- Parser against what clients send: `initialize` with roots/sampling/elicitation capabilities and `clientInfo` (answered, version
  echoed when supported, otherwise 2025-11-25), `notifications/initialized` and any id-less message (no output), `ping`,
  `tools/list` (with or without `params:{}`), `tools/call` (arguments absent: fine), unknown method -32601, unknown tool -32602,
  tool input errors as `isError`, result shape `content[{type:text}]` + `isError`, batch refused, CRLF line ends accepted, BOM and
  duplicate keys accepted by Foundation, invalid UTF-8/NUL give -32700 with id null.
- Strictness that a client could trip on (not changed, decisions to know): `"params": null` is -32602 (clients that omit params
  are fine); `"arguments": null` is a tool error rather than "no arguments".
- Defect fixed: an integer id above Int64 was echoed as -1 (a client would wait forever). Now refused as invalid id. Test row added.
- Depth 16 accepted, 17 refused, 500000-deep refused in 1.2 s (debug). The tests pin the 5000-deep case (answered -32600; Foundation
  alone would say -32700) but not the 16/17 boundary.

### K06 (stdio loop), K07 (`vmr control mcp`)
- Stdout purity: across 40 hostile sessions every stdout line was valid JSON-RPC, stderr stayed empty, exit 0 except the over-long
  line (exit 1, one -32600 line, then end). Empty input, only newlines, answers from the client, 100000 blank lines, 10000 pings
  (0.12 s): fine. Stdin closed: exit 1; `/dev/null`: 0. Stdout closed or reader gone: the process ends (exit 1 or killed by SIGPIPE, 141);
  no hang.
- 1 MiB line (exact, and +1) and 2 MiB without newline: correct results but about 5 s each in a debug build, because `LineBuffer`
  rescans the pending bytes after every 4 KiB read (quadratic). Bounded by the 1 MiB cap, so not a hang, but an agent-sized input
  is slow; reading 64 KiB chunks would cut it 16-fold. Not changed (the card's code is the tested form); owner's call.
- Partial last line at EOF (no trailing newline) is dropped silently with exit 0. Now stated in the K06 doc comment and in the diary.
  A client that closes stdin right after writing a request without a newline gets nothing; MCP clients end messages with a newline.
- Output stall: `ConsoleSocket.writeAll` only times out on a NON-BLOCKING descriptor. The tests make the pipe non-blocking; the real
  `vmr control mcp` writes to a blocking stdout, which waits for its reader. Text corrected (K06 doc comment and Why).
- A blocked tool call (a start can take up to 120 s) holds the loop: later messages, including a cancellation, wait. By design.
- An agent's `token` argument is replaced by the caller's own token (checked), so an agent cannot present another token.

### K08 (docs honesty)
- Roadmap, ADR note, CONTRIBUTING and diary say TESTED only for what the suites really cover, and NOT RUN for the app/client run.
  Verified by me and not claimed by the cards: a real foreign-uid socket (see K01), exit 76 for junk answers, the over-length answer.
  Exit 75 (timeout) was not reached by any run.
- Fixed: README line now says `AgentBridge` links ControlProtocol and GuestConsole (the manifest test says both); diary
  "Decisions to confirm" now lists the dropped last line.
- The diary and roadmap text "eight commits, each through the gate" is a promise about the executor's run; the card already tells
  the executor to fix the sentence if untrue.

## INDEX-K's 16 decisions: ones needing attention

- 5 (mode & 077 refuses group access): consistent in code, help, CONTRIBUTING and tests; stricter than the brief; fine, flag to owner.
- 8 (name resolution needs `list`): a name equal to a UUID string is taken as an id; two machines with one name exit 1. Fine.
- 9 (one connection per call): costs one extra connection for `status` (a probe connect, then the call); the service sees a
  connection that closes at once. Harmless.
- 11 (`status` spends `list`): confirmed (exit 77 for a token without it).
- 12/13 (versions, strictness): `params: null` and `arguments: null` are refused or errors; listed above. A client sending
  protocolVersion 2025-03-26 gets 2025-11-25 and decides, as the spec allows.
- 14/15: tool result text and annotations match `MCPTool`.
- 16: consistent with the documentation law; nothing edits the research note.
- INDEX line "K05 and K06 need only K01" holds (their anchors are in files K02 to K04 do not touch).

## Only an owner run can confirm

Everything on INDEX-K's owner-run list, in particular: the app's service accepting `vmr control` on the default path (path equality
is by reading), a real token minted in Settings, `start`/`stop` of a real guest, an MCP client application accepting the server
(`initialize` shape, `tools/list` schemas, annotations), the `log show` refusals without any `vmrc_` text, exit 75 on a real slow
start, and that `ps` shows no token while a client runs.

## Card edits made (7)

1. `K01.md`: added test `anAnswerOneLevelPastTheNestingLimitIsRefused` (9 levels), test file 127 to 136 lines, Test paragraph.
2. `K02.md`: `ControlStatus` gets `TokenCheck.unchecked`, set when a token is given, shown by `lines` (76 to 79 lines).
3. `K02.md`: new test `aTokenThatCouldNotBeCheckedIsNotReportedAsAbsent` in `ControlCommandTests` (63 to 77 lines), Test paragraph.
4. `K05.md`: `requestID` refuses an integer id that does not fit `Int` (`String(number.intValue) == number.stringValue`); new test row for
   18446744073709551615; counts 161 to 164 and 133 to 134 lines; "twelve" malformed lines.
5. `K06.md`: `serve` doc comment and Why corrected (non-blocking output only; last line without newline dropped); 71 to 72 lines.
6. `K08.md`: README line for `Sources/AgentBridge` names both libraries.
7. `K08.md`: diary "Decisions to confirm" gains the dropped-last-line sentence (52 to 53 lines).
