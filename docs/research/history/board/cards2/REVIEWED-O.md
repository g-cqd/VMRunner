# REVIEWED-O — pre-dispatch review of chain O (sonnet), compiled and run

Reviewed against `main` at `b19f40a` (the cards say `1b6f8d4` or later; every anchor still matches). Method: scratch
worktree detached at `b19f40a`, the six cards applied in order from the card text by script (no hand edits), `swift build
--build-tests`, the cards' tests, an independent attack corpus, real runs of `vmr guest console` through a pty against an
`nc -lU` listener, and finally a **fresh replay of the edited cards** on a clean tree followed by `swift run vmr check`.

Result of that replay: `swift run vmr check` exit 0, 8/8 PASS (format, swiftlint, docs, workflows, policy, build, test,
analyzers; arcleak, dolly, deadwood PASS). Before the edits it was 7/8: swiftlint FAILED (see O01 and O02).

## Verdict table

| Card | Verdict | What the compile found |
|---|---|---|
| O01 | ready after the edits listed | Compiles first time. 123 cases pass. Swiftlint: 5 `prefer_self_in_static_references` errors in the test's `FilterVector`. Table type-check: not an issue (see below). |
| O02 | ready after the edit listed | Compiles, 14 tests (both filter suites) pass. Swiftlint: 1 `legacy_multiple` error (`% 2 == 0`). |
| O03 | ready after the edits listed | **Compile error**: removing `import GuestConsole` from `GuestCommand.swift` breaks the build (`exec` uses `result.output` / `result.status`; MemberImportVisibility). Everything else compiles; 5 relay tests + end-to-end pass, 5 runs and 20 loaded runs stable. |
| O04 | ready after the edit listed | Compiles. **Test failure**: both raw-mode restore tests failed 20 of 20 runs (macOS sets PENDIN on leaving raw mode, so `c_lflag` is not bit-identical). After the fix: 20 of 20, and 20 of 20 under 10 busy processes. |
| O05 | ready after the edit listed | Compiles, the two binary tests pass, `--help` lists `--raw`. Help sentence overclaimed (see edits). |
| O06 | ready after the edits listed | `vmr check docs` passes. Two docs-honesty problems fixed (see edits). |

## Card edits made (15 edits in 7 files)

O01 (2)
1. Test file, struct `FilterVector`: `-> FilterVector` becomes `-> Self` (3 places) and `FilterVector(name:` becomes `Self(name:`
   (2 places) inside the struct only. Reason: swiftlint `prefer_self_in_static_references`, 5 errors; the gate step failed.
2. Filter's doc comment: one sentence added: the filter assumes a terminal that reads UTF-8 (in a legacy 8-bit mode the bytes
   0x80-0x9F inside valid UTF-8, e.g. C4 9B, would be C1 controls). Docs honesty: it is the one precondition under which the
   "no C1 reaches the terminal" claim fails.

O02 (1)
3. `random.next() % 2 == 0` becomes `random.next().isMultiple(of: 2)` (formatted by `swift-format` to two lines). Same
   behaviour; swiftlint `legacy_multiple`.

O03 (2)
4. Step 3 (remove `import GuestConsole` from `GuestCommand.swift`) deleted, steps renumbered, the "Files" line, the "Why"
   paragraph and the stop condition rewritten: the import must stay (the `exec` command needs it). The original would have
   stopped the haiku run at the first build.
5. Help text in the new `Console` command: "so the guest can neither change nor read this terminal" becomes "so the guest
   cannot set this terminal's title, clipboard or modes, or make it answer" (the allow-list still lets a guest move the cursor
   and erase the visible screen, so "neither change" overclaimed). Line wrapped with `\`, under 140 columns.

O04 (1)
6. `sameFlags` in `TerminalModeTests` leaves out `PENDIN` (`let pending = tcflag_t(PENDIN)`, compare `c_lflag & ~pending`), with
   a doc comment; the "Test" paragraph says so. Measured on a fresh pty: original `c_lflag` 1483, restored 536872395 = 1483
   plus 0x20000000 (PENDIN). All other flag words and the speeds are identical. This does not weaken the test: the raw-mode
   and ICANON/ECHO/ISIG assertions are unchanged.

O05 (1)
7. Same help-text wording as edit 5, in the old anchor (its grep string now `'takes one client at a time.'`), the old
   block, and the new block (three places).

O06 (4)
8. Roadmap item for the terminal application: "that client already filters the guest's output" (false: the bundled client does
   not exist yet) becomes "and that client must use the console output filter by default".
9. Diary row 6 (bridge and exec still see raw bytes): verdict `TESTED (by reading and the existing suite)` becomes
   `INFERRED (from the call graph; the existing console suites still pass)`. Nothing asserts it; reading is not a test.
10. ADR-0052 note and CONTRIBUTING: say that `vmr guest exec` prints a command's output as the guest sent it (unfiltered).
    A reader of "only the console client filters" would otherwise think `exec` output is safe on the terminal.
11. Diary "Not verified": new bullet for the same exec fact.

INDEX-O (4)
12. Never-touch list: `GuestCommand.swift` import line is no longer touched.
13. Review-reading list for O03: the import removal bullet dropped.
14. "How the cards were checked": says a compiled review exists (this file).
15. Follow-ups: three added (exec output unfiltered; UTF-8 terminal assumption; screen spoofing via cursor moves/erase).

## O01 filter: my own attack (not the card's table)

A throwaway test in the scratch tree (removed afterwards) ran 394 hostile and benign cases (each as `A<x>B`, expected output
written by hand), every case whole, cut at every single byte, one byte at a time, and for inputs under 40 bytes at every
pair of cuts, plus 600 random streams of up to 1500 bytes (the full byte range with the sequence-building bytes weighted
up) fed one byte at a time with the filter's `held` and `partial` buffers measured after each byte.

Covered: OSC 0/1/2/4/7/8/9/10/11/12/52 (write, read, `p`)/104/133/777/1337 (File, SetUserVar, RemoteHost)/99 with BEL and with ST;
DCS, APC, PM, SOS with ST and BEL and empty; DECRQSS (m, r, space-q, quote-q), XTGETTCAP, sixel, a tmux passthrough, a kitty
graphics APC; DA1/DA2/DA3, DSR/CPR/DECXCPR, `?15n ?25n ?26n ?53n ?62n ?63n ?996n`, DECRQM (`$p`, `$y`), XTWINOPS
`14t 16t 18t 19t 20t 21t 22/23;*t 8;..t 1t 2t 3t 4t 5t 9t`, `>0q`, `x`, `"p`, `"q`, `!p`; about 30 private-mode numbers
set and reset (`?1 ?3 ?4 ?5 ?6 ?7 ?9 ?12 ?25 ?47 ?66 ?69 ?1000-1007 ?1015 ?1016 ?1047-1049 ?2004 ?2026 ?2027 ?9001`, a
multi-mode list, `4h 20h 2h 12h`); kitty keyboard protocol (`>1u >31u =5;1u =1;2u <u <1u ?u 1;5u`, `>4;2m`, `27;5;9~`);
RIS `ESC c`, DECSTR, DECALN `ESC # 8`, `ESC # 3`, `ESC # 6`; charset designations `ESC ( 0`, `) * +`, `( B`, `( A`, `-./`, `% G`, `% @`,
`ESC SP F/G/L/M/N` (S7C1T/S8C1T), `ESC ( <`, `ESC $ B`, `ESC $ ) C`; 23 two-byte escapes (`7 8 = > D E H M N O Z \ n o | } ~ 6 9 c g l m`);
SI/SO (`0x0E 0x0F`, alone and followed by `lqqk`), NUL, DEL, ENQ, VT, FF, SUB, CAN, EM, FS-US, XON/XOFF; CAN/SUB mid-CSI and
mid-OSC; ESC restarting a CSI and an OSC; `ESC ESC [ 6 n`; BEL, LF, NUL, DEL inside a query; `ESC DEL [6n`, `ESC LF [6n`; every
C1 single byte named and `0x80`/`0xA0`; all 32 C1 code points in UTF-8 form and CSI/OSC/DCS/PM/SOS/APC openers in UTF-8
form; 19 malformed UTF-8 forms (overlongs C0/C1/E0/F0, surrogates ED A0/BF, F4 90, F5, F8, FE, FF, lone 80/BF/A0, cut 2/3-byte);
overlong spellings of C1 and of ESC; a CSI of 10000 digits (`n` and `m`), of 253 digits (kept), of 300 digits; an OSC of 4200
bytes, of 100000 bytes; the allowed set (SGR, colons, cursor, erase, character edit, UTF-8, controls) and 16 near-misses of
allowed finals (`3J`, `?2J`, `?K`, intermediates, `1;2K`, `>1m`, `?1m`, `=1m`, `<1m`, `1 m`, `1"m`, `1$m`, `1!m`, `;m;`).

Findings:
- **No filter bypass.** In every case and every cut the output contains no ESC except as the start of an allowed CSI sequence
  (checked with the card's own `allows` on each ESC), no C0 other than BEL BS HT LF CR, no DEL, no C1 control, no SO/SI,
  and is valid UTF-8. 600 fuzz streams: 0 unsafe outputs, output never longer than input, one-byte feeding equals whole feeding.
- **Memory bound holds**: `held` max 6 on fuzz (cannot exceed 256 by `hold`), `partial` max 4. 8 MiB of ESC bytes and a flood
  of 20000 restarted 255-digit CSIs (5 MB) run in 0.4 s in a debug build; 16 MiB of text 1.1 s (debug). No hang.
- **Line drawing is removed**: `ESC ( 0` is dropped as an escape with an intermediate; `SO`/`SI` are dropped; `lqqk` after `SO`
  shows as the letters `lqqk` (readable, not boxes).
- **Residue of a removed sequence: none from sequences.** Residue that exists is the documented design only: after a single
  0x9B the following `6n` shows as text; the final byte after a CAN/SUB cancelled CSI shows (`ESC [ 6 CAN n` gives `n`, as a
  terminal would); the tail of a control string past 4096 bytes shows as text (an OSC 52 payload longer than 4 KiB would
  print its remainder as base64-looking text).
- Behaviour differences from what I first expected, all consistent with the card text: a UTF-8 C1 opener (C2 90/98/9B/9D/9E/9F)
  also swallows the following text up to a terminator, so `A C2 9D x B` yields `A` (the `B` is inside the string); the UTF-8
  string terminator U+009C (C2 9C) does **not** end a string (the design lists only BEL, `ESC \`, CAN, SUB), so a terminal that
  honours U+009C would see the string end earlier than the filter does; the filter errs on the side of swallowing, at most
  4096 bytes.
- Mutation check of the tests: 6 deliberate breakages of the filter (accept `?` in SGR, accept `3J`, drop the intermediate
  state, drop BEL as string end, allow `n`, off-by-one string limit) were each caught by the tests (a seventh, on the C1
  opener list, mis-targeted its anchor and did not apply). The O01/O02 tests can fail.
- Table type-check: the whole test file type-checks in 0.22 s with every expression under 20 ms; no split of the `removed`
  array needed. Full `swift build --build-tests` of the package took 46 s.
- Precondition not enforced (now stated in the doc comment): a terminal in a legacy 8-bit mode reads 0x80-0x9F inside valid
  UTF-8 (U+0100-U+01FF and others have such continuation bytes) as C1 controls.

## Placement (O03) and the raw path

`ConsoleRelay` and `ConsoleOutputFilter` are referenced in `Sources` only by `ConsoleAttach.swift` (and the two files
themselves). `ConsoleBridge`, `ConsoleSession`, `GuestExec`, the helper and the app never mention the filter; the bridge/exec
tests pass unchanged (81 tests in the GuestConsole/GuestCommand/policy suites; `DependencyPolicyTests` passes: the filter
imports nothing). Residual: `GuestExec` writes `result.output` (raw guest bytes) to standard output, so `vmr guest exec` can
still carry escape sequences to the person's terminal; documented (edits 10, 11, 15).

## O04 signals, measured

- On macOS an ignored signal is still delivered to a dispatch source: all five production signals (HUP, INT, QUIT, PIPE, TERM)
  became a byte with the right number; a 5000-signal flood drained 1661 bytes with no crash or block (the pipe is
  non-blocking and drops). Dispositions: DFL before, IGN while active, DFL after `stop()`.
- `stop()` twice is harmless; a `deinit` without `stop()` restores DFL; `caught()` after `stop()` returns nil.
- Close-on-write race: 200 rounds with a thread sending SIGUSR2 continuously, `stop()`, then a new pipe (likely recycling the
  numbers) read after 3 ms: 0 stray bytes. The gate lock design works.
- Start-up race: real, as documented (a signal in the window between `SIG_IGN` and the source becoming active is lost, since it
  is ignored); the test copes by resending; production exposure is a few milliseconds at attach.
- Real runs of the built `vmr guest console` in its own pty (never my terminal) against `nc -lU` under `/tmp`: Ctrl-] gives
  exit 0 and "detached"; SIGTERM/INT/QUIT/HUP/PIPE sent to that child give exit 143/130/131/129/141 and "ended by signal N";
  in all of them the pty is raw while attached (ICANON and ECHO off) and canonical with echo after. Closing the pty master
  while attached ends the client (exit 0, "end of input", reaped within 5 s). 20 of 20 runs of `TerminalModeTests`, 20 of 20
  under load. The poll with a `-1` wake descriptor works (relay tests without wake pass).
- Residual (already in INDEX follow-ups): SIGTSTP/SIGCONT not covered; a closed stdout shows "the console closed".

## O05 `--raw`, measured

Same `nc -lU` + pty harness, payload with title, clipboard, alternate screen, DA1/DA2, mouse, bracketed paste, a charset
switch, SO/SI, title report, DECRQSS, RIS, 8-bit and UTF-8 CSI/OSC, SGR, BEL:
- Default: the captured terminal output is `login: ESC[1;31mred ESC[0m lqqk   6n   BEL BEL ok CRLF END CRLF`, then on exit
  only `ESC[0m`; stderr `attached ...` / `detached`; **nothing was sent back to the listener** (nc stdout empty); no title,
  clipboard, mode or charset sequence reached the pty.
- `--raw`: stderr starts with the `warning: --raw passes ...` line; the capture is byte-identical to the payload; at the end
  the reset list (`?1049l ... ?25h ?7h ESC > ESC 7 ESC[r ESC 8 ESC(B SI ESC[0m`) is written. Same with a signal end (SIGTERM).
- Stdout not a tty (stdin `/dev/null`, stdout a pipe): no reset bytes in the output in either mode (filtered output
  identical to the captured text; raw output identical to the payload), stderr says "end of input", exit 0.
- The two binary tests are real (they run the built `vmr`; exit 125 and "nothing is serving").

## O06 docs honesty

Verified vs not: the diary table's counts are true (85 removed rows, 30 kept, 8 edges, 123 cases; 300 + 200 random
inputs = "500"; "six commits" matches the chain). Claims 1-5, 7 are TESTED by a suite; 6 is now INFERRED (edit 9); 8 says
"in parts" and the whole path NOT RUN, which stays true for the repository's tests; claim 9 NOT RUN stays owner-only (this
review's pty runs are not in the repository and are not claimed there). The roadmap edit is by text (the "terminal
application" item is item 5 at `b19f40a`; items 10 and 11 are added after item 9; no renumbering); ADR-0052 `status:`
untouched; `docs/research` untouched (diff empty); no board or card id, and no outside project name, in any repository-bound
text of the six cards (searched Sources, Tests, docs, CONTRIBUTING). Diary number `07` is correct at `b19f40a`.

## Risks (after the edits)

- The haiku run is mechanical now; the remaining risk is a changed machine (a different Xcode could change PENDIN or lint
  versions): the stop rules cover that.
- Filter text loss: 4 KiB swallowed after an unterminated control string or UTF-8 opener, bounded.
- Screen spoofing remains (cursor movement + `2J` pass, as designed); scrollback, title, clipboard, modes, answers do not.
- `exec` output unfiltered (see above).
- Gate time: the replay's `test` step took 47 s and `build` 5 s warm; the full check from cold takes minutes.

## Decisions needing attention (the 10 defaults)

1. **Allow-list**: fine for login, boot log, readline. Consequences to accept: `less`, `man`, `vi`, `top`, `htop` (alternate
   screen, scroll regions, `ESC 7/8`, `ESC M`) draw badly when filtered; `--raw` is the answer. `CSI 2J` + `H` lets a guest
   repaint the visible screen. I would keep the default; the wider alternative (alternate screen, scroll region) re-opens the
   mode-leak surface the closing bytes cannot fully fix.
2. **BEL passes**: harmless but unlimited (a bell flood). Keep, or rate-limit later (listed in follow-ups).
3. **Malformed UTF-8 dropped**: confirmed no growth and no residue; keep.
4. **C1**: single byte dropped alone (so `0x9B 6n` shows `6n`), UTF-8 form takes its sequence. Safe on a UTF-8 terminal; keep,
   and know the UTF-8 precondition (now in the doc comment). U+009C does not terminate strings in the filter.
5. **Limits 256 / 4096**: measured; memory bound is 260 bytes; keep.
6. **Reset at the end**: filtered `ESC[0m`, raw the long list; verified written only to a tty. Known cost `?1049l` stays. The
   raw reset does not undo a title or clipboard change (the warning says so).
7. **Signals incl. SIGQUIT and SIGPIPE**: verified end to end with exit 128+N. Keep.
8. **Ctrl-] once**: works in the pty harness; with the filter on no keyboard protocol can be enabled. Keep.
9. **`--raw` warns, no confirmation**: the warning is on stderr first (verified). Keep.
10. **No help topic of the app; study not edited**: honoured. Decide separately whether `exec` output should be filtered.
11. Charset shifts: removed (ESC ( 0, ESC ) 0, SO, SI): confirmed; text stays readable.

## What only an owner run can confirm

- Real terminal applications (each one used): title unchanged, `pbpaste` unchanged, no answers typed back, no alternate screen
  (INDEX-O owner list 1-3). My pty runs prove the bytes, not the terminal's behaviour (including 8-bit/legacy modes, and
  terminals that honour U+009C).
- A real guest: boot log shape (OpenRC `ESC[A ESC[71G` columns), `ls --color`, `clear`, `vi` behaviour, `exec` still working.
- Closing the terminal window while attached (SIGHUP delivered by a real terminal), job control (`kill -STOP`), Ctrl-] in
  terminals with enhanced keyboard modes enabled before `vmr` started.
- Whether the first signal after attach can be lost in the few-millisecond start-up window on a loaded machine (not
  observable in my runs).

## Cleanup done

Scratch worktree removed (`git worktree remove --force /tmp/review-o`), all `/tmp/rvo-*` directories, the author's `/tmp/o-sim`,
the `/tmp/rvo-nc` socket directory and my test processes removed; nothing was written outside `/tmp` and the board; the
repository was never modified.
