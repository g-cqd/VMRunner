# INDEX-K — Chain K: the `vmr control` command-line client and the first MCP step (roadmap 0005, "Remaining" items 2 and 3; ADR-0056)

Base: `main` at `b51d258`. Files: COMMON.md (in `../cards/`), this index, K01.md to K08.md (one card each, one commit each).

**How the cards were checked.** The orchestrator could not build in the main checkout, so it exported `b51d258` to a
scratch copy under `/tmp` (`git archive`), applied every card's edits in order exactly as the cards give them, ran
`swift-format` after each card (every `old` text of a later card is the formatted text an earlier card leaves), and ran
`swift run vmr check format swiftlint docs policy build test analyzers` on the tree after each card: all seven steps
PASS after every one of the eight cards (arcleak, dolly and deadwood included). The socket suites (`ControlClientTests`,
`MCPStdioTests`, `ControlMachineCommandTests`, `ControlMCPCommandTests`) then passed five runs in a row and left nothing
under `/tmp`. A research agent checked the nine MCP 2025-11-25 facts the cards rely on against the specification
(all confirmed). The
`workflows` step was not run there (the copy has no `.github` linters installed and no card touches `.github`). Every
anchor in a file that exists on `main` was found with `grep -nF` in the real checkout at `b51d258`. Executors still run the
full gate (8 steps) before each commit.

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/k-vmr-client -b chain/k-vmr-client b51d258
```
`WT = ~/Developer/g-cqd/VMRunner-chains/k-vmr-client`, branch `chain/k-vmr-client`. One chain, cards
strictly in order, **one build at a time** (the gate takes 3 to 10 minutes). Every card leaves the branch green with
`swift run vmr check` (8/8 PASS). haiku (effort low) executes each card; sonnet (effort medium) reviews every card before
dispatch and the whole chain before merge; opus merges after the gate on the merged tree.

## How to read the code blocks of a card

Blocks start at the left margin; an `old` block is exact, blank lines and indentation included, and occurs once in its
file (check its first line with the `grep -nF` the card gives). Blocks that hold a Markdown code fence use four backticks.
"Create" means a new file with exactly that text; "Replace the whole contents" means the file's text becomes exactly that.

## Rules for chain K (they override COMMON where they differ)

Standing owner rules, every card:
- **No outside project named** in prose, docs, comments or commit messages (say "the shared utility library", "another
  virtualization app"); no distribution plans; no board or card ids (`K04`, `X17`...) anywhere in the repository.
- **Every commit atomic, signed (`-S`), builds, and `swift run vmr check` is 8/8 PASS before it, the 8 lines READ** (not
  inferred from an exit status). No push, amend or rebase.
- Swift 6.4, strict memory safety: every unsafe call is marked `unsafe` on the expression; warnings are errors; SwiftLint is
  strict (its warnings fail): `type_body_length` 300, `function_body_length` 60, `cyclomatic_complexity` 12, lines under
  140 columns. Swift Testing only. Dolly fails on an exact clone; deadwood on a declaration only tests use (the cards wire
  every declaration in the card that adds it; no `@dw` directive is needed or allowed in this chain).
- **Agents never start a virtual machine and never open the app's real data folder** (`~/Library/Application
  Support/VMRunner`, `~/Library` at all, the app's preferences). Tests use scratch folders; socket tests a short private
  (0700) folder under `/tmp` they remove. **Never run `vmr control` by hand**: without `--socket` it looks at the owner's
  data folder. Every test that runs the binary passes `--socket` to a test fixture or sets `VMRUNNER_DATA_DIR` to a
  scratch folder.
- **A test that writes to a socket or a pipe whose peer may not read sets the writing end non-blocking**, or a regression
  hangs the gate (`LineIOTests` shows the form; K06 does it for the MCP output pipe). Writes the tests make otherwise are
  far smaller than the socket buffer.
- **Compile errors in a card's code** (unlikely: each card was built as given): fix a compile, format or lint error
  *minimally* without changing behaviour or what a test checks (a missing `try`/`await`/`unsafe`, an explicit type or
  cast, a `self.`, a line wrapped under 140 columns) and list every such fix in the report with the compiler line. A fix
  that would change behaviour, an API a later card names, or a test's expectation: STOP and report.
- **A test that fails: STOP and report** the test and its output. Never edit a test, a limit or a baseline to get green.
- Diary: the next free number for 2026-10-23 at the time of K08 (`ls docs/diary | grep 2026-10-23`; `-01` and `-02` exist
  at `b51d258`, so `2026-10-23-03.md` unless another merge took it).
- Shell: fish is the login shell; wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.

Never-touch list: COMMON's list holds, with these exceptions, only for the files and lines each card names:
- `Package.swift` (K02: `"ControlProtocol"` in the `DevTools` target; K03: `"ControlProtocol"` in the `DevToolsTests`
  target; K05: the `AgentBridge` and `AgentBridgeTests` targets; K07: `"AgentBridge"` in the `DevTools` target);
- `.vmr.json` (K05: `AgentBridgeTests` joins `coverage.testBundles`; nothing else);
- `Sources/ControlProtocol/ControlClient.swift` (K01, rewritten) and `Sources/ControlProtocol/JSONRPC.swift` (K05: one
  `public` keyword);
- `Tests/DevToolsTests/ModuleBoundaryTests.swift` (K05: one test, one argument).

## Order, dependencies and files

| Card | What | Needs | Files (new = N) | Size | Risk |
|---|---|---|---|---|---|
| K01 | Client: one read buffer per client (pipelining), answer nesting (8) and size bounds, `request` (send only), `ControlCaller` (one call per connection, own token, the socket's user checked first) | — | `Sources/ControlProtocol/ControlClient.swift`, `ControlCaller.swift` (N), `Tests/ControlProtocolTests/ControlClientTests.swift` (N) | ~330 | **high** |
| K02 | `vmr control` group and `status`; socket path (`--socket`, `VMRUNNER_DATA_DIR`, default) and token (`--token-file` private file, `VMR_CONTROL_TOKEN`; never an argument); exit statuses | K01 | `Package.swift`, `Sources/DevTools/CLI/VMRCommand.swift`, `Sources/DevTools/Control/ControlTarget.swift` (N), `ControlStatus.swift` (N), `Sources/DevTools/CLI/ControlCommand.swift` (N), `Tests/DevToolsTests/ControlTargetTests.swift` (N), `ControlCommandTests.swift` (N) | ~390 | medium |
| K03 | `list`, `state` (id or name), `--json`, error-code-to-status table; the test fixture (library listener under `/tmp`, machines in memory) | K02 | `Package.swift`, `ControlTarget.swift`, `ControlCommand.swift`, `Sources/DevTools/Control/ControlInvocation.swift` (N), `Tests/DevToolsTests/Support/ControlFixture.swift` (N), `ControlMachineCommandTests.swift` (N), `ControlTargetTests.swift` | ~420 | medium |
| K04 | `start`, `stop [--force]` | K03 | `ControlCommand.swift`, `ControlInvocation.swift`, `ControlMachineCommandTests.swift` | ~170 | low |
| K05 | `AgentBridge` library: strict MCP parsing; `initialize`, `ping`, `tools/list`; tool calls turned into actions; manifest, layering test, coverage | K01 | `Package.swift`, `.vmr.json`, `Sources/ControlProtocol/JSONRPC.swift`, `Sources/AgentBridge/MCPServer.swift` (N), `MCPTool.swift` (N), `Tests/AgentBridgeTests/MCPServerTests.swift` (N), `Tests/DevToolsTests/ModuleBoundaryTests.swift` | ~420 | medium |
| K06 | The stdio loop (bounded lines, ends at end of input), tool calls through `ControlCaller`, results as text, refusals as `isError` with the code | K05 | `Sources/AgentBridge/MCPStdio.swift` (N), `Tests/AgentBridgeTests/MCPStdioTests.swift` (N) | ~230 | **high** |
| K07 | `vmr control mcp` | K04, K06 | `Package.swift`, `ControlCommand.swift`, `Tests/DevToolsTests/ControlMCPCommandTests.swift` (N) | ~110 | low |
| K08 | Docs: roadmap 0005 (dated "Built so far", trimmed "Remaining"), ADR-0056 dated note, CONTRIBUTING (library rule, `vmr control` section with exit statuses), README (layout, tooling), diary | K01-K07 | `docs/roadmap/0005-...md`, `docs/adr/0056-...md`, `CONTRIBUTING.md`, `README.md`, `docs/diary/2026-10-23-03.md` (N) | ~150 doc | low |

Dispatch order: K01 → K08 in number order. K05 and K06 need only K01 (they could run before K02 to K04 if those are held;
K07 needs all of K01 to K06). Sizes over 300 lines are mostly tests and code given verbatim.

**No help topic changes in this chain.** `vmr` is the repository's developer tooling (`swift run vmr`), not the app: nothing
the app shows or does changes, so no `HelpTopic` or `HelpContent` file is touched. The app's control-service help keeps its
`nc -U` example; pointing it at `vmr control` would describe a tool users of the app do not have.

## Owner decisions (each card implements the default)

1. **Where MCP lives: a new library target, `AgentBridge`** (K05), linking `ControlProtocol` and `GuestConsole` only; the
   tooling links it, the app does not. The research note's design is "thin front ends" that forward to the socket: in
   `ControlProtocol` (which the app links) the app would carry an MCP parser it never runs; in `DevTools` (which links the
   tooling's packages) a server bundled later could not reuse it. Alternatives: either of those.
2. **Its name: `AgentBridge`** (ADR-0042: named for what it provides; not `MCPServer`, the name of its main type, which
   rule 4 forbids; no grab-bag suffix). Alternative: `ControlMCP`.
3. **Both libraries keep a `public` API** (dead-code roots, as `ControlProtocol` and `GuestConsole` do); moving them to
   `package` access becomes roadmap 0005 "Remaining" item 9 (K08). Alternative: do it now, with narrow `@dw` directives.
4. **Coverage:** `AgentBridgeTests` joins `coverage.testBundles` in `.vmr.json` (K05). Say no and K05 drops that edit.
5. **Token file strictness: any permission bit for the group or others (mode & 077) refuses the file**, with the
   `chmod 600` to run; so do a link, another owner, more than 4 KiB, or text that does not start with `vmrc_`. The brief
   said "world-readable"; group access is refused too, as for a private key. Alternative: refuse only mode & 004.
6. **Token sources:** `--token-file` wins over `VMR_CONTROL_TOKEN`; there is no option that takes the token itself
   (`--token` is an unknown option, exit 64).
7. **Exit statuses** (in `vmr control --help` and CONTRIBUTING): 0 done; 1 the service refused (-32002, -32003, -32004,
   other codes, a name that matches no machine or several); 64 usage or no token; 66 token file unreadable, missing, a link;
   69 nothing serves the socket; 75 no answer in time or the service's -32005; 76 an answer the client cannot read; 77 not
   permitted (-32001, a token file open to others, a socket another user serves, `status` with a refused token).
8. **A machine may be named by its name** when the text is not a UUID: resolved through `machines.list` (so the token
   also needs `list`); no match or several is exit 1. Alternative: ids only.
9. **One connection per call** (`ControlCaller`): the service closes a connection idle for 10 s, and MCP tool calls are
   sparse. Alternative: a held connection with reconnects.
10. **The client checks the socket's user (`getpeereid`) before it sends a token** (K01); a socket served by another user
    is refused with 77 and nothing is sent.
11. **`status` checks a token by listing machines**, so a token without `list` shows as refused (exit 77) even if it may
    start machines. Alternative: an unauthenticated ping method in the service (a protocol change, not in this chain).
12. **MCP protocol versions: 2025-11-25** (the revision the research note cites) **and 2025-06-18**; any other requested
    version is answered with 2025-11-25 and the client decides. Server name `vmrunner-control`, version `1.0.0`.
13. **MCP limits and strictness:** a line of at most 1 MiB (a longer one is answered -32600 and ends the session, exit 1),
    nesting at most 16, empty lines skipped, no batch, no null, boolean or fractional id, no member besides `jsonrpc`,
    `id`, `method`, `params`; notifications and answers are not answered; requests before `initialize` are served (no
    session state). Unknown tool: -32602; an argument that is not a string or a boolean, or arguments that are not an
    object: a tool error (`isError`), as MCP 2025-11-25 asks for input errors.
14. **Tool results:** the service's JSON result as the one text content; a service error as `isError: true` with the text
    `error <code>: <message>`; an unreachable service as `isError: true` with the reason. No `structuredContent` and no
    output schema yet.
15. **Tool annotations:** list and state read-only; start not destructive, idempotent; stop destructive, idempotent; none
    open-world.
16. **The research note is not edited** (the documentation law: a study is not edited to match a later decision); roadmap
    0005 and ADR-0056 carry the record.

## Owner-run list (never dispatched to an agent: it opens the real app and starts a real machine)

After the merge, in the main checkout, with a scratch data directory as CONTRIBUTING requires for real runs (never the
owner's own library), and one Linux machine set up in it:
```
cd ~/Developer/g-cqd/VMRunner
swift run vmr build-app && swift build --product vmr          # the app, and .build/debug/vmr
mkdir -m 700 /tmp/vmr-owner
VMRUNNER_DATA_DIR=/tmp/vmr-owner build/VMRunner.app/Contents/MacOS/VMRunner &
export VMRUNNER_DATA_DIR=/tmp/vmr-owner                      # vmr control then looks in /tmp/vmr-owner/Control/control.sock
V=~/Developer/g-cqd/VMRunner/.build/debug/vmr
```
1. Service off: `$V control status; echo $?` prints `error: no socket at /tmp/vmr-owner/Control/control.sock: ...` and `69`.
2. Settings → Automation: turn the service on. `$V control status; echo $?`: "the control service is listening at
   /tmp/vmr-owner/Control/control.sock", "no token given ...", `0`.
3. Settings → Control tokens: create `owner-read` with List machines and Read state; copy it; `umask 077; pbpaste >
   /tmp/vmr-owner/read.txt`. `chmod 644 /tmp/vmr-owner/read.txt; $V control status --token-file /tmp/vmr-owner/read.txt;
   echo $?`: refused as open to other users, `77`; `chmod 600 /tmp/vmr-owner/read.txt`. Then `$V control status
   --token-file /tmp/vmr-owner/read.txt`: "the token is accepted: it lists 0 machine(s)".
4. Turn on the machine's **Allow agent access** (editor, Automation). `$V control list --token-file
   /tmp/vmr-owner/read.txt` shows one line (id, `stopped`, `linux`, name); add `--json`; `$V control state <name>
   --token-file /tmp/vmr-owner/read.txt` prints `<name> (<id>): stopped`. `$V control start <name> --token-file
   /tmp/vmr-owner/read.txt; echo $?`: `error: Not permitted (-32001)` and `77`.
5. Create `owner-act` with List, Start and Stop into `/tmp/vmr-owner/act.txt` (as in 3). Owner-authorised real-guest
   start: `$V control start <name> --token-file /tmp/vmr-owner/act.txt` prints `<id>: running` once it runs; then `$V
   control stop <name> --token-file /tmp/vmr-owner/act.txt` prints `<id>: shuttingDown`; start it again and `$V control
   stop <name> --force --json --token-file /tmp/vmr-owner/act.txt` prints `{"id":"<id>","state":"stopped"}`.
6. MCP by hand (prints three lines: ids 1, 2 and 3; id 3's text lists the machine):
   ```
   printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"owner","version":"1"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"machines_list"}}' | VMR_CONTROL_TOKEN="$(cat /tmp/vmr-owner/read.txt)" $V control mcp
   ```
7. With an MCP client application of the owner's choice: a stdio server with command `$V` (the absolute path above),
   arguments `control mcp`, and environment `VMRUNNER_DATA_DIR=/tmp/vmr-owner` and `VMR_CONTROL_TOKEN=<owner-read's
   token>`. Ask it to list the machines and read one's state; with `owner-act` instead, to start and stop it (an
   owner-authorised real-guest run). While it runs, `ps -ax -o command | grep -c '[v]mrc_'` prints `0` (no token in any
   process's arguments).
8. Revoke `owner-read`; `$V control list --token-file /tmp/vmr-owner/read.txt; echo $?`: `-32001`, `77`. Turn the service
   off: `$V control status; echo $?` says there is no socket (or that nothing serves it) and `69`; a tool call in the MCP
   client answers that the control service could not be used.
9. `log show --last 30m --predicate 'category == "control"'`: each refusal is there, and `... | grep -c vmrc_` prints `0`.
10. Quit the app; `rm -rf /tmp/vmr-owner`; `unset VMRUNNER_DATA_DIR`.
Record the run in roadmap 0005 (item 1) and the diary; if the owner accepts it, set ADR-0056 to `accepted`.

## What a sonnet pre-dispatch review should read hardest

- **K01**: the struct-to-`final class` change of `ControlClient` (every existing caller: `ControlConnectionTests`,
  `ControlListenerTests`, `LineIOTests`, `ControlServiceTests` in the app's tests), the `Mutex` held across a blocking
  read (one receiver at a time is the documented contract), and `ControlCaller`'s order: connect, user check, then send.
- **K06**: the stdio loop's ends (end of input, a too-long line, a failed write), `continue` inside the `switch`, and the
  test's pipes (the output end non-blocking, the input written and closed before the loop starts, the loop on its own
  thread).
- **K05**: whether the strict reading matches MCP 2025-11-25 where it matters to clients (string or integer ids, no null;
  notifications and answers unanswered; unknown tool -32602 versus input errors as tool errors; the `initialize` result).
- **K02**: the token file checks (`attributesOfItem` does not follow a link; the time between the check and the read is
  the user's own folder), the default socket path against the app's `AppPaths` (`URL.applicationSupportDirectory` +
  `VMRunner/Control/control.sock`), and that no test can reach `~/Library`.
- **K03/K04**: the fixture's lifetime (`stop()` on every path), the exact human output strings, and the JSON error print
  before the non-zero exit.

## Follow-ups found while carding (not in this chain)

- `exec` through `ConsoleSession` as a control method and an MCP tool, behind its own capability (roadmap 0005 item 2).
- `package` access for `ControlProtocol` and `AgentBridge` (roadmap 0005 item 9).
- The service could offer an unauthenticated `service.ping` so `vmr control status` need not spend a token's `list` right.
- `ControlAnswer.id` reads a JSON `true` as 1 (`as? Int` on a Boolean `NSNumber`); harmless for the service's answers.
- A bundled MCP server (inside the app's bundle) would let users of the app, not only of the repository, point an agent at
  it; it needs a decision on shipping a second executable.
