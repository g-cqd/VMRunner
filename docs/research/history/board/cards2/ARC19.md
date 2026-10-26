# ARC19 — docs: KVO invalidate scope, oracle limits, bag-only reactive contracts

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (final review fixes), card 2 of 2: **dispatch after ARC20**; last card

Review items S2-S5 and two comment nits, docs and comments only (no code, no test changes; the test count stays 200). S2: the KVO explanation and known gap 9 say that any reachable `invalidate()` in the type silences `kvo-observation-self-cycle`, a Timer's included. S3: the README oracle paragraph adds the finite `Task` stored on `self` and cancelled only in `deinit` to the shapes the leak oracle does not prove, and says the `sec-*` rows are reasoned from findings and not oracle-covered. S4: the README KVO row says `invalidate()` alone does not release the change handler (also set the observation to nil). S5: the `combine-sink-self-cycle` explanation and the README `signalDisposable` bullet state the bag-only rule for `disposeBag`; the README says 0.10.2 and earlier reject the two reactive templates. Nits: the `matchUserContract` doc comment names the built-in reactive contracts; the `builtInContracts` comment no longer claims more than the code does (a user contract whose base or labels do not match falls through to the built-in).

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `explanation` of `.combineSinkSelfCycle` and `.kvoObservationSelfCycle`
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift`: the gap 9 comment
  - `README.md`: the oracle paragraph, the `signalDisposable` bullet, the `kvo-observation-self-cycle` row, the security-pack paragraph (0.10.2 note)
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: two doc comments (`matchUserContract`, `builtInContracts`)

## Change

### Edit 1: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            from the call; finite sources (`Single`, `Completable`, `Maybe`, `just`,
            `take(1)`, `first()`) stay silent. Other spellings are declared with the
            `disposeBag` and `signalDisposable` contract templates.
````

Replace it with:

````swift
            from the call; finite sources (`Single`, `Completable`, `Maybe`, `just`,
            `take(1)`, `first()`) stay silent. Other spellings are declared with the
            `disposeBag` and `signalDisposable` contract templates. A disposeBag
            subscription counts only through .disposed(by:) or addDisposableTo(_:); a
            Disposable assigned to a member of self is matched only by
            signalDisposable (declare it for a home-grown token).
````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            A reachable `invalidate()` in the type silences the rule, as it does for
            timers. invalidate() stops the notifications, but the observation keeps
            its handler until it is released (apple/swift@d6b4691dc8,
            NSObject.swift), so release it too.
````

Replace it with:

````swift
            A reachable `invalidate()` in the type silences the rule, as it does for
            timers. Any `invalidate()` counts, including a Timer's: the rule does not
            check what it is called on. invalidate() stops the notifications, but the
            observation keeps its handler until it is released (apple/swift@d6b4691dc8,
            NSObject.swift), so release it too.
````

### Edit 3: `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift`

Find this exact text (it occurs once in the file):

````swift
// handler → self stays. kvo-observation-self-cycle treats a reachable
// invalidate() as a managed lifecycle, as timer-retains-self does.
````

Replace it with:

````swift
// handler → self stays. kvo-observation-self-cycle treats a reachable
// invalidate() as a managed lifecycle, as timer-retains-self does. Any
// invalidate() in the type counts, including a Timer's: the rule does not
// check what it is called on.
````

### Edit 4: `README.md`

Find this exact text (it occurs once in the file):

````markdown
canaries on every macOS CI run. The oracle does not cover
`webview-script-handler-cycle`, `kvo-observation-self-cycle`, the RxSwift and
SwiftSignalKit subscriptions of `combine-sink-self-cycle`, or closures stored
on an owned child: those rest on documented or observed behaviour and on
public fixes, cited in each rule's explanation (`arcleak rules <id>`).
````

Replace it with:

````markdown
canaries on every macOS CI run. The oracle does not cover
`webview-script-handler-cycle`, `kvo-observation-self-cycle`, the finite
`Task` stored on `self` and cancelled only in `deinit` (its oracle scenario is
the non-terminating task), the RxSwift and SwiftSignalKit subscriptions of
`combine-sink-self-cycle`, or closures stored on an owned child: those rest on
documented or observed behaviour and on public fixes, cited in each rule's
explanation (`arcleak rules <id>`). The `sec-*` rows are reasoned from the
other rules' findings and are not oracle-covered either.
````

### Edit 5: `README.md`

Find this exact text (it occurs once in the file):

````markdown
whose change handler captures `self` strongly, with no reachable `invalidate()` in the type |
````

Replace it with:

````markdown
whose change handler captures `self` strongly, with no reachable `invalidate()` in the type (any `invalidate()` counts, a Timer's included). `invalidate()` alone does not release the change handler: also set the observation to nil |
````

### Edit 6: `README.md`

Find this exact text (it occurs once in the file):

````markdown
  `start(next:)` (declare it with `"requiredLabels": ["next"]` for other
  callees of that shape).
````

Replace it with:

````markdown
  `start(next:)` (declare it with `"requiredLabels": ["next"]` for other
  callees of that shape). A `disposeBag` subscription counts only through
  `.disposed(by:)` or `addDisposableTo(_:)`; a Disposable assigned to a member
  of `self` is matched only by `signalDisposable` (declare it for a home-grown
  token).
````

### Edit 7: `README.md`

Find this exact text (it occurs once in the file):

````markdown
0.10.2 and earlier as an unknown rule id. In SARIF output their rule
````

Replace it with:

````markdown
0.10.2 and earlier as an unknown rule id. Likewise, a contract with the
`disposeBag` or `signalDisposable` template is rejected by 0.10.2 and earlier
as an unknown template. In SARIF output their rule
````

### Edit 8: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
    /// User-KB fallback: `tokenProducer` calls feed the premature-release rules
    /// exactly like built-in token APIs; `sinkWrapper` calls additionally have
    /// their closure argument analyzed for a strong-`self` cycle exactly like
    /// `.sink` (`React.to { self.… }` stored on `self`).
````

Replace it with:

````swift
    /// User-KB fallback: `tokenProducer` calls feed the premature-release rules
    /// exactly like built-in token APIs; `sinkWrapper` calls additionally have
    /// their closure argument analyzed for a strong-`self` cycle exactly like
    /// `.sink` (`React.to { self.… }` stored on `self`). The built-in reactive
    /// contracts (`subscribe`, `bind` and `drive` as `disposeBag`,
    /// `start(next:)` as `signalDisposable`) are matched here too, after the
    /// user contracts.
````

### Edit 9: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
    /// `subscribe`/`bind`/`drive` and SwiftSignalKit's `start(next:)`. User
    /// contracts are tried first, so a user can redeclare any of these names.
````

Replace it with:

````swift
    /// `subscribe`/`bind`/`drive` and SwiftSignalKit's `start(next:)`. User
    /// contracts are tried first: one whose callee, base and labels match
    /// decides the call, so it can redeclare these names; one whose base or
    /// labels do not match falls through to the built-in.
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 200 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak rules kvo-observation-self-cycle | grep -c "including a Timer"; swift run -q arcleak rules combine-sink-self-cycle | grep -c "home-grown token"'`. Expected: `1` then `1`.
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 35 s on the orchestrator's copy after the build above).

## Stop conditions

- A Find text is not found exactly once.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (all `M`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "docs: state the KVO invalidate scope, the oracle limits and the bag-only contract

The kvo-observation-self-cycle explanation and known gap 9 now say that any
invalidate() in the type silences the rule, a Timer one included. The README
KVO row adds that invalidate() alone does not release the change handler.

The README oracle sentence adds the finite stored Task cancelled only in
deinit to the shapes the leak oracle does not cover, and says the sec-* rows
are reasoned from findings and are not oracle-covered.

The combine-sink-self-cycle explanation and the README signalDisposable
bullet say that a disposeBag subscription counts only through .disposed(by:)
or addDisposableTo(_:), and that a Disposable assigned to a member of self is
matched only by signalDisposable. The README notes that 0.10.2 and earlier
reject a contract with either template. The matchUserContract comment names
the built-in reactive contracts, and the built-in list comment says that a
user contract whose base or labels do not match falls through.
No behaviour change. 200 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `docs: state the KVO invalidate scope, the oracle limits and the bag-only contract`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.
