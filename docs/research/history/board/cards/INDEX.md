# INDEX — Task cards: T7, D1, D2, D3, U6, F10, F15, X5, X6, X7

Base: `main` at `46bdd5f`. Line anchors are for that commit; re-check them if `main` moves (CHECKLIST.md item 1).

Before you dispatch, three facts shape the plan:
- **Build cap.** Two other agents are building in locked worktrees right now (the NetPolicy/NetStack extraction and the console harness). With the cap of three builds, only one chain can start until one of them finishes.
- **The extraction branch overlaps four cards.** It also edits `ChecksumBenchmarks.swift`, `ConfigurationBuilder.swift`, `VMController.swift`, `ControllerRig.swift` and `ci.yml`, so B5 to B9 wait for it to merge.
- **The dead-code gate.** deadwood runs with `"production": true`, so any new production symbol must get a production caller in the same card. That is why some items are merged into one card or carry an explicit acceptance.

Files: COMMON.md (rules every card follows), CHECKLIST.md (pre-dispatch checklist and after-merge steps), REVIEW-A.md, REVIEW-B.md, REVIEW-C.md (review cards), one file per card.

## Chains and dispatch order

| Chain | Worktree | Cards, in order | Conflict notes |
|---|---|---|---|
| C, app UI (roadmap phase 0 first) | `c-app` | C1 → C2 → C3 → C4 → C5 → C6 | none with in-flight branches |
| A, DevTools and CI | `a-devtools` | A1 → A2 → A3 → A4 → A5 → A6 → A7 → A8 | A6, A7, A8 edit `ci.yml` and `CONTRIBUTING.md`, which the extraction branch (`ci.yml` line 64) and both locked worktrees (uncommitted `CONTRIBUTING.md`) also edit, in other hunks. Rebase before A6. A8 runs after C3 has merged. |
| B, engine hashing and start | `b-engine` | B1 → B2 → B3 → B4, then **held** B5 → B6 → B7 → B8 → B9 | B5 to B9 are CONFLICT-RISK: the extraction branch edits `ConfigurationBuilder.swift`, `ChecksumBenchmarks.swift`, `VMController.swift`, `ControllerRig.swift` and `MachineStartTests.swift`. Dispatch B5 only after that branch has merged and WT is rebased. |
| R, research (read-only) | none | F15-3 | does not count as a build |

Dispatch order: C, then A, then B. F15-3 can start at any time.

At most three chains run at once, and the machine-wide cap is three builds **including other agents' builds**. While both locked worktrees are busy, run one chain. Add the next chain each time one of them reports.

Card to board item: A1 U6 · A2 T7 (archive kind, version report, pins) · A3 T7 (gate step) · A4 D1 (tooling) · A5 F15 (analyzer roots) · A6 T7 (CI lint job, docs) · A7 F15 (CI cache) · A8 X6 (docs) · B1-B2 D3 · B3 D1 (app) · B4 D2 · B5 X5 (extraction) · B6-B7 F10 · B8-B9 X5 (adoption) · C1-C4 X6 · C5-C6 X7 · F15-3 F15 (licence inventory).

## Design decision for X6 (preferences, owner-delegated)

`VMRUNNER_DATA_DIR` runs keep the app's settings in the domain `<app identifier>.data-directory-override`, turn off window restoration for both window scenes, and clear the main window's frame autosave name. AppKit keys written outside the app's control (a split view's divider) stay in the standard domain; that limit is documented in A8. A separate bundle identifier for scratch builds would close it and is listed as a follow-up.

## Decisions and departures from the request

- **D2 hex helper (scope reduced):** the two copies live in modules that share no target. Joining them needs a `Package.swift` edit, which the extraction holds. B4 unifies within the app only; the tooling copy waits for the ImageTrust package (board C8).
- **F15 analyzer roots:** this is not a one-line change. The roots are read from `.vmr.json` (A5) rather than hard-coding `Packages/Containers` in generic tooling. A5 stops if the analyzers report findings in the nested package.
- **`zizmor.yml` is kept:** removing it would lose actionlint's shellcheck run on Linux. The gate step turns shellcheck off so local and CI results are the same. The cost is a second actionlint pin inside `zizmor.yml` (follow-up).
- **The `workflows` step is in the default fast gate:** it sits next to swiftlint, which also means a one-time download of about 10 MB per checkout.
- **X7 causes are inferred from the code, not reproduced:** pointer events without a window are dropped by the guard, and drag-loop events bypass local monitors. The owner's re-measurement after C6 confirms them.
- **The deadwood check is an inference:** its configuration says `"production": true`, read as "a symbol used only by tests counts as dead". The archive card was merged into the pins card and B5 has an acceptance that B9 removes; the first gate run confirms or refutes this.
- **F10 compatibility (B7):** a `config.json` naming `sha1`, or any name VMRunner never wrote, now loads instead of failing to decode; fetching its image fails with `SetupError.weakChecksum` before any request. Losing a machine from the library over a field that only matters at download time is worse than refusing the download, and the refusal stays fail-closed.
- **Probe results (2026-10-22):** both archives downloaded, digests match the pins, both binaries sit at the archive root, and both tools report no findings on this repository. With a broken file, zizmor exits 3 alone and 1 with `--strict-collection`; actionlint exits 1. Tag commits checked with `git ls-remote` (both tags lightweight).

## Follow-ups not carded

- **Ephemeral clone:** moving the clone in `VMController.swift:209-211` off the main actor.
- **Rest of board F10:** migrating old flat-cache machines and cloning the restore image.
- **Scratch-build bundle identifier:** a separate one for scratch builds would also isolate AppKit's own autosaved keys.
- **Licence findings:** acting on whatever F15-3 reports.
- **Second actionlint pin:** removing it from `zizmor.yml` once shellcheck is pinned another way.
