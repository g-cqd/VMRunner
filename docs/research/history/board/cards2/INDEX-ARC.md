# INDEX-ARC — arcleak rules lane (cards ARC01-ARC10)

Repository: `WT = ~/Developer/g-cqd/arcleak-lane`, a clone of the public arcleak repository, `main` at `5c234f3` (version 0.10.2, Swift 6.4, swift-syntax 604). All cards run on one branch, `lane/rules`, created from `main` by ARC01. Each card is one atomic commit that builds and passes the gate on its own; the integrator exports them with `git format-patch 5c234f3..lane/rules` and the owner applies them with `git am`. Nothing in any card depends on a file outside the repository.

Every card was produced by implementing the change on a copy of the clone (`/tmp/arc-orch`), passing the gate there, and generating the card's Find/Replace pairs from that commit's diff (each Find text checked to occur exactly once in the parent file, and the pairs checked to reproduce the commit). The ten cards were then replayed mechanically from their markdown on a fresh branch from `5c234f3`: every edit applied, every command run, every commit command run; each replayed tree matched the verified commit (see "Replay" below).

## Order and dependencies

Strictly sequential: every card edits files the previous card changed (`RuleID.swift`, `FactsExtraction.swift`, `README.md`, `OptInRulesTests.swift`), and the Find texts assume the previous card's text. Dispatch one at a time, in this order.

| card | commit subject | scope (task item) | depends on | tests after |
|---|---|---|---|---|
| ARC01 | feat: flag closures stored on a child self owns | (1) owned-child extension of `stored-closure-strong-self` | `main` 5c234f3 | 190 tests / 40 suites |
| ARC02 | feat: add webview-script-handler-cycle | (2) new default rule | ARC01 | 190 / 40 |
| ARC03 | feat: extend combine-sink-self-cycle to Rx and SwiftSignalKit subscriptions | (3) `disposeBag`, `signalDisposable` templates | ARC02 | 193 / 41 |
| ARC04 | feat: flag stored tasks cancelled only in deinit | (4) `task-nonterminating-self` deinit-only cancel | ARC03 | 193 / 41 |
| ARC05 | feat: add kvo-observation-self-cycle | (5) new default rule | ARC04 | 193 / 41 |
| ARC06 | feat: add the opt-in sec-cleanup-in-unreachable-deinit rule | (6) security pack, rule 1 | ARC05 | 195 / 41 |
| ARC07 | feat: add the opt-in sec-session-in-cycle tag | (6) security pack, rule 2 | ARC06 | 196 / 41 |
| ARC08 | feat: tag the security rules in SARIF output | (6) SARIF `properties.tags` | ARC07 | 196 / 41 |
| ARC09 | test: pin delegate-strong-property on the delegate shapes of public fixes | (7) | ARC08 | 197 / 41 |
| ARC10 | test: record four more known false negatives | (8) KnownGaps 5-8 | ARC09 | 197 / 41 |

Item (8) fixtures, README rows and `RuleID` texts ship inside the card of the rule they document (ARC01-ARC08), so each commit is complete on its own. No card bumps the version or touches `Benchmarks/`.

## Verified commands (macOS, Xcode toolchain, Swift 6.4, on the copy)

| command | result | time (incremental, after one card's edits) |
|---|---|---|
| `swift build --build-tests` | `Build complete!`, no warnings (warnings are errors in this package) | 3-8 s (clean build of the baseline: 49.7 s, from `/tmp/arc-baseline-build.log`) |
| `swift test --no-parallel` | `Test run with N tests in M suites passed` | 9 s |
| `swift run arcleak analyze Sources --strict --no-cache` | `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 79-82 file(s); 9 suppressed` | 3 s |
| `Scripts/lint-format.sh` | no output, exit 0 | under 1 s |
| `Scripts/no-gcd.sh` | `no-gcd: implementation is GCD-free` | under 1 s |
| `Scripts/ci-local.sh` (whole gate) | `== all gates green`; includes the runtime oracle (19 scenarios ok) and the LSP smoke test, both of which work here (python3 present) | 36-38 s |

All five sub-commands and the whole `Scripts/ci-local.sh` work in this environment. A global git pre-commit hook runs swift-format on the staged files and printed `[OK] pre-commit checks completed successfully.` for every commit.

## Replay

The ten cards' markdown was parsed and applied in order on a branch from `5c234f3` in the orchestrator's copy, exactly as an executor would (Find/Replace with exact-once checks, new files written verbatim), and every command of every card was run, including the card's own commit command. Results: every edit applied; build without warnings; test counts 190, 190, 193, 193, 193, 195, 196, 196, 197, 197 (all passed); self-dogfood 0 findings each time; lint and no-gcd clean; every probe output as stated in the cards; `Scripts/ci-local.sh` green at ARC10; the pre-commit hook passed on all ten commits; `git status` empty after each commit. Each replayed commit's tree is identical to the verified commit, except ARC10's `Clean/KnownGaps.swift`, which ends without a final newline after the card's edit (the verified commit had one); this is harmless (fixtures are not format-linted, the fixture tests passed).

## Decisions made by the orchestrator (the pre-dispatch reviewer should confirm them)

1. Owned-child path (ARC01) reports `warning` (capped by the configured severity), not the rule's default `error`: a child may clear its callback after firing. Children of unknown type (SDK, other files) count as owned; only a struct or enum declared in the same file is exempt, as the task says ("exempt when known"). A struct child stored inline in a class is arguably a real cycle too; it is exempt by instruction.
2. `webview-script-handler-cycle` (ARC02) also matches `addScriptMessageHandler(_:contentWorld:name:)` (the reply-handler API; the firefox-ios fix was on the Swift 2 spelling `addScriptMessageHandler(self, name:)`), and any receiver whose last name ends in `ContentController` (a local `let contentController = …` or `userContentController`). Apple's documentation (apple-docs: `webkit/wkusercontentcontroller/add(_:name:)`, `add(_:contentworld:name:)`, `wkusercontentcontroller`, `wkscriptmessagehandler`) never states the retention; the rule text says "observed behaviour" and cites firefox-ios@4d83f60171 and element-x-ios@f8d094516d, whose diffs were read with `gh api` (both replace `self` with a weak proxy).
3. Reactive templates (ARC03) are built in (active with no configuration) for `subscribe`, `bind`, `drive` (+ `.disposed(by:)`/`addDisposableTo(_:)` into a member of self, or assignment to a member) and `start(next:)` (+ `.set(_:)`/`.add(_:)` on a member, or assignment); a fact is produced only when the Disposable lands on self, and `producesLifetimeToken` is false (a dropped Rx/SignalKit Disposable does not end the subscription). Findings are warnings (completion unknown). Finite markers are read from the receiver's tokens (`Single`, `Completable`, `Maybe`, `asSingle`, `asCompletable`, `asMaybe`, `just`, `empty`, `first`, `take ( 1 )`) plus `subscribe(onSuccess:)`. ReactiveSwift `observeValues` is not covered (not in the task's scope list).
4. Stored Task deinit-only cancel (ARC04): the new finite path reports at the configured severity (warning by default). The task said "keep the severity rules of the existing rule"; the existing error tier (handle stored on self) is kept for the non-terminating paths only, because a finite await is not a definite leak. If the owner wants `error` there, change one line in `TaskNonterminatingSelfRule.check` (`severity: configuration.severity(for: .taskNonterminatingSelf)` to `.error`) and the README row.
5. `kvo-observation-self-cycle` (ARC05) accepts any member of self as the observed object (`memberOfSelfName`, which includes computed properties), not only stored properties.
6. Security pack (ARC06-ARC08): no new configuration key, no CLI flag; both ids are `enabledByDefault = false`, default severity `note`. `sec-cleanup-in-unreachable-deinit` is a separate note finding anchored on the first cycle finding of the type. `sec-session-in-cycle` is implemented as an extra note line on the existing cycle findings (no finding of its own), via the existing `Finding.adding(note:)`; the note is outside the fingerprint, so baselines keep matching. Both cover only the cycles reported per type (`SecurityPack.keepsSelfAlive`: stored-closure, sink, assign, dispatch-source, task, timer, notification, URLSession, web view, KVO); `mutual-strong-properties` cycles are not linked (documented in the explanations). SARIF tags are included (small change): `["security","CWE-401","CWE-226"]` and `["security","CWE-401"]`.
7. KnownGaps gap 8 (ARC10) uses an `onTermination` handler set on the AsyncStream build closure's parameter: the literal REPORT shape (a strong-self consumer Task with `for await`) is already caught by `task-nonterminating-self`, so the entry says so and uses `[weak self]` for the consumer. Gap 9 is not added: ARC03 closes it.

## Risks

- Find texts are exact and assume the previous card applied verbatim; if a card is skipped or edited, later Find texts can fail (the cards then stop, by their stop conditions).
- Every finding line number in the probes and tests is exact; a fixture typed with one extra or missing line shifts them (the fixture runner compares lines exactly), which surfaces as a test failure, not silently.
- Default-on changes (ARC01, ARC02, ARC03, ARC04, ARC05) can raise new findings on user code: owned-child closures, Rx `subscribe` + `disposed(by:)`, stored awaiting Tasks with deinit-only cancel. All are warnings, not errors (except a deinit-only script-handler removal, which follows the notification rule's error). No FP measurement on real code was run in this lane (REPORT follow-up 2).
- The facts schema changes (`StoredClosureFact.ownedChild`, `TaskSpawnFact.bodyAwaits`, new `APICallFact.Kind` and `ReleaseSite.Kind` cases). The facts cache is keyed on the build identity, so a new build never reads an old cache; no cache version bump is needed (verified: `CacheTests` pass).
- Commit messages avoid apostrophes, double quotes, backticks, `$`, `!` and backslashes, so they survive `bash -c '... -m "..."'`.
- Other lanes share `cards2/` (D*, E* cards); this lane only adds `ARC*.md`, `INDEX-ARC.md`, `CHECKLIST-ARC.md`.
