# INDEX-F — Chain F: follow-ups of the chain D and chain E reviews

Base: `main` at `a98fd14` (after chains A to E). Every anchor of every card was read on that commit; a later card anchors
on text the earlier cards leave untouched unless it says otherwise. Locate by text, never by line number.

Files: COMMON.md (in `../cards/`, rules every card follows), this index, CHECKLIST-F.md (what the sonnet reviewer checks
before dispatch), F01.md to F12.md (one card each, one commit each).

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/f-followups -b chain/f-followups main
```
`WT = ~/Developer/g-cqd/VMRunner-chains/f-followups`. One chain, cards strictly in order, one build
at a time (the gate takes 3 to 10 minutes). Every card leaves the branch green with `swift run vmr check`.

## How to read the code blocks of a card

Most blocks start at the left margin. A fenced block nested in a list item is indented by the list's indentation: remove
exactly the indentation of the block's opening fence (the line that starts with three backticks) from every line of the
block; what remains is the text to write, with its own indentation. A quoted single line in backticks (an `old` or `new`
line) is written with its leading spaces as shown. The base for every `old` text is the file as the previous cards left it
after `swift-format`.

## Rules for chain F (they override COMMON where they differ)

- **Base and never-touch list.** COMMON's base `73bceb0` reads `a98fd14` here. COMMON's "Never touch" list holds, with these
  exceptions, only for the files and lines each card names:
  - `Sources/NetStack/ResolverWorkers.swift`, `Sources/NetStack/SystemNameResolver.swift` (F02);
  - `Sources/NetPolicy/PolicyGate.swift`, `Sources/NetStack/UserNetCore+Control.swift` (F03; `derivedBlocks` becomes
    `package`, one keyword, and gets a finite lifetime);
  - `Sources/NetStack/UserNetCore+DNS.swift`, `Sources/NetStack/UserNetStats.swift` (F06: comments only).
  `Sources/VMRunner/Model/Security.swift` stays untouched (F11 changes a string it reads, not the file). `VMController.swift`
  stays untouched: its class body is at the `type_body_length` limit (INDEX-E); F07 reaches the stop path through
  `discardEphemeral()`, which `VMController.release()` already calls.
- **INDEX-E decision 11 is overridden** by the owner (2026-10-22): a forced `MaxRuntimeMinutes` of 0 means no limit (F01).
- **No network, no guest.** No card fetches anything or starts a virtual machine. The owner runs below are never dispatched
  to haiku.
- **Suite-name `UserDefaults`** in tests are cleaned with `suite.removePersistentDomain(forName:)` (already so on `main`; no
  card adds one).
- **No board or card identifier** (`X17`, `F08`, `D13`...) in the repository: not in code, comments, docs or the diary.

## Order and dependencies

| Card | Review item | What | Needs (committed) | Size (lines) |
|---|---|---|---|---|
| F01 | owner decision | A forced `MaxRuntimeMinutes` of 0 means no limit; help, roadmap 0013, a dated note in ADR-0013 (stays proposed) | — | ~45 |
| F02 | X17 | Queued lookups carry a deadline (the proxy's 5 s timeout); a late one answers SERVFAIL without running | F01 (order only) | ~75 |
| F03 | X18 | Derived address blocks live 12 h (oldest goes first past 1,024), pruned with the name table | F02 (order only) | ~40 |
| F04 | X19 | Sweep leftover `.install-*` clones of the image cache at launch | F03 (order only) | ~60 |
| F05 | X20 | `GateLock.release(_:)` and its test; dead loop gone and near-miss hosts; `accepted > 500`; expiry tripwire comment | F04 (order only) | ~45 |
| F06 | X20 | ADR-0031 "approved too" and the sweep; DNS-over-TCP reset comments | F04 | ~15 |
| F07 | X21 | `freshHostInfoFolder()` requires an empty folder; `discardEphemeral()` removes `HostInfo` at stop | F06 (order only) | ~35 |
| F08 | X22 | Kill switch reads the card back; a cut that did not take stops the machine; help; roadmap 0010 "Owed" | F07 (order only) | ~90 |
| F09 | X23 | Saved state dropped on a change of disk interface, disk serial, or host information on/off | F08 (order only) | ~40 |
| F10 | X24 | Lock row only when locked (`@ViewBuilder`); serial filter keeps `!` to `~` | F09 (order only) | ~40 |
| F11 | X24 | Exposure text names Low Power Mode; installer gets no host-information share; diary 05 count | F07 (same test file) | ~15 |
| F12 | all | Roadmap 0011, 0012, 0013 ("Owed"), 0034, 0036 rows F and G; the diary entry | F01 to F11 | ~70 docs |

Dispatch order: F01 to F12. Cards marked "order only" do not use an earlier card's text and may be reordered if one is held;
F12 then checks the commit count (`git rev-list --count main..HEAD` must be 11) and stops otherwise, so the integrator edits
its first sentence ("Twelve commits") and that check if a card is dropped.

F08 is the largest (about 90 lines): a protocol, a value type, its only production caller, the help paragraph, the roadmap
note and three tests. It is not split because the type with no caller would fail the dead-code gate (production mode).

## Owner decisions (each card states the default it implements)

1. **`MaxRuntimeMinutes` 0 (F01): decided by the owner.** 0 means no limit, the control stays unlocked. Implemented details
   the owner may want to confirm: a forced Boolean `false` (which the system reports as a number 0) still becomes 15; a forced
   `<real>0</real>` also means no limit; 1 to 14, negative values, more than 1440 and strings become 15.
2. **Kill switch when a cut does not take (F08): pending, default "stop the machine".** Alternative: keep it running and
   only show an error. Recorded in roadmap 0010 "Owed" and in the help.
3. **Where to sweep install clones (F04): launch**, chosen here: at launch no setup of the app can be running; at the start of
   a setup another setup may be reading its own clone. Say so if the start of a setup is preferred.
4. **Derived block lifetime (F03): 12 hours** after the proxy last gave the address. Before, the entry lived as long as the
   network stack; now a port rule for a name lapses for an address 12 hours after the guest last resolved it.
5. **Not carded, left to the owner:** whether a clamp the library persisted is undone when a policy is lifted; accepting
   ADR-0013; the in-guest VPN probe (needs an ADR). Recorded in F12 (roadmap 0013 "Owed" and the diary).

## Work that needs a real guest or real hardware (owner runs; never haiku)

| Run | After | What to observe |
|---|---|---|
| O1 | F01, F10 | A real configuration profile forcing `MaxRuntimeMinutes` to 0, to 60 and to `false`: no lock and no clamp for 0, 60 locked, `false` locked at 15; the layout of every locked and unlocked row in the editor and in Settings (the lock row is now added only when locked) |
| O2 | F08 | The owed kill-switch run of roadmap 0010 (R1 of INDEX-E), plus: whether the framework ever keeps the attachment (the new log line `The network card stayed connected after the kill switch cut it`), and whether the attachment can be taken off before the machine starts |
| O3 | F04 | A macOS install from the catalog killed mid-install (force quit), then a relaunch: no `.install-*` file is left in `Images/<sha256>/`. Optional: a data directory on a non-APFS volume, where the install now fails with the clone error |
| O4 | F07, F09 | A Linux guest with host information on: after stop, no `HostInfo` folder in the bundle; start again and the share still mounts. Suspend, turn host information off, start: a cold boot without a restore error |
| O5 | F02 | Optional: a guest that floods lookups to a name whose server drops queries; other lookups keep being answered |

## Cards to read twice (the orchestrator is not certain)

- F01: `guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(), let minutes = value as? Int else {`. Checked in a scratch
  program outside the repository (Swift 6, strict memory safety, warnings as errors): a `UserDefaults` value written as
  `false` gives 15, `0` and `0.0` give nil, `60` gives 60; Swift `false`, `true`, `-5`, `2000`, `"0"` give 15. Not checked
  with the package's own flag set, nor with a real profile (O1). Reviewed: compiled in the package under its flags, and
  checked with values read back through `UserDefaults.object(forKey:)` (Boolean `false` gives 15, number 0 and 0.0 give nil).
- F02: the test blocks the single worker with `release.wait()` on a `DispatchSemaphore` inside a synchronous `@Sendable`
  closure of an `async` test. Reviewed: the card's test compiles and passes in a copy of the package, and fails when the
  deadline check is removed. The whole `ResolverWorkers` design and that sequence ran in a scratch program and printed
  `["first ran", "waited late", "fresh ran"]`; the test itself (with TestKit's `TestClock` and `AsyncEventProbe`) was not run.
- F04: the review text said clones are "directly in the images directory". Read from the code they are made **beside the
  cached file**, so in `Images/<sha256>/` (or directly in `Images` for an old flat-cache file): the sweep looks in `Images`
  and one level down. Its logic ran against the planted files of the test in a scratch program (all seven checks true).
- F05: `#expect(accepted > 500, ...)`: 1,171 comes from a replica of the test's loop (same generator, seed, mutation and
  `decodeName`), compiled and run outside the repository, not from the test itself.
- F07: `#expect(throws: AppPaths.UnsafeDirectory.self) { try bundle.freshHostInfoFolder() }` relies on mode 0555 stopping
  the removal, which does not hold when the tests run as root; reviewed: the test carries `.disabled(if: geteuid() == 0, ...)`.
- F08: `extension VZNetworkDevice: NetworkCard {}` with a `@MainActor` protocol, and the `Task { [weak self, machine] in ... }`,
  type-checked in a scratch file with the package's upcoming features (not inside the module).
- F03: the second test resolves a name again after advancing the virtual clock by 12 hours and a minute; the resolve helper
  was not run after such a jump.
- F12: the diary's first line and name come from `date` and `ls` when the card runs; its first sentence assumes all twelve
  cards were applied.

## Card to review item

F01 owner decision on `MaxRuntimeMinutes` · F02 X17 · F03 X18 · F04 X19 · F05, F06 X20 · F07 X21 · F08 X22 · F09 X23 ·
F10, F11 X24 · F12 all. (These identifiers belong to the board only; none is written in the repository.)

## After each card and after the chain

As in `../cards/CHECKLIST.md`, "After each merge". The worktree stays until F12 has merged.

## Second batch (G01 to G04): defects found by the real-guest run of 2026-10-22

Source: `../realguest-report.md` (authorised run on `main` at `a98fd14`). Four cards, one commit each, on the same branch
and worktree, **after F11 and before F12**. Dispatch order: **F01 to F11, G01, G02, G03, G04, F12**. F12 was patched for
it: it now checks `git rev-list --count main..HEAD` = **15**, says "Sixteen commits", adds a diary row per G card, a section
on the real-guest run (observed and not observed), and notes in roadmaps 0005, 0010 (appended after F08's paragraphs), 0011
and 0012 ("Owed"), 0013 and 0034 (item 3).

| Card | Report item | What | Needs (committed) | Size (lines) |
|---|---|---|---|---|
| G01 | defect 1 (R2) | Host-information files rewritten in place (truncate, one write), created with `.withoutOverwriting`; help and roadmap 0011 say to read again a file empty or missing for a moment | F11 (order only) | ~45 |
| G02 | defect 3 (R1) | `NetworkCutoff.logLine(from:to:)` and a public `Log.machine.notice` in `apply` for every cut, reconnection and change of reason; `setNetworkConnected`'s doc says the delegate's attachment-disconnected callback is not implemented | **F08** (its imports and doc comment) | ~30 |
| G03 | defect 2 | Docs only: the catalog's Alpine ISO boots with `console=ttyAMA0`; help topic, a dated note in ADR-0052 (stays accepted), the automation study | G02 (order only) | ~25 |
| G04 | defect 4 | `Tests/VMRunnerTests/ScratchDefaults.swift`: a suite named by an absolute path in a scratch folder; used in the five test files | G03 (order only) | ~70 |

Rule change: the chain-F rule "Suite-name `UserDefaults` in tests are cleaned with `removePersistentDomain`" is replaced
from G04 on: tests use `ScratchDefaults` (no `UserDefaults(suiteName:)` elsewhere in `Tests/`). Reason, measured by the
orchestrator outside the repository: removing the domain, synchronizing and deleting `~/Library/Preferences/<name>.plist`
(five orders, 30 suites each) left no file 1 to 2 s later but all of them 20 s later, rewritten by the preferences daemon;
a suite whose name is an absolute path writes `<path>.plist` there instead, and a deleted folder is not recreated.

Checks the orchestrator ran: G01 to G04 (with F08's source steps applied first) in a scratch copy of `main`: `swift run vmr
check` exit 0, all steps `PASS`; the new tests 15 times in a row, all passed; `vmr check docs` with G03's and F12's new
roadmap text, `PASS`. Not run there: F01 to F07 and F09 to F11, and F12's diary.

New suites and counts for the reviewer: `HostInfoPublisherTests` 3 after G01; `NetworkCutoffWatchTests` 3 after G02;
`SerialConsoleTests` 12 (unchanged count) after G03; `ScratchDefaultsTests` 1 (new in G04). New production declarations
and their callers (deadwood): `HostInfoPublisher.overwrite(_:with:)` (`publish`), `NetworkCutoff.logLine(from:to:)` (`apply`).

Owner runs added (never haiku):

| Run | After | What to observe |
|---|---|---|
| O6 | G01 | The guest loop of the report (read `battery` every 0.1 s across a rewrite): no `No such file or directory`; an empty read is allowed |
| O7 | G02 | `log stream --predicate 'category == "machine"'` while a machine with a VPN rule starts: one line `Kill switch: cutting the network card (...)`, and `reconnecting` when the rule holds again |

Cards to read twice (second batch):

- G01: `try handle.truncate(atOffset: 0)` then `try handle.write(contentsOf: data)`: a reader can see an empty file between
  the two calls (the brief accepts it). Whether virtio-fs in the guest then shows the new content at once or after its own
  cache times out is not known: O6 checks it. An existing name that is a link is followed by `FileHandle(forWritingTo:)`; the
  folder is private and emptied at each start (F07), so only this user could plant one.
- G02: `case (let was?, let now?) where was != now:` in a `switch` expression; compiled and tested in the scratch copy.
- G03: the help's "In that second press an arrow key in the machine's window, then `e`, ... and press Ctrl-X" is standard
  GRUB behaviour, not tried on this ISO in the app. "An installed system that runs systemd may start one on `hvc0` ...
  through its getty generator" (study only) is from memory of systemd's documentation, marked as not tried.
- G04: the stray-file behaviour above was measured on this Mac (Darwin 25.6.0), not documented by Apple; that a
  suite name may be an absolute path is long-standing Core Foundation behaviour, also undocumented for `UserDefaults`.
