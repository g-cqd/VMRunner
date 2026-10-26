# CHECKLIST-ARC — what the sonnet pre-dispatch reviewer verifies on ARC01-ARC10

Apply to each card before dispatching it, in order. `WT=~/Developer/g-cqd/arcleak-lane`. Run read-only commands only; do not build in WT while an executor is working in it.

## Before the first card

1. `git -C WT log -1 --format=%h main` prints `5c234f3`, and `git -C WT status --short` is empty. If `main` moved, every Find text of every card must be re-checked against the new `main` (step 4) before dispatch.
2. `/tmp/arc-baseline-build.log` ends with `BUILD_EXIT=0` (the baseline build that was running when the cards were written has finished), and no other build is running in WT.
3. `ls WT/Benchmarks` exists and no card names a path under it; no card edits `Package.swift`, `Package.resolved`, `ToolInfo.swift` or any version string.

## Per card

4. Anchors: for each `### Edit` of the card, the Find text occurs exactly once in the file at WT's current HEAD (after the previous card's commit). A quick check: pick the most specific line of each Find block and `grep -c -F` it in the file (expect `1`), or run `python3 -I` with a read of the file and `str.count`. For `### New file`, the path does not exist yet.
5. Previous card landed: `git -C WT log --oneline -1` shows the previous card's subject (ARC01: `main` at `5c234f3`, and branch `lane/rules` absent or equal to `main`).
6. Symbols the card names exist at HEAD: `grep -n` for the function or type named in its Files list (e.g. `func recordAppendedClosureIfAny`, `struct SinkWrapperContractTests`, `func sarifOutputIsValidAndComplete`, `enum SecurityPack` from ARC07 on).
7. Expected outputs are concrete and match INDEX-ARC: test count and suite count (190/40, 190/40, 193/41, 193/41, 193/41, 195/41, 196/41, 196/41, 197/41, 197/41), dogfood file count (79, 80, 80, 80, 81, 82, 82, 82, 82, 82) and `9 suppressed`, probe finding counts and line numbers.
8. The `git add` list of the Commit block equals the card's Files list (new and modified), and the message contains none of `'`, `"`, backtick, `$`, `!`, backslash. Subject is lowercase conventional (`feat:` or `test:`), imperative, no trailing period; body says why and gives the test count.
9. Privacy: the card (code, comments, fixtures, README text, commit message) cites only public upstream commits (`firefox-ios@4d83f60171`, `element-x-ios@f8d094516d`, `wikipedia-ios@9db7aa718d`) and public documentation (Apple: `WKUserContentController.add(_:name:)` page, which does NOT state retention, and `NSKeyValueObservation.invalidate()`); it names none of the owner's apps or repositories, no research row ids (`T1-`, `T3/`, `P1`…`P16` pattern ids), no private commit text, and nothing from `arcleak-research/`. `grep -n -i -E "T1-1|rows/|REPORT|Luce|Kyklos|LotoBuddy|Stations|owner app|arcleak-research" cards2/ARCnn.md` must find nothing (verified empty for all ten cards when they were written).
10. Opt-in discipline (ARC06-ARC08): new rule ids have `enabledByDefault` false, default severity `.note`, and are enabled only through `rules.<id>.enabled`; no new `Configuration` key, no new CLI option (`grep -n "@Option\|@Flag" Sources/arcleak/ArcLeakCommand.swift` unchanged by the card).
11. The card's stop conditions say to stop and report on any mismatch; no step asks the executor to choose or fix.
12. Model haiku, effort low; the "Rules for this lane" block is present at the end of the card.

## Decisions to confirm with the owner before dispatch (see INDEX-ARC "Decisions")

13. ARC04: finite stored Task with deinit-only cancel reports `warning` (configured severity), not `error`.
14. ARC01: struct children declared in the same file are exempt (by instruction), unknown-type children count.
15. ARC03: the reactive templates are active by default (built in) for `subscribe`/`bind`/`drive`/`start(next:)`.
16. ARC07: `sec-session-in-cycle` is a note line on existing findings, not a finding of its own.

## After the last card (integrator)

17. `git -C WT log --oneline 5c234f3..lane/rules` lists exactly the ten subjects of INDEX-ARC in order; `Scripts/ci-local.sh` passes on the tip (`== all gates green`); then `git -C WT format-patch 5c234f3..lane/rules -o <dir>` produces ten patches.
