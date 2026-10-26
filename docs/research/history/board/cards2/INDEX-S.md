# INDEX-S — Chain S: containers run from the app (roadmap 0024; ADR-0017, amended by a new ADR)

Base: `main` at `6bab9e9`. Files: COMMON.md (in `../cards/`), this index, S01.md to S11.md (one card each, one commit each),
and S-RUN.md (the authorised real-guest run of a container from the app, after the merge).

## What the chain builds

Until now the container runner (`Packages/Containers`, roadmap 0024) could only be run by hand with `vmr container-sign`.
This chain lets the app run a container as a machine of its own kind. The runner stays a separate, signed executable
that boots one virtual machine for one container; the app starts it as a child process, reads its event lines, shows the
container's output in a log view, and stops it. The container library is not linked into the app (it would add its pinned
packages to the root graph; see "Next chain"). A container machine appears in the library, the New Machine sheet, the
editor, the help, the security summary and the control service, and an organisation can forbid it.

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/s-containers -b chain/s-containers 6bab9e9
```
`WT = ~/Developer/g-cqd/VMRunner-chains/s-containers`, branch `chain/s-containers`. One chain, cards
strictly in order, **one build at a time** (the gate takes 3 to 10 minutes; the nested package build adds to it). Every
card leaves the branch green with `swift run vmr check` (8/8 PASS). haiku (effort low) executes each card; sonnet
(effort medium) reviews every card before dispatch and the whole chain before merge; opus merges after the gate on the
merged tree.

## Rules for chain S (they override COMMON where they differ)

Standing owner rules, every card:
- **No outside project named** in code, docs, comments or commit messages (say "the container package", "the shared
  utility library"); no distribution plans; **no board or card ids** (`S04`, ...) anywhere in the repository.
- **Every commit atomic, signed (`-S`), builds, and `swift run vmr check` is 8/8 PASS before it, the 8 lines READ** (format,
  swiftlint, docs, workflows, policy, build, test, analyzers), not inferred from an exit status. No push, amend or rebase.
  A card that touches `Packages/Containers` also runs `cd WT/Packages/Containers && swift test` (its own suite) and reports
  the result.
- **Swift 6.4, strict memory safety:** every unsafe call is marked `unsafe` on the expression; no `String(format:)`;
  warnings are errors; SwiftLint is strict (its warnings fail): `type_body_length` 300 (VMController is near the limit: new
  code goes in same-file extensions), `function_body_length` 60, `cyclomatic_complexity` 12, lines under 140 columns. Silence a
  false positive only with a line-level `// swiftlint:disable:this <rule>`. Swift Testing only; TestKit `AsyncGate`,
  `AsyncEventProbe` and `TestClock`, no real sleeps, no `nonisolated(unsafe)`. Deadwood: prefer wiring a use; otherwise a
  trailing `// @dw:accept:this <rule> -- <reason>`.
- **Never touch:** `Package.swift` and `Package.resolved` at the root, `.vmr.json`, `.swiftlint.yml`, analyzer baselines,
  `Sources/VMRunner/Network`, `Sources/VMRunner/Policy`, `Sources/NetPolicy`, `Sources/NetStack`, `Sources/TestKit`,
  `Sources/VMHelper*`, `Sources/GuestConsole` (use its `ConsoleOutputFilter`, do not edit it). One exception:
  `Sources/VMRunner/Model/Security.swift` may be edited by the security card (S09) only, for the posture line the chain needs.
- **Process-spawning code must not leak descriptors** (close the parent's copies of the child's ends, close read and write
  handles at exit) and **must kill its children when the app quits.**
- **Tests use scratch directories** (the temporary directory plus a UUID) and **fake runner executables** (a shell script
  the test writes, `chmod 0700`) only. Tests never start a virtual machine, never run the real `ContainerRunner`, never
  touch `~/Library` or the app's real data folder.
- **A test that writes to a pipe or socket whose peer may never read sets the writing end non-blocking**, or a regression
  hangs the gate.
- **A compile, format or lint error in a card's own code:** fix it *minimally* without changing behaviour or what a test
  checks (a missing `try`, `await` or `unsafe`, an explicit type, a `self.`, a line wrapped under 140 columns), and list
  every such fix in the report with the compiler line. A fix that would change behaviour, an API a later card names, or a
  test's expectation: STOP and report.
- **A test that fails: STOP and report** the test and its output. Never edit a test, a limit or a baseline to get green.
- **Disk space:** if a build or test stops on "No space left on device", free space and rerun; that is not the card's
  failure.
- **One known flaky test:** the network stack's `pingToLoopbackThroughTheStack` needs a host that answers loopback ICMP and
  can fail once under load. Rerun the gate once and report both results; a second failure is a stop.
- **A second known flaky test:** TestKitTests "atLeast resumes when a later sleeper reaches the target"
  (`TestClockRendezvousTests.swift:46`) exceeded its 60 s limit once under load, in the gate of the sixth card. Rerun the
  gate once and report both results; that timeout is not the card's failure, and a second one is a stop.
- Shell: fish is the login shell; wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.

## Order, dependencies and risk

All cards: model haiku, effort low. Dispatch strictly in number order, S01 to S11. S04 does not depend on the files of S01
to S03 (it only touches the app's model), but it is applied after them so each card's `old` texts are the files the
previous cards leave.

| Card | Scope | Needs | Size (lines) | Risk |
|---|---|---|---|---|
| S01 | The runner takes an image, command, environment, CPUs and memory on its command line, and streams its events as JSON lines; a `stop` line or end of input stops it (status 75) | — | ~770 | **high**: the stop path runs only with a real VM |
| S02 | `vmr container-run`: sign the runner and run it on an image and a command, confirmed with `--boot` | S01 | ~470 | medium: signal path |
| S03 | `vmr build-app` embeds the signed runner at `Contents/Helpers/ContainerRunner`, checked against its own entitlement policy | S02 | ~215 | low |
| S04 | The data model: workload and container spec in `VMConfig`, checked on read; the library keeps a machine without a disk | — (applied after S03) | ~520 | low |
| S05 | The seam under the controller: a workload with capabilities, a factory routing each start, a running machine that may show a log | S04 | ~350 | **high**: wide refactor |
| S06 | The runner as a child process: command line, event lines, bounded filtered log, a driver that stops and kills it, a registry that ends every runner at quit | S04 | ~1587 | **high**: processes, pipes, signals |
| S07 | A container machine starts, shows its log and stops from the app: workload, factory, log view, quit hook | S04, S05, S06 | ~700 | **high**: changes the start path of every machine; spawns processes |
| S08 | Create a container machine from the New Machine sheet; tell it apart in the sidebar | S04 | ~440 | low |
| S09 | The editor shows a container only what applies; the help explains containers; the security summary tells the truth about them; an organisation can forbid them (`AllowContainers`) | S04 to S08 | ~865 | medium: edits `Security.swift`; the settings form draws sections from a list |
| S10 | The control service tells a container from a virtual machine (`workload`) and starts and stops a container through the same paths | S05 to S07, S09 | ~313 | medium: a public type gains a hand-written decoder |
| S11 | Documentation: containers run in a separate signed runner the app drives; what is left before the library could be linked | S01 to S10 | ~265 doc | low: the text makes claims about the app |
| S-RUN | The authorised real-guest run of a container from the app, after the merge | S01 to S11 merged | — | **owner-authorised only**: starts a real virtual machine |

Sizes are those the cards state.

## Verification

All 11 cards were applied in order, from their text alone, onto a copy of `main` at `6bab9e9`, and each commit was gated
8/8 (`swift run vmr check`: format, swiftlint, docs, workflows, policy, build, test, analyzers; the 8 lines read for every
card, none failed, no known flaky test failed in any run, so no gate was rerun). The commits, in card order, with the size
of the app's own test run in that gate:

| Card | Commit | Gate | `VMRunnerTests` in the gate |
|---|---|---|---|
| S01 | `3694fca` | 8/8 PASS | 908 tests in 151 suites |
| S02 | `fd8d076` | 8/8 PASS | 908 tests in 151 suites |
| S03 | `e5842fd` | 8/8 PASS | 908 tests in 151 suites |
| S04 | `6c099fe` | 8/8 PASS | 922 tests in 153 suites |
| S05 | `8dfe1f7` | 8/8 PASS | 930 tests in 156 suites |
| S06 | `d5eb694` | 8/8 PASS | 972 tests in 163 suites |
| S07 | `3bc9250` | 8/8 PASS | 990 tests in 165 suites |
| S08 | `fb03960` | 8/8 PASS | 1006 tests in 168 suites |
| S09 | `0e47eac` | 8/8 PASS | 1046 tests in 174 suites |
| S10 | `41ed853` | 8/8 PASS | 1055 tests in 176 suites |
| S11 | `dc90829` | 8/8 PASS | 1055 tests in 176 suites |

- The chain was first written against an earlier `main`; the base is now `6bab9e9`, which holds three more commits to the
  machine editor (its grouped form `EditorForm`, a trailing help button on every setting row, and `ValueStepper` for a
  stepper row). Nine cards apply to it as written. Two were adapted to its conventions and nothing else: S08 (the container
  section uses `ValueStepper` for its two steppers) and S09 (the same in the section it replaces, a trailing help button on
  its command, environment, processor and memory rows, and the editor's `Form` and `.formStyle(.grouped)` become
  `EditorForm` in `ConfigEditor`).
- The nested package's own `swift test` passed 44/44 at S01.
- `vmr build-app debug` took 117 s at S03, and `codesign --verify` on the bundle was OK.
- A strict replay (every closing fence on its own line, every `old` text matching whole lines exactly once in the file as the
  previous cards leave it, every `new` text ending on a line boundary) of the 11 cards onto a fresh branch from `6bab9e9`
  reproduces the gated tree exactly.
- The flaky tests named in "Rules for chain S" (the network stack's loopback ping and the TestKit rendezvous test) did not
  fail in this run.

## The interface between the cards (fixed; a change is reported, not made)

- **Runner command line (S01):** `ContainerRunner <scratch-directory> [--network none|loopback] [--image <reference>]
  [--command <argument>]... [--cpus <n>] [--memory <MiB>] [--env <NAME=value>]... [--json]`. Image default
  `docker.io/library/alpine:3.24.2`; each `--command` appends one argument (no shell); CPUs 1 to 16 (default 2); memory
  128 to 16384 MiB (default 512); environment names `[A-Za-z_][A-Za-z0-9_]*`, at most 64 entries, no duplicates; at most
  64 command elements of at most 4096 bytes. Without the new flags the runner behaves as before.
- **Event lines (`--json`):** one JSON object per stdout line, sorted keys, no human report lines on stdout. Members:
  `event`, `time` (seconds since the runner started), and as needed `name`, `seconds`, `stream`, `text`, `status`,
  `message`. Kinds: `phase` (kernel, init-image, pull, create, boot, run), `output` (stdout or stderr, chunks of at most
  16384 bytes), `exited` (the container's status), `error`, `finished` (the runner's own status, the last line).
- **Stop line:** in `--json` mode the runner reads stdin; a line `stop`, or end of input (the app died), stops the container.
  The runner then exits with status **75** if the command had not ended. This is how the app stops a container and how an
  orphaned runner ends.
- **Bundle path:** `VMRunner.app/Contents/Helpers/ContainerRunner`, ad hoc signed with the hardened runtime and
  `Resources/ContainerRunner.entitlements`, signed before the app. The app resolves it from `Bundle.main`; absent (for
  example under `swift run VMRunner`), starting a container machine fails with a clear message and nothing crashes.
- **App side:** `VMConfig.workload` (`vm` by default, or `container`) and `VMConfig.container` (image, command,
  environment as an ordered list, CPUs, memory, network `none` or `loopback`); a stored config without these keys is a
  virtual machine. The scratch folder is `<machine bundle>/container-scratch` (0700). Stop: `stop` line, then after 10 s
  SIGTERM, then SIGKILL after 5 s more; quit stops every runner first. The log is bounded (1 MiB, oldest dropped, with a
  marker) and passes through the console output filter. Control service: `workload` is an added member of a machine's
  answer, `guest` stays `linux`.

## Owner decisions (each card implements the default)

1. **The runner is always embedded in `vmr build-app`.** Cost: about 190 s more for the nested package build, and a debug
   runner of about 79 MB. Escape hatch: `--container-runner PATH` embeds an executable that is already built. Alternative:
   embed only on request.
2. **`vmr container-run` requires `--boot`** (it starts a real virtual machine) and caps the guest at 2 CPUs, 2048 MiB and
   900 s, like `vmr guest`.
3. **A machine's command is one text, tokenized by whitespace and double quotes; no shell.** Alternative: a list editor
   or a shell.
4. **Environment is an ordered list of `NAME=value`.** Alternative: an unordered dictionary.
5. **A container is excluded from the security profiles** (Isolated, Hardened), which describe a virtual machine's
   settings. The security summary says what a container does and does not have.
6. **The managed key `AllowContainers`** lets an organisation forbid containers; unset means allowed.
7. **The scratch folder `container-scratch` is kept** between runs (it is the kernel and image cache) and not removed
   automatically; deleting the machine removes it. Alternative: clear it at each stop.
8. **The control service's `workload` member is additive.** `guest` stays `linux` for a container so a client that
   switches on it keeps working.
9. **The decision is recorded as a new ADR, 0057, that amends ADR-0017**, with a dated note on 0017; the accepted ADR is
   not rewritten.
10. **Containers get no network or `loopback` only**; there is no outside networking and no filtered network.

## What a sonnet pre-dispatch review should read hardest

- **S06**: the process, pipe, `DispatchSource` and backpressure code. Descriptor closing in the parent and at exit, the
  non-blocking stop-line write, the reader's bound on a flood of output, the grace-period kill, and the registry that
  ends every runner.
- **S07**: the `VMController` start branch (every virtual machine passes through the code it changes, and a moved method
  keeps the class under 300 lines) and the quit path (the order of `terminateAll` against `prepareToQuit`).
- **S05**: the wide refactor under the controller. A virtual machine must take the path it took before; the existing
  tests are the proof.
- **S09**: the `Security.swift` edits, the one allowed exception to the never-touch list, and the editor's move to a
  list of sections.
- **S01**: the stop path through stdin (`StopSignal`, `StdinWatcher`) is not exercised by any test or gate step, since it
  needs a real virtual machine. S-RUN is its first check.

## Owner-run list (never dispatched to an agent: it starts a real virtual machine)

`S-RUN.md` is the run, after the merge, by a session the owner has authorised. It writes
`~/Developer/g-cqd/vmrunner-board/realguest-container-report.md`. Record its result in the diary
and roadmap 0024; if the owner accepts it, set the status of ADR-0057.

## Next chain (found while carding; not in this chain)

- The `vmr control list` text line (id, state, guest, name) lacks `workload`; only `--json` and the MCP tool carry it.
- ADR-0056 and roadmap 0005 are not updated for `workload`.
- ADR-0013 (managed preferences) does not list `AllowContainers`.
- The build output of `vmr container-run` goes to standard output.
- The white paper's wording about what the app runs.
- Roadmap 0036 still has a stale sandbox-run line.
- Outside networking for containers (today `none` or `loopback`).
- Management of the image cache (size, listing, removal).
- Linking the container library into the app instead of running a separate runner: after the licence inventory of the 29
  pinned packages it would bring in.
- A test for the container-run signal path (S5 finding of the review): a runner that stays alive, stopped by a signal to the command.
- Log view rendering (S8 finding of the review): the container log view is not rendered in a test; only its text and filters are.
- Other review nits, to collect into one card.
