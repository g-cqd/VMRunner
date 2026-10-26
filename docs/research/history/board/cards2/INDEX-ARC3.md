# INDEX-ARC3 — arcleak rules lane, final review fixes (cards ARC20 and ARC19)

Repository: `WT = ~/Developer/g-cqd/arcleak-lane`, branch `lane/rules` at `30610af` (ARC01-ARC18, 18 commits on public `main` 5c234f3; Swift 6.4). The final review found no blocking issue, plus one precision issue (S1), four documentation items (S2-S5) and some nits. These two cards fix them with one commit each on top of `lane/rules`. No history is rewritten; the integrator still exports with `git format-patch 5c234f3..lane/rules`.

Both cards were produced like the ARC2 batch. The change was made on a copy of the clone (`/tmp/arc-orch3`, branch `orch` from `lane/rules`) from the Find/Replace pairs of the card markdown, each Find checked to occur exactly once. It built and passed the gate there and was committed with the card's own commit command. Then both cards were replayed from the markdown alone on a fresh branch `replay` from `30610af` in the same copy (see "Replay"). The copy was deleted afterwards.

## Order and dependencies

**Dispatch ARC20 first, then ARC19** (ARC20 is the only behaviour change, so it goes first; the numbers do not give the order). Both cards edit `README.md`, `RuleID.swift` and `FactsExtraction.swift`, at different places. Only the order ARC20 then ARC19 was verified and replayed, so dispatch one at a time, in that order.

| order | card | commit subject | review items | depends on | tests after |
|---|---|---|---|---|---|
| 1 | ARC20 | fix: require an owned receiver for the deinit-only script handler error | S1, the finite-marker nit, the `return nil` nit | ARC18 (30610af) | 200 tests / 41 suites |
| 2 | ARC19 | docs: state the KVO invalidate scope, the oracle limits and the bag-only contract | S2, S3, S4, S5, the two comment nits | ARC20 | 200 / 41 |

Baseline (measured on the copy at 30610af): 199 tests in 41 suites pass. No card bumps the version or touches `Benchmarks/`, `Scripts/`, `.github/`, `Package.*`.

## Verified commands (macOS, Xcode toolchain, Swift 6.4, on the copy)

| command | result | time on the copy |
|---|---|---|
| `swift build --build-tests` | `Build complete!`, 0 `warning:`/`error:` lines | 3-10 s incremental (the first build of the copy took 130 s: a copied `.build` rebuilds fully and prints `Stale file … outside of the allowed root paths` warnings that only a copied `.build` produces; none after) |
| `swift test --no-parallel` | `Test run with 200 tests in 41 suites passed` after each card | 7 s |
| `swift run arcleak analyze Sources --strict --no-cache` | `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed`, exit 0 | 3-5 s |
| `Scripts/lint-format.sh` | no output, exit 0 | under 2 s |
| `Scripts/no-gcd.sh` | `no-gcd: implementation is GCD-free` | under 1 s |
| `Scripts/ci-local.sh` | ends with `== all gates green`, exit 0 | 42 s (ARC20), 33 s (ARC19) |

The global pre-commit hook ran swift-format on the staged files and printed `[OK] pre-commit checks completed successfully.` for both commits, on the verified and the replayed branch.

## Decisions made by the orchestrator (the pre-dispatch reviewer should confirm them)

1. **ARC20 (S1): the full receiver-root fix, not the smaller fallback.** It fits one small commit (10 files, +203/-45, including fixtures and one test). `APICallFact` gains `receiverRootMember: String?` (default `nil`, so the other `APICallFact(` call sites are unchanged; both copy methods carry it). Only `scriptMessageHandlerAdd` sets it. The value is the stored member of `self` that the receiver chain starts from, walking member accesses, `?` and `!` (`webView` for `webView.configuration.userContentController` or `self.webView.…`); a parameter or local gives `nil`, because `memberOfSelfName` already lets parameters and locals shadow members. `receiverIsSelfMember` was not reused: it is a Bool and cannot say *which* member, and "a member" is not enough (the type could keep a web view and also a helper whose controller it registers on). The facts cache needs no change: its header carries the build identity, so a new build never reads old facts. The rule now works like this:
   - **Error:** a deinit-only removal where the root is a strong stored property whose declared or inferred type is exactly `WKWebView`, `WKWebViewConfiguration` or `WKUserContentController`.
   - **Configured severity, cycle message:** the same root with no removal.
   - **Warning cap, `observed:` message:** any other receiver when the type keeps such a property. The message says "when this controller belongs to the web view this type keeps"; the deinit-only note says that deinit then never runs.
   - **Unchanged from ARC11:** if the type keeps no such property, a missing removal is an `observed:` warning and a deinit-only removal is silent.
   - **Exact type names:** SwiftUI's `WebView` struct and any `…WebView` subclass no longer count. A `WKWebView` subclass under its own name is a false negative, like the superclass case ARC11 already accepted.
2. **ARC20 consequence: a local alias of an owned controller is no longer proven.** In `let contentController = webView.configuration.userContentController; contentController.add(self, …)`, and in `let config = WKWebViewConfiguration(); config.userContentController.add(self, …)`, the receiver root is a local. Such a call now gets the `observed:` message and at most a warning, even with a deinit-only removal (it was an `error` before). Resolving locals to their initializer would need a new local-binding table and was left out. The existing Leaks fixture `PageController` (line 31) has this shape: it stays a warning, with the `observed:` message now. `OwningBridge` in the same fixture registered through the parameter it had just stored. It was rewritten to register on its stored `let contentController = WKUserContentController()`, so the owned-controller error stays pinned (line 54).
3. **ARC20, the reviewer's literal input.** Before ARC20 the probe gave `error` only with the parameter named `contentController`. With the parameter named `c`, the call is not matched at all, because the extraction requires a receiver whose name ends in `ContentController` (checked on the copy at 30610af). As in ARC11, the Leaks fixture (`PreviewBridge`, warning at line 83) and the test therefore use `contentController`. The Clean twin (`SwiftUIPreviewBridge`) is the same class keeping a SwiftUI `WebView`: silent. At 30610af it gave `error` (checked by building the old sources against the new fixtures). The new `PrecisionRegressionTests` case `scriptHandlerErrorNeedsOwnedReceiver` covers three shapes: parameter controller plus an unrelated owned `WKWebView` gives a warning starting `observed:`; owned stored controller gives an error; SwiftUI `WebView` gives nothing.
4. **ARC20, finite markers.** `just`, `empty` and `first` moved from the bare-token set into a table of call forms, matched on the tokens that follow the name: `just` + `(`, `empty` + `()`, `first` + `()`, and `take` + `(1)`, which replaces the separate `take(1)` check with the same behaviour. `Single`, `Completable`, `Maybe` and the `as…` conversions stay bare tokens. The brief asked for "a Clean fixture line pinning that `users.first?.events.subscribe { self… }.disposed(by: bag)` IS flagged". Clean fixtures must have zero findings, so that line went into the **Leaks** fixture `RxDisposeBagSelf.swift` (`UserListViewModel`, line 34, `#al:expect combine-sink-self-cycle`; silent at 30610af). The Clean fixture `RxFiniteOrWeak.swift` gained `refresh.first().asObservable()…` and `Observable<Int>.empty()…` lines, which pin that the call forms are still finite.
5. **ARC20: the `return nil` on a bag-spelling mismatch stays.** It is not equivalent to `continue`. User contracts are tried before the built-ins, and duplicate callees are not rejected. Take a user who declares `start` with the `disposeBag` template and a call `self.d = x.start(next: { self… })`. With `return nil` it gives no finding (the user's contract decides). With `continue` the built-in `signalDisposable` for `start(next:)` would match and report it. The behaviour is the same only when no later contract matches the same call. Since neither card may change other behaviour, a comment above the check now explains this. The `base`/`requiredLabels` `continue`s are different: those contracts do not match the call at all. ARC19's rewording of the built-in-list comment says the same thing.
6. **ARC19 (S2):** an `invalidate()` silences the KVO rule whatever its receiver. `ReleaseSite.Kind.invalidate` is keyed on the callee name only, and the rule calls `hasReachableRelease(.invalidate)`. A session's `invalidateAndCancel()`/`finishTasksAndInvalidate()` is a different kind and does not count, so the text says "including a Timer's", not "any invalidate-like call".
7. **ARC19 (S3):** `Sources/leak-oracle/OracleScenarios.swift` has a non-terminating `Task` scenario only (a `while !Task.isCancelled` loop), so the README now says the finite stored `Task` cancelled only in `deinit` is not oracle-proven. The Rx/SwiftSignalKit subscriptions and owned-child closures were already listed, so the paragraph keeps them. It now adds that the `sec-*` rows are reasoned from findings and not oracle-covered.
8. **ARC19 (S5), the "rejected by 0.10.2 and earlier" note for the two templates** is reasoned from code, not run. At 5c234f3 (version 0.10.2), `Configuration.UserContract.Template` is a `String` raw-value `Codable` enum with only `tokenProducer` and `sinkWrapper`, and `Configuration.load` maps any decoding error to `configurationInvalid`. The lane is still at version string 0.10.2 (no bump in this lane), as the existing sec-* sentence already assumes.

## Left alone, and why

- **`isUserContentController` (the receiver name must end in `ContentController`) and optional-chained receivers (`contentController?.add(self, …)`, not matched).** Widening the matcher would change behaviour beyond the review items.
- **Locals resolved to their initializer** (decision 2): not in scope.
- **The owner-app names in `README.md` ("verified: 0 findings across …").** They come from public `main` 5c234f3, as INDEX-ARC2 noted; these cards add none.

## Replay

Both cards' markdown was parsed and applied in order (ARC20, then ARC19) on branch `replay`, created from `30610af` in the copy, as an executor would: Find/Replace pairs were taken from the four-backtick blocks with exact-once checks (22 edits, then 9). Every `/bin/bash …` command of each card's Commands section was run in order, with `WT` pointing at the copy, and each card's commit command was run after `git status --short` listed exactly the card's files.

Results:
- Every edit applied.
- Build logs ended `Build complete!`, `EXIT=0`, and the `grep -cE "warning:|error:"` check printed `0` both times.
- Tests: 200 and 200, all passed, in 41 suites.
- Self-dogfood: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed`, exit 0, both times. Lint was silent and no-gcd was clean.
- The ARC20 probe gave `arcleak: 10 finding(s) (2 error(s), 8 warning(s)) in 4 file(s)`, with findings at the lines stated in the card, then `EXIT=1`. The ARC19 probe printed `1` and `1`.
- `Scripts/ci-local.sh` ended `== all gates green`, `EXIT=0`, after each card (69 s and 60 s for the whole replay of each card, gate included).
- The pre-commit hook passed both commits, and `git status --short` was empty after each.

The replayed and the verified commits have identical trees (`da5a6d2d64…` for ARC20, `b56028bb6e…` for ARC19), identical messages, the same author and committer (`Gigi <42325924+g-cqd@users.noreply.github.com>`), and both are unsigned (`%G?` = `N`). Only the hashes differ.

A privacy scan of `git diff 30610af..orch` for owner-app names and private paths found nothing. Upstream references are public `repo@sha` only, all already in the lane (firefox-ios@4d83f60171, element-x-ios@f8d094516d, wikipedia-ios@9db7aa718d, apple/swift@d6b4691dc8). The real WT was not touched. All work ran in `/tmp/arc-orch3`, which was deleted at the end. The replay wrote the cards' own log paths `/tmp/arc-lane-{build,test,ci}.log`, which the executors overwrite anyway.

## Risks

- Find texts are exact. The two cards' Find texts do not overlap, so the reverse order would probably apply too, but it was not verified: dispatch ARC20 first. If a Find text fails, the card stops by its stop conditions.
- Probe line numbers are exact. A fixture typed with one line more or less shifts them, which shows up as a fixture-test failure, not silently.
- Behaviour changes on user code (ARC20 only):
  - `webview-script-handler-cycle` gives fewer errors: a parameter or local receiver is now at most a warning, and a type keeping only a SwiftUI `WebView` or a `…WebView` subclass now counts as keeping no web view.
  - Its message changes to `observed: …` for parameter and local receivers. The message is hashed into the fingerprint, so baselines that hold such findings will see them as new.
  - `combine-sink-self-cycle` gives more warnings: a receiver containing a property named `first`, `just` or `empty` is no longer treated as finite.
  - No false-positive measurement on real code was run.
- Commit messages avoid apostrophes, double quotes, backticks, `$`, `!` and backslashes, so they survive `bash -c '... -m "..."'` (checked with grep).
