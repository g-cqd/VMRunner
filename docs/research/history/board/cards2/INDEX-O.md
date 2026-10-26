# INDEX-O — Chain O: the console client filters guest output and restores the host terminal

Base: `main` at `1b6f8d4` (or later). Files: COMMON.md (in `../cards/`), this index, O01.md to O06.md (one card each, one
commit each). Evidence and design input: `../terminalkit-assessment.md` (board document; decision taken: option A, no
dependency, everything in the repository). Nothing in a card's repository-bound text (code, comments, docs, commit
messages) names an outside project.

## The finding this chain closes

`ConsoleRelay` copies the guest's bytes to the person's real terminal unchanged ("Copies bytes ... unchanged", its doc
comment) and `lossyText` only repairs UTF-8. A guest, untrusted by design, can therefore set the window title (OSC 0/2),
write or query the clipboard (OSC 52), add hyperlinks (OSC 8), make the terminal type answers into the person's input (DA,
DSR/CPR, DECRQM, DECRQSS, title reports), switch on modes that outlive the session (alternate screen, mouse, bracketed
paste, application keys, keyboard protocols, a line-drawing set), reset the terminal (RIS, DECSTR), erase the scrollback,
and leave the terminal raw when a signal ends `vmr`. `TerminalMode.raw` restores on return or throw only; there is no signal
handling in the repository. The client already has a detach key (Ctrl-], byte 0x1D, since the console was built).

## How the cards were checked (read this before trusting them)

- The orchestrator could not build (brief). The Swift was **not compiled** by the author; a pre-dispatch review compiled and
  ran all six cards on `b19f40a` and fixed what it found (`REVIEWED-O.md`). Every Swift block was run through
  `swift-format` with the repository's `.swift-format` (output identical to the block: the cards' text is already in
  formatted form, which also proves it parses) and has no line of 140 columns or more.
- The filter's behaviour was checked against a Python model of the state machine, transcribed line by line from O01's
  Swift: all 123 table rows (whole, cut at every byte, one byte at a time), the "all removed rows in one stream" test,
  every assertion of O02 (limits, C1 forms, cut sequences, the boot log), 3000 + 2000 random rounds of the two property
  tests (the cards run 300 + 200), O03's hostile relay output and the raw-session reset bytes. All held. The model is
  evidence about the design and the expected bytes, not about the Swift compiling.
- Every `old` anchor in a file that exists on `main` was found exactly once with `grep -nF` in the real checkout at
  `1b6f8d4`: `GuestCommand.swift` (the import block and the `Console` command), `ConsoleEndToEndTests.swift` line 136,
  the end of `GuestCommandTests.swift`, roadmap 0005 (`## Remaining`, the "console client inside the app's bundle" line),
  ADR-0052 (its last update line), CONTRIBUTING (the `vmr guest console` line, the "measured numbers." paragraph end).
  Anchors in files an earlier card writes are that card's text verbatim.
- Facts read in the repository: `ConsoleRelay` is used only by `vmr guest console` and one test; `TerminalMode` only by
  that command; the bridge and `ConsoleSession` never touch the relay; `GuestConsole` may import only Foundation and
  Synchronization (`DependencyPolicyTests`); `SeededGenerator` and `GuestEnd` exist in `ConsoleTestSupport.swift`;
  `ConsoleSocket.streamPair`, `read`, `writeAll`, `close` are `package`; lint forbids the text `DispatchQueue`;
  `cyclomatic_complexity` ignores `case` lines; `vmr guest exec` on a missing socket exits 125 with "nothing is serving".

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/o-console-filter -b chain/o-console-filter main
```
`WT = ~/Developer/g-cqd/VMRunner-chains/o-console-filter`, branch `chain/o-console-filter`. One
chain, cards strictly in order, **one build at a time** (the gate takes 3 to 10 minutes). Every card leaves the branch
green with `swift run vmr check` (8/8 PASS). haiku (effort low) executes each card; sonnet (effort medium) reviews every
card before dispatch and the whole chain before merge; opus merges after the gate on the merged tree.

## How to read the code blocks of a card

Blocks start at the left margin; an `old` block is exact, blank lines and indentation included, and occurs once in its
file (check its first line with the `grep -nF` the card gives). "Create" means a new file with exactly that text; "Replace
the whole contents" means the file's text becomes exactly that.

## Rules for chain O (they override COMMON where they differ)

Standing owner rules, every card:
- **No outside project named** in code, comments, docs or commit messages. If a reason is ever needed, "an external
  terminal library"; preferably nothing. No distribution plans. **No board or card ids** (`O03`, `X17`...) anywhere in
  the repository.
- **Every commit atomic, signed (`-S`), builds, and `swift run vmr check` is 8/8 PASS before it, the 8 lines READ** (not
  inferred from an exit status). No push, amend or rebase.
- Swift 6.4, strict memory safety: every unsafe call is marked `unsafe` on the expression; warnings are errors; SwiftLint
  strict: `type_body_length` 300, `function_body_length` 60, `cyclomatic_complexity` 12, lines under 140 columns. Swift
  Testing only. Dolly fails on an exact clone; deadwood on a declaration only tests use (every declaration is wired in
  the card that adds it; no `@dw` directive is needed or allowed in this chain).
- **Agents never start a virtual machine** (`vmr guest start` is never run), never run `vmr guest console` against a real
  socket or terminal, and never send a signal to anything but the test process itself (O04's test, SIGUSR1). Tests use
  scratch folders, socket pairs, pipes and pseudo-terminal pairs only.
- **A test that writes to a peer that may not read sets the writing end non-blocking** (O03's relay tests do), or a
  regression hangs the gate. Writes the tests make otherwise are far smaller than the buffers.
- **Compile errors in a card's code:** fix a compile, format or lint error *minimally* without changing behaviour or what
  a test checks (a missing `try`/`await`/`unsafe`, an explicit type or conversion, an `import Dispatch`, a wrapped line)
  and list every fix in the report with the compiler line. A fix that would change behaviour, an API a later card names
  (`ConsoleOutputFilter.pass(_:)`, `.allows(_:)`, `.sequenceLimit`, `.stringLimit`, `ConsoleRelay.run(...filter:wake:)`,
  `.closingBytes(filtered:)`, `Ending.interrupted`, `SignalWatch(signals:)`, `.ending`, `.descriptor`, `.caught()`,
  `.stop()`, `TerminalMode.raw(on:_:)`, `ConsoleAttach.run`, `ConsoleAttach.rawWarning`) or a test's expectation: STOP and
  report.
- **A test that fails: STOP and report** the test and its output. Never edit a test, a limit or a baseline to get green.
- Diary: the next free number for 2026-10-23 at the time of O06 (`-06` is the last at `1b6f8d4`, so `-07` unless taken).
- Shell: fish is the login shell; wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.

Never-touch list: COMMON's list holds, with these exceptions, only for the files and lines each card names:
- `Sources/GuestConsole/ConsoleOutputFilter.swift` (O01, new), `Sources/GuestConsole/ConsoleRelay.swift` (O03, rewritten);
  nothing else in `Sources/GuestConsole` (the bridge, the session, the exec protocol, `LossyText` keep raw bytes).
- `Sources/DevTools/Guest/ConsoleAttach.swift` (O03 new, O04 and O05 rewritten), `TerminalMode.swift` (O04),
  `SignalWatch.swift` (O04, new); `Sources/DevTools/CLI/GuestCommand.swift` (O03 and O05: the `Console` command only; the
  `import GuestConsole` line stays, because `exec` needs it).
- Tests: `Tests/GuestConsoleTests/ConsoleOutputFilterTests.swift` (O01), `ConsoleOutputFilterStreamTests.swift` (O02),
  `ConsoleRelayTests.swift` (O03), `ConsoleEndToEndTests.swift` (O03: one call); `Tests/DevToolsTests/TerminalModeTests.swift`
  (O04), `GuestCommandTests.swift` (O05: two tests at the end).
- No card touches `Package.swift`, `Package.resolved`, `.vmr.json`, `.swiftlint.yml`, a baseline, or the app.

## Order, dependencies and files

| Card | What | Needs | Files (new = N) | Size | Risk |
|---|---|---|---|---|---|
| O01 | `ConsoleOutputFilter`: streaming, bounded state machine; allow-list; the 123-row table and 4 tests | — | `Sources/GuestConsole/ConsoleOutputFilter.swift` (N), `Tests/GuestConsoleTests/ConsoleOutputFilterTests.swift` (N) | ~450 | **high** |
| O02 | Stream tests: every row cut at every byte, limits, C1 both forms, seeded random properties, determinism, boot log | O01 | `Tests/GuestConsoleTests/ConsoleOutputFilterStreamTests.swift` (N) | ~180 | medium |
| O03 | Relay takes `filter` and `wake`, `closingBytes`; `vmr guest console` filters by default via `ConsoleAttach`; relay tests | O01 | `ConsoleRelay.swift`, `Sources/DevTools/Guest/ConsoleAttach.swift` (N), `GuestCommand.swift`, `ConsoleEndToEndTests.swift`, `ConsoleRelayTests.swift` (N) | ~330 | medium |
| O04 | `SignalWatch` (dispatch sources, self-pipe, no code in signal context), `TerminalMode.raw(on:)`, wiring, exit 128+N; pty and signal tests | O03 | `TerminalMode.swift`, `SignalWatch.swift` (N), `ConsoleAttach.swift`, `Tests/DevToolsTests/TerminalModeTests.swift` (N) | ~230 | **high** |
| O05 | `--raw` with a stderr warning and the mode reset at the end; help text; binary tests | O04 | `ConsoleAttach.swift`, `GuestCommand.swift`, `GuestCommandTests.swift` | ~110 | low |
| O06 | Docs: roadmap 0005 (dated "Built so far", two new "Remaining" items), ADR-0052 dated note, CONTRIBUTING, diary | O01-O05 | `docs/roadmap/0005-...md`, `docs/adr/0052-...md`, `CONTRIBUTING.md`, `docs/diary/2026-10-23-NN.md` (N) | ~110 doc | low |

Dispatch order: O01 → O06 in number order (O02 needs only O01 and may be dispatched after O03 if the reviewer prefers; it
touches no file another card touches).

## Where the filter belongs (decided)

In the **client relay only** (`ConsoleRelay.run`, console-to-terminal direction), never in `ConsoleBridge` or
`ConsoleSession`. The bridge serves every client and keeps the replay; `ConsoleSession` (exec, the agent path) needs the
raw bytes for `PromptClassifier` and `ExecScanner` (markers must be matched exactly as the guest sent them). Only the relay
writes to a person's terminal. The filter type lives in `GuestConsole` (the plain library: no import at all), so the app's
future bundled client (roadmap 0005, "opening the console in the user's terminal application") and a later screen model
can reuse it.

## Owner decisions (each card implements the default)

1. **Allow-list (minimal set for a serial login and a shell):** SGR `m` (digits, `;`, `:`); cursor `A B C D G H f`;
   erase `J` and `K` with no parameter or one of 0, 1, 2 (never `3J`, the scrollback); character editing `@ P X`. Why:
   boot logs use SGR and `CUU`+`CHA` for "[ ok ]" columns; readline and the BusyBox line editor use `C D K J A`, `\b`,
   and `P @` for mid-line edits; `clear` sends `H` + `2J`. Everything with a private marker (`?<=>`) or an intermediate
   is out, as is every other final byte (no scroll region, no `ESC 7/8`, no insert/delete line, no REP, no alternate
   screen). Alternatives: narrower (SGR and `K` only), or wider (alternate screen and scroll region, so full-screen
   programs work filtered).
2. **BEL passes** (shells use it for a failed completion; harmless). Alternative: drop it, or rate-limit it.
3. **Malformed UTF-8 is dropped silently**, not shown as U+FFFD: a replacement character is 3 bytes and the output must
   never grow. Alternative: one `?` per malformed byte.
4. **C1:** a single byte 0x80-0x9F is dropped alone (a UTF-8 terminal treats it as invalid, so `0x9B 31m` shows `31m`);
   in UTF-8 form it is dropped, and U+009B/0090/0098/009D/009E/009F take their sequence or string with them (some
   terminals act on them). Alternative: treat single-byte introducers the same way (costs up to 4 KiB of swallowed text
   after binary noise).
5. **Limits:** CSI at most 256 bytes (longer is dropped whole); a control string is given up after 4096 bytes and the rest
   reads as text (bounded memory: a counter; an endless OSC cannot silence the console forever). Alternative: 64 / 16 KiB.
6. **Reset at the end:** after a filtered session `ESC[0m` only (colours are the only thing filtered output can leave
   set); after `--raw`, the list in `ConsoleRelay.closingBytes(filtered: false)`; written only when standard output is a
   terminal. Known cost: `?1049l` on some terminals restores a saved cursor even outside the alternate screen.
7. **Signals watched:** SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM (the three asked, plus quit and a closed output, which
   also default to ending the process); received through dispatch sources with the signal ignored, a self-pipe, no code in
   signal context; exit status 128 + N. A crash (trap) of the client is not covered; the help says `stty sane`.
   Alternative: only the three asked.
8. **Detach key stays Ctrl-] pressed once** (it exists; a getty and a shell never need 0x1D; with the filter on, a guest
   cannot enable a keyboard protocol that would re-encode it). No `~.` escape. Alternative: Ctrl-] twice, or `~.` after a
   newline (costs a typed `~` at line start).
9. **`--raw` warns on standard error and does not ask.** Alternative: refuse unless standard input is a terminal, or ask
   for confirmation.
10. **No help topic of the app changes**: `vmr` is developer tooling; `vmr guest console --help` carries the text. The study
    `docs/research/automation-2026-10.md` is not edited. ADR-0052 keeps `status: accepted` and gets a dated note; decision
    8 (the exec protocol makes no claim against a hostile guest) stands, since exec reads raw bytes.
11. **Window size forwarding is not in this chain** (the serial port cannot carry it; it waits for the guest agent): a
    roadmap item.

## Owner-run list (never dispatched to an agent: it needs a real terminal application, and part of it a real guest)

Most of it needs no guest: a listener on a private socket stands in for the bridge. In the main checkout after the merge,
in bash or zsh (fish: `set P '...'`):
```
cd ~/Developer/g-cqd/VMRunner && swift build --product vmr
V=~/Developer/g-cqd/VMRunner/.build/debug/vmr
mkdir -m 700 /tmp/vmr-o
P='title\033]0;OWNED\007 clip\033]52;c;b3duZWQ=\007 alt\033[?1049h query\033[6n\033[c mouse\033[?1000h paste\033[?2004h \033[1;31mred\033[0m end\r\n'
```
1. Filtered. Terminal A: `printf "$P" | nc -lU /tmp/vmr-o/c.sock`. Terminal B (the terminal application under test; repeat
   in each one the owner uses): `$V guest console /tmp/vmr-o/c.sock`. B shows `title clip alt query mouse paste red end`
   with `red` in red; B's window title is unchanged; `pbpaste` is not `owned`; no alternate screen; nothing is typed back
   (A shows nothing after the payload); a click in B prints nothing. Ctrl-] detaches; `stty -a` shows `icanon` and `echo`
   (not `-icanon`, `-echo`); a paste at B's shell prompt shows no `200~`.
2. Raw. Same with `$V guest console --raw /tmp/vmr-o/c.sock`: the warning line comes first; the title and the clipboard
   may change (the terminal's own policy decides); after Ctrl-] the alternate screen, mouse reporting and bracketed paste
   are off again (a click prints nothing, a paste shows no `200~`), the cursor is visible, colours are reset. Reset the
   title and the clipboard by hand afterwards.
3. Signals. A: `nc -lU /tmp/vmr-o/c.sock` (no payload). B: `$V guest console /tmp/vmr-o/c.sock`. Third terminal:
   `pkill -TERM -f 'guest console /tmp/vmr-o/c.sock'`: B prints `ended by signal 15`, `echo $?` is `143`, `stty -a` shows
   `icanon echo`. Repeat with `-INT` (130), `-QUIT` (131), `-HUP` (129). Then close B's window while attached (SIGHUP) and
   check that no `vmr` is left (`pgrep -fl 'guest console'`).
4. Owner-authorised real-guest run (CONTRIBUTING, scratch directory, caps): `vmr guest start --directory /tmp/vmr-guest`,
   then `vmr guest console <socket>`: log in, `ls --color=always /`, `clear`, `printf '\033]0;x\007'` (title unchanged),
   `vi` (expected to draw badly filtered: no alternate screen; works with `--raw`); `vmr guest exec <socket> -- uname -a`
   still works (raw path untouched). `vmr guest stop --directory /tmp/vmr-guest; rm -rf /tmp/vmr-guest`.
5. `rm -rf /tmp/vmr-o`. Record the run in roadmap 0005 and the diary.

## What a sonnet pre-dispatch review should read hardest

- **O01** (the state machine): every transition against the design list in the card; that `continueCharacter` re-reads the
  cutting byte with `missing == 0` (no recursion loop); that `held` never exceeds `sequenceLimit` and `partial` 4 bytes;
  that `interrupt` passes the five controls mid-sequence and why that keeps the output idempotent; the C1 decision (single
  byte alone vs. UTF-8 form takes its sequence); the `allows` rule for `J`/`K`; whether the big table literal type-checks
  in reasonable time (the stop condition gives the split).
- **O04** (signals): that ignoring a signal still lets a dispatch source see it on macOS (kqueue `EVFILT_SIGNAL` records
  ignored signals); the activation race the test works around; the `Gate` lock ordering (`stop()` closes the gate before
  closing the pipe; a handler writes only under the lock); `deinit` plus the `defer` both calling `stop()`; SIG_DFL
  restored, not the previous disposition (vmr sets none); `openpty` visibility and the fallback; that SIGPIPE being ignored
  turns a closed output into an `EPIPE` error path (also fine).
- **O02**: whether every property truly holds for the Swift (idempotence, `isSafe`'s scan, output never longer), and
  `String(validating:as:)` availability on the deployment target.
- **O03**: the third `pollfd` with descriptor -1 (POSIX: ignored), the order console → input → wake in one iteration, the
  required `filter:` parameter (every caller updated), and the
  relay tests' descriptors (non-blocking writer, every one closed once).
- **O05/O06**: help text accuracy against the code; docs claims marked TESTED only where a suite covers them.

## Follow-ups found while carding (not in this chain)

- Window size forwarding: needs the guest agent over vsock (roadmap item added in O06).
- A screen model and a read-screen tool: extract the scanner from `ConsoleOutputFilter` so both policies (filter, model)
  sit on one parser (roadmap item added in O06).
- Job control: `kill -STOP` / SIGTSTP from outside leaves the terminal raw while stopped, and SIGCONT does not re-enter raw
  mode; SIGTTOU if `vmr` is in the background. Small, separate card.
- A closed standard output is reported as "the console closed" (the relay's `writeAll` maps `EPIPE` to
  `ConsoleError.closed`); a clearer message would name the output.
- Unicode bidirectional and invisible format characters (U+202A-U+202E, U+2066-U+2069, U+200B) pass the filter and can make
  text read differently; consider dropping them in a later card.
- A bell flood is not rate-limited.
- `vmr guest exec` writes the command's output to the person's terminal as the guest sent it (the exec scanner reads raw
  bytes; ADR-0052 decision 8): a hostile guest still reaches the terminal through `exec`. Filtering `GuestExec`'s output on
  the client side only (never in `ConsoleSession`) is a small card.
- The filter assumes a terminal that reads UTF-8: in a legacy 8-bit mode the continuation bytes 0x80-0x9F of valid UTF-8
  characters (for example U+011B, bytes C4 9B) would be read as C1 controls.
- The allow-list keeps cursor movement and erasing of the visible screen, so a guest can still redraw the visible screen
  (spoof a prompt); it cannot touch the scrollback, the title, the clipboard or the modes.
- The app's future bundled client must use the filter by default; say so when roadmap 0005's terminal-application item is
  carded.
