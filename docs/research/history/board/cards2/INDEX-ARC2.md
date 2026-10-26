# INDEX-ARC2 — arcleak rules lane, review fixes (cards ARC11-ARC18)

Repository: `WT = ~/Developer/g-cqd/arcleak-lane`, branch `lane/rules` at `005f65f` (ARC01-ARC10 on top of public `main` 5c234f3; Swift 6.4). A review of ARC01-ARC10 found two blocking issues and several smaller ones. These eight cards fix them with follow-up commits on top of `lane/rules`. No history is rewritten: each card adds one commit that builds and passes the gate on its own. The integrator still exports with `git format-patch 5c234f3..lane/rules`.

Every card was produced the same way. The change was implemented on a copy of the clone (`/tmp/arc-orch2`, branch `orch` from `lane/rules`) from a spec of Find/Replace pairs. Each Find text was checked to occur exactly once in the parent file, built and passed the gate there, and was committed with the card's own commit command. The card markdown was rendered from that same spec, so its code blocks are the code that compiled and passed. Then all eight cards were replayed from the markdown alone, on a fresh branch `replay` from `lane/rules` in the same copy: edits parsed out of the markdown, every command of every card run, every commit command run (see "Replay"). The copy was deleted afterwards.

## Order and dependencies

Strictly sequential. Several cards edit the same files (`RuleID.swift`, `FactsExtraction.swift`, `README.md`, `KnownGaps.swift`), and each card's Find texts assume the previous card's text. Dispatch one at a time, in this order.

| card | commit subject | review item | depends on | tests after |
|---|---|---|---|---|
| ARC11 | fix: require an owned web view for the deinit-only script handler error | (B) blocking 2 | ARC10 (005f65f) | 198 tests / 41 suites |
| ARC12 | fix: flag KVO self cycles on any observed object | (C), findings 3 and 4 | ARC11 | 198 / 41 |
| ARC13 | fix: flag closures stored on a struct child of self | (D), finding 3 | ARC12 | 198 / 41 |
| ARC14 | fix: require a dispose bag for the built-in subscribe, bind and drive | (E), finding 5b | ARC13 | 199 / 41 |
| ARC15 | docs: scope the runtime-proof claim and the security pack wording | (A) blocking 1, (F) finding 7, (G) findings 6 and 9 | ARC14 | 199 / 41 |
| ARC16 | refactor: skip contract matching for callees no contract names | (H), finding 8 | ARC15 | 199 / 41 |
| ARC17 | fix: add the external/cwe tag form to the SARIF security tags | (I) SARIF tags, `securityTags` internal | ARC16 | 199 / 41 |
| ARC18 | refactor: reflow the script handler docs and order the rule summaries | (I) doc reflow, summary order | ARC17 | 199 / 41 |

Baseline before ARC11 (measured on the copy at 005f65f): 197 tests in 41 suites pass. No card bumps the version or touches `Benchmarks/`, `Scripts/`, `.github/`, `Package.*`.

## Verified commands (macOS, Xcode toolchain, Swift 6.4, on the copy)

| command | result | time on the copy |
|---|---|---|
| `swift build --build-tests` | `Build complete!`, 0 `warning:`/`error:` lines | 8-24 s incremental per card (the first build of the copy took 167 s, a full rebuild because `.build` was copied from another path; it printed `Stale file … outside of the allowed root paths` warnings that only a copied `.build` produces, and none after) |
| `swift test --no-parallel` | `Test run with N tests in 41 suites passed` (N = 198 after ARC11-ARC13, 199 after ARC14-ARC18) | 9-29 s |
| `swift run arcleak analyze Sources --strict --no-cache` | `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed`, exit 0 | 3-13 s |
| `Scripts/lint-format.sh` | no output, exit 0 | under 2 s |
| `Scripts/no-gcd.sh` | `no-gcd: implementation is GCD-free` | under 1 s |
| `Scripts/ci-local.sh` (whole gate) | log ends with `== all gates green`, exit 0; the runtime oracle printed 19 `ok` lines | 129 s for the first card, then 80, 55, 37, 46, 35, 35, 33 s |

The global pre-commit hook ran swift-format on the staged files and printed `[OK] pre-commit checks completed successfully.` for every commit, on both the verified and the replayed branch.

## Decisions made by the orchestrator (the pre-dispatch reviewer should confirm them)

1. **ARC11 (B): a deinit-only removal is silent, not a warning, when the type keeps no web view.** The brief asks for `error` only with ownership and a warning cap otherwise. It also asks for the reviewer's counterexample (weak controller, removal in deinit) as a **Clean** fixture, and the fixture runner requires zero findings for Clean files. Both hold only if the counterexample is silent. That is also the right answer: such a handler is not in a cycle, and its deinit runs once the web view is gone. So: owner and deinit-only gives `error`; owner and no removal gives the configured severity (warning); no owner and no removal gives `min(configured, warning)` with the message starting `observed:`; no owner and deinit-only removal is silent. "Owns" means a strong stored property whose declared or initializer-inferred type name is `WKWebViewConfiguration`, `WKUserContentController`, or ends in `WebView` (so a `WKWebView` subclass named `…WebView` counts). A web view reached through a superclass, a computed property or a differently named subclass is not seen: the deinit-only shape is then silent, a false negative. The reviewer's literal counterexample registers through a parameter named `c`, which the extraction never matched (the receiver must be named `…ContentController`). The fixture and test therefore name the parameter `contentController`, so the case exercises the rule.
2. **ARC12 (C): a reachable `invalidate()` silences the KVO rule, as instructed, but `invalidate()` alone does not break the cycle.** In the open-source overlay (apple/swift@d6b4691dc8, `stdlib/public/Darwin/Foundation/NSObject.swift`), `NSKeyValueObservation` keeps `let helper` and the helper keeps `let callback`. `invalidate()` removes the observer and the association but releases neither, so self → observation → helper → handler → self stays until the observation is released (current SDKs are closed source; not re-checked there). Consequences in the card: the note says to "invalidate() and release (set to nil)"; the Clean twin invalidates *and* sets the observation to nil; KnownGaps gains gap 9 (invalidate-only, a real leak asserted silent). Like the timer rule, any reachable `.invalidate()` in the type silences it, including a timer's. If the owner prefers precision here, the alternative is to require `observation = nil` on a reachable path. That needs a new release-site kind and is not in this lane.
3. **ARC12: the observed-object facts are removed, not just ignored.** `targetIsSelf`/`receiverIsSelfMember` are no longer set for `observe(\.keyPath)`; no other rule read them for that kind (checked with `grep -rn "targetIsSelf\|receiverIsSelfMember" Sources/ArcLeakCore/Rules`).
4. **ARC13 (D): any strong stored property counts as an owned child, whatever its type.** The helper no longer reads `memberTable`; it became `static func isOwnedChild`. Enums cannot hold assignable stored members, so the dropped enum exemption changes nothing in practice.
5. **ARC14 (E): the rule is per template, not per callee name.** A `disposeBag` contract, built in (`subscribe`, `bind`, `drive`) or user-declared, now counts only `.disposed(by: <member of self>)` / `addDisposableTo(<member of self>)`. The assignment path and the `.set`/`.add`-into-a-member path are gone for that template, so the template means one thing everywhere. `signalDisposable` (`start(next:)`) keeps assignment, `.set` and `.add`. The Rx shape `subscription = subject.subscribe(onNext: { self… })` is a real cycle that is now silent; it leaves the Leaks fixture and becomes KnownGaps gap 10. The test count goes to 199 (one new `ReactiveContractTests` case).
6. **ARC15 groups (A), (F) and (G) under `docs:`,** although (F) changes one user-visible message string ("may keep … alive, so that cleanup may never run"), because the change is wording. The README now names the oracle's coverage (from `Sources/leak-oracle/OracleScenarios.swift`: stored and lazy closures, Combine sink and assign, mutual strong properties, dispatch sources, timers, notification observers, URLSession delegates, tasks). The claim that `@al:disable` has no effect on `sec-session-in-cycle` was verified on the copy: with the tag enabled and `// @al:disable sec-session-in-cycle` above the type, the finding still carries the tag note and nothing is suppressed. The sentence also went into the rule's explanation.
7. **ARC16 (H) uses `refactor:`**, since the repository's history has no `perf:` commits. The early return covers a callee that no built-in name and no user contract names. With no user contracts this is the old `guard !userContracts.isEmpty` plus one set lookup.
8. **ARC17 (I): both CWE tag forms are kept.** GitHub's "SARIF support for code scanning" page (docs.github.com, fetched with GET) describes `properties.tags` as filter strings, gives `security` as an example, and does not mention a CWE form. `external/cwe/cwe-N` is the CodeQL query-metadata convention, from the orchestrator's knowledge; it was not fetched. Tags: `["security", "external/cwe/cwe-401", "external/cwe/cwe-226", "CWE-401", "CWE-226"]` and `["security", "external/cwe/cwe-401", "CWE-401"]`. SARIF output escapes `/` as `\/` (JSONEncoder); decoders read it back as `/`, and the test decodes it. `securityTags` became internal: only `RuleID.swift` and `ReportFormatter.swift` reference it (`grep -rn securityTags --include=*.swift .`, `.build` excluded).
9. **ARC18 (I):** the `summary` switch now follows `RuleID`'s declaration order (`webview`, `kvo`, `sec-cleanup`, `sec-session`), which `explanation` already followed. The oddly broken lines of the `webview-script-handler-cycle` explanation were reflowed with the doc comment, which changes the line breaks of `arcleak rules webview-script-handler-cycle`.

## Left alone, and why

- **Finding 5a (a finite one-shot Observable) and 5c (a SwiftSignalKit signal that completes after one value).** Completion cannot be read from the call site beyond the finite markers already handled (`Single`, `Completable`, `Maybe`, `just`, `empty`, `first`, `take(1)`, `onSuccess:`). These stay warnings whose note says completion could not be determined, as ARC03 decided.
- **Finding 6 (a finite but awaiting stored Task reported as a warning).** Kept at warning, as the review asked. Only the README was fixed (ARC15).
- **The owner-app names in `README.md` ("verified: 0 findings across …") and `KnownGaps.swift` gap 4.** They come from public `main` 5c234f3, not from this lane (`git diff 5c234f3..005f65f` contains none, and these cards add none). They were not touched because removing them is outside this review's scope; the owner may want to.
- **The ARC01-ARC10 cards** were not rewritten (their commits are already on the branch).

## Replay

The eight cards' markdown was parsed and applied in order on branch `replay`, created from `lane/rules` (005f65f) in the orchestrator's copy, exactly as an executor would. Find/Replace pairs were taken from the four-backtick blocks with exact-once checks, new files were written verbatim plus one newline, every `/bin/bash …` command of every card's Commands section was run in order (with `WT` pointing at the copy), and each card's own commit command was run after `git status --short` listed exactly the card's files.

Results:
- Every edit applied.
- Every build log ended `Build complete!`, `EXIT=0`, and the `grep -cE "warning:|error:"` check printed `0` eight times.
- Test counts were 198, 198, 198, 199, 199, 199, 199, 199, all passed, in 41 suites.
- Self-dogfood gave `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed`, exit 0, each time.
- Lint was silent and no-gcd clean.
- Every probe output was as stated in its card: ARC11 2 errors and 3 warnings at lines 15/55 and 31/42/69 with `EXIT=1`; ARC12 3 warnings at 18/21/25; ARC13 5 warnings at 24/27/28/31/32; ARC14 6 warnings at Rx 16/19/20 and SignalKit 19/22/23; ARC15's `may never run` line.
- `Scripts/ci-local.sh` ended `== all gates green`, `EXIT=0`, after every card (61, 34, 34, 37, 36, 36, 40 and 68 s).
- The pre-commit hook passed on all eight commits, and `git status --short` was empty after each.

For every card, the replayed commit and the verified commit (branch `orch`) have the same tree, the same message and the same author and committer (`Gigi <42325924+g-cqd@users.noreply.github.com>`), and both are unsigned (`%G?` = `N`). Only the hashes differ, because the commit times differ.

A privacy scan of `git diff 005f65f..orch` for owner-app names, private paths and row ids found nothing. Upstream references are public `repo@sha` only: firefox-ios@4d83f60171, element-x-ios@f8d094516d and wikipedia-ios@9db7aa718d (already in the lane), plus apple/swift@d6b4691dc8 (new, read with `gh api` and raw GitHub). The real WT was not touched; all work ran in `/tmp/arc-orch2`, which was deleted at the end.

## Risks

- Find texts are exact and assume the previous card applied verbatim. If a card is skipped or edited, later Find texts fail, and the cards then stop by their stop conditions.
- Probe line numbers are exact. A fixture typed with one line more or less shifts them, which shows up as a fixture-test failure, not silently.
- Behaviour changes on user code: `webview-script-handler-cycle` stops reporting deinit-only removals on types that keep no web view (fewer errors). `kvo-observation-self-cycle` reports observations of any object (more warnings) but is silent on types with a reachable `invalidate()`. `stored-closure-strong-self` reports struct children (more warnings). The built-in `subscribe`/`bind`/`drive` stop reporting assigned Disposables (fewer warnings). No false-positive measurement on real code was run.
- The `ARC15` SecurityPack message change alters the fingerprint of `sec-cleanup-in-unreachable-deinit` findings, since the message is hashed. That rule is opt-in and unreleased, so no published baseline contains it.
- Commit messages avoid apostrophes, double quotes, backticks, `$`, `!` and backslashes, so they survive `bash -c '... -m "..."'`. The orchestrator's renderer asserted this for every card.
