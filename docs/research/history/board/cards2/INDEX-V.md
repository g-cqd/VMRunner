# INDEX-V — Chain V: container follow-ups from the first real run (roadmap 0024; ADR-0057, ADR-0056)

Base: `main` at `fdebe0c` (or later: the patches apply only if the files they touch did not change; if `git apply --check`
fails, STOP and report, do not merge by hand). Files: COMMON.md (in `../cards/`), this index, V01.md to V05.md (one card,
one commit each), the fixtures `fixtures/V01.patch` to `V05.patch` and `fixtures/V01.msg` to `V05.msg`, and
`W-STOP-RUN.md` (the authorised real-guest re-run, after the merge; it commits nothing). Design input kept for the
reviewers: `V-artifacts/SPEC-V.md` (the decided design), `V-artifacts/appnap-fix.diff` and
`V-artifacts/ScratchStopTimingTests.swift` (the debugger's draft and scratch tests; not committed: the timing tests take real
seconds).

## Evidence

`~/Developer/g-cqd/vmrunner-board/realguest-container-report.md` (2026-10-25, main `fdebe0c`) and the
debugger's findings:
1. A stop of a running container took 72.4 s to reach `stopped` (design: the stop line, SIGTERM at 10 s, SIGKILL at 15 s).
   With fake runners the driver meets 10.3 s and 15.7 s. Best-supported candidate, **unproven**: App Nap coalescing the
   main-actor sleep timers that carry the escalation, because a container workload held no activity and the app, launched
   directly, was never activated. The code-side worst case (escalation 15 s, drain wait 2 s re-armed at most 5 times) is about
   27 s, not 72 s.
2. The container's output could not be read anywhere outside the app's window, so the run could not confirm `uname`.
3. Quit with a running container shows the quit alert ("Quit Anyway" kills after 5 s via `terminateAll`); by design, but
   the alert is invisible to automation in an app that was never activated.
4. The app's descriptors went 44 to 54 over the runs; not shown to be a leak; the control listener's accepted connections
   were not checked.

## What the chain does

| Card | Scope | Size (stat) | Risk |
|---|---|---|---|
| V01 | A running container holds a user-initiated activity (not latency-critical, the Mac still sleeps); the stop path logs each step at `info`, category `container`, with the runner pid | 5 files, +165 −4 | low: no behaviour change besides the activity; balance of begin/end on every path |
| V02 | Each run's filtered output is appended to `container-output.log` in the machine's folder: 0600, created exclusively, 1 MiB with one previous file, written off the main actor on one shared serial queue, refused for a link, FIFO, hard link or open file; removed with the machine, not copied by Duplicate | 9 files, +792 −7 | **medium**: file I/O on a path in the bundle; the only change to an existing test is the bundle's file list |
| V03 | `machines.log` (read-only, capability `log`, same order of checks as `machines.state`, at most 64 KiB), `vmr control log MACHINE [--bytes N]`, MCP tool `machines_log`; the exposure line, help, README and CONTRIBUTING say that a token holder can read a container's output | 21 files, +595 −34 | **medium**: a new protocol requirement and a new capability (see owner decision 3) |
| V04 | A serialized test proves the control listener closes every accepted connection on seven paths, and a `/dev/fd` count over 131 connections | 1 file, +262 | low: test only; real sockets under /tmp |
| V05 | Docs: ADR-0057 and ADR-0056 dated notes, roadmap 0024 (Left items), roadmap 0036 (one stale line), diary `2026-10-25-04.md` | 5 files, +104 −8 | low: claims about a real run; every number comes from the report |
| W-STOP-RUN | Authorised re-run of the stop timing (A: direct launch, never activated; B: Launch Services `open`, in front; C optional: the old build), with `vmr control log` | — | **owner-authorised only**: starts a real VM |

## Verification already done

Developed in a scratch clone of `main` at `fdebe0c`, reviewed (no blocker; three should-fix in V02 and three suggestions,
all applied before the final commits), each commit gated 8/8 (`swift run vmr check`: format, swiftlint, docs, workflows,
policy, build, test, analyzers; the 8 lines read) and signed:

| Card | Commit (scratch) | Gate | `VMRunnerTests` in the gate |
|---|---|---|---|
| V01 | `5476182` | 8/8 PASS | 1211 tests in 197 suites |
| V02 | `70d262f` | 8/8 PASS | 1235 tests in 198 suites |
| V03 | `6108ffa` | 8/8 PASS | 1240 tests in 198 suites |
| V04 | `3e25760` | 8/8 PASS (first run of its own gate at `fdebe0c` failed once on `UserNetStackTests` `aServerThatResetsBecomesAResetForTheGuest`, unrelated; passed alone 3 times and on the rerun) | 1240 tests in 198 suites |
| V05 | `48d0703` | 8/8 PASS | 1240 tests in 198 suites |

Then the five cards were applied, from their text alone, in order, on a fresh clone of `main` at `fdebe0c` and gated after
each (see "Card replay" at the end of this file).

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/v-containers -b chain/v-containers main
```
`WT = ~/Developer/g-cqd/VMRunner-chains/v-containers`, branch `chain/v-containers`. Cards strictly in
order, one build at a time. haiku (effort low) executes each card; sonnet (effort medium) reviews every card before dispatch
and the chain before merge; opus merges after the gate on the merged tree.

## Rules for chain V (they override COMMON where they differ)

- **No outside project named** in code, docs, comments or commit messages ("the container package", "the shared utility
  library"); no distribution plans; **no board or card ids** (`V01`, `S-RUN`, ...) anywhere in the repository. The fixtures
  were checked for both; do not add any.
- **No `NNNN` or `DD` placeholders.** The ADR and diary numbers are already in the fixtures (ADR-0056 and ADR-0057 get
  dated notes; the diary file is `docs/diary/2026-10-25-04.md`). If `ls docs/adr docs/diary` in `WT` shows that number taken
  by then (another chain landed first), STOP: the integrator renames to the next free number (`ls docs/diary | tail -3`; the
  next of the day is `<date>-<n+1>.md`, a new day starts at `-01`) and regenerates the fixture.
- **Atomic, signed commits:** one per card, `git commit -S`, made only after `swift run vmr check` printed 8 `PASS` lines
  and you READ them (not inferred from an exit status). No push, amend or rebase.
- **Swift 6.4 strict memory safety** (`unsafe` on the expression; no `String(format:)`), **warnings are errors**, **SwiftLint
  strict** (`type_body_length` 300, `function_body_length` 60, `cyclomatic_complexity` 12, lines under 140 columns), **Swift
  Testing** only, the **leak analyzer** (the gate's `analyzers` step) clean. The fixtures pass all of these as they are; a
  card does not edit code by hand.
- **Agents executing cards never start a virtual machine, never launch the app, never run the real `ContainerRunner`.**
  The tests use scratch folders and fake runner scripts only.
- **A test that fails: STOP and report** the test and its output. Never edit a test, a limit or a baseline. Known flaky:
  `pingToLoopbackThroughTheStack`; TestKit "atLeast resumes when a later sleeper reaches the target"; and, seen once in this
  chain's development, `UserNetStackTests` `aServerThatResetsBecomesAResetForTheGuest`. One rerun of the gate; report both
  runs; a second failure is a stop.
- **Non-blocking writer rule:** a test that writes to a pipe or socket whose peer may never read sets the writing end
  non-blocking (the fixtures do: V04's clients are `O_NONBLOCK` with a 10 s stall limit; V02 opens with `O_NONBLOCK`).
- **Never touch** what COMMON lists, and `Sources/VMRunner/Model/Security.swift` (the container exposure line is in
  `ContainerExposures.swift`).
- Shell: fish is the login shell; wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.

## Procedure of every card (the card gives N, the parent subject, the hash and the stat)

`F = ~/Developer/g-cqd/vmrunner-board/cards2/fixtures`.
1. `git -C WT status --short` prints nothing; `git -C WT log -1 --format=%s` prints the card's parent subject.
2. `shasum -a 256 F/V0N.patch F/V0N.msg` prints the card's two hashes. Different: STOP.
3. `git -C WT apply --check F/V0N.patch` prints nothing, then `git -C WT apply --index F/V0N.patch`.
4. `git -C WT diff --cached --stat` matches the card's stat line by line (file names and counts).
5. `cd WT && swift run vmr check > /tmp/vmr-V-gate-V0N.log 2>&1; echo exit=$?` (in the background; wait for it): `exit=0`,
   and `grep -E '^(PASS|FAIL)' /tmp/vmr-V-gate-V0N.log` shows exactly the 8 steps, each `PASS`. Read them.
6. `git -C WT commit -S -F F/V0N.msg`; `git -C WT log -1 --format='%h %G? %s'` shows `G` and the card's subject.
7. Report: the SHA, `git -C WT show --stat HEAD`, the 8 gate lines, the `Test run with ... tests in ... suites` line of
   `VMRunnerTests` from the log, and the last 5 lines of each command's output. `rm /tmp/vmr-V-gate-V0N.log`.

## Owner decisions (each card implements the default)

1. **The activity a running container holds** is `.userInitiatedAllowingIdleSystemSleep`, from the runner's start to its end;
   not latency-critical, not governed by the "Keep input responsive" setting (that one is the latency activity of a machine
   with a screen). Alternative: hold it only while a stop is pending (narrower, but leaves App Nap on the output path).
2. **The output file** keeps the most recent output in `container-output.log` and one previous file, each at most 1 MiB, the
   same filtered text as the log pane plus run markers (`[run started <ISO 8601>]`, exit and finish statuses, runner errors);
   not the runner's own diagnostics. Removed with the machine, not copied by Duplicate. Alternative: no file, or a size
   setting.
3. **A new capability `log`**, not folded into `state`: a token made before this chain cannot read output until the owner
   ticks it. Cost: an OLDER app cannot load a `tokens.json` that lists `log` (its decoder refuses the unknown value, the
   store is refused and left untouched, so the older app accepts no token until upgraded again). Alternative: a tolerant
   decoder (risks rewriting the file without `log` on the next change).
4. **`machines.log` takes no size**: the protocol's params stay strings and booleans; the tail is always at most 64 KiB and
   `vmr control log --bytes N` (1 to 65536) cuts on the client; `--json` with a size is a usage error.
5. **MCP `machines_log`** answers the service's JSON (`id`, `text`, `truncated`) like the other tools, and is listed third
   (list, state, log, start, stop) so the existing assertions on the last tool still hold.
6. **The placeholder bundle identifier `com.example.VMRunner`** (NOT implemented; decide): the repository's identifier is
   shared with the owner's own installed app, so both use the same standard defaults domain and the same
   `.data-directory-override` domain by name, and Launch Services sees two apps with one identifier (W-STOP-RUN's run B
   checks that the installed app is not running and unregisters the built app afterwards). Default: keep the placeholder
   until a real identifier is chosen for publication; the change touches `Resources/Info.plist`, `Log.fallbackSubsystem`
   and its test, and the docs that name the domain.

## What a sonnet pre-dispatch review should read hardest

- **V02 `ContainerOutputFile.swift`** (322 lines): open flags (`O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK`, `O_EXCL` + `fchmod`),
  the `fstat` checks (regular, owner, one link, mode), rotation by `rename` with the one shared drain queue, the pending
  budget and its dropped-bytes note (it must survive the cut), the UTF-8 cut, `tail` opening current before previous and
  dropping a previous with the same inode, log-once per kind. Is any descriptor alive after a drain or a `tail`?
- **V02's change to an existing test** (`ContainerWorkloadTests.swift`, the bundle's file list gains
  `container-output.log` after waiting for the drain): justified by the design, not a weakening.
- **V03 the dispatcher and the adapter**: the order of checks against `machines.state`, the 64 KiB cut in the dispatcher
  whatever the adapter returns, the `@concurrent` read off the main actor, the VM refusal, the organisation-off path, and the
  worst-case answer size (64 KiB of NULs escape to about 384 KiB, under the client's 1 MiB).
- **V03 the exposure and help text**: the exposure line now says a token holder can read the container's output; check the
  help's capability and method lists against the code.
- **V01 begin/end balance** of the activity (a start that throws holds nothing; `ended` and `isolated deinit` both guarded).
- **V05**: every number against the report; "unproven" stays unproven.
- **W-STOP-RUN**: the `open -n --env` launch (the check that the data folder took), the bundle-identifier precondition, the
  token rewrite for run C, the cleanup of the Launch Services registration.

## Owner-run list (never dispatched to an agent without the owner's authorisation)

`W-STOP-RUN.md`, after the merge. It writes
`~/Developer/g-cqd/vmrunner-board/realguest-container-report-2.md`.

## Follow-ups found while carding (not in this chain)

- The run-start marker is written when the machine is prepared, so a start that fails before the runner launches leaves a
  marker with no end line (harmless; could move to the workload's start).
- `tail`'s same-inode branch (a rotation between its two opens) has no test.
- `UserNetStackTests` `aServerThatResetsBecomesAResetForTheGuest` failed once under load: a flaky candidate.
- The menu-quit path and the quit alert remain unverified (W-STOP-RUN run B tries it).
- The app's descriptor growth (44 to 54) remains unexplained; the listener is proven clean by V04.
