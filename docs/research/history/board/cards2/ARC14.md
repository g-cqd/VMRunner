# ARC14 — reactive templates: subscribe, bind and drive need the bag spelling

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 4 of 8 (after ARC13; next ARC15)

Review fix (E, and finding 5b). For the built-in `disposeBag` template (`subscribe`, `bind`, `drive`) only a chained `.disposed(by: self.<bag>)` / `addDisposableTo(self.<bag>)` now counts; the 'assigned to a member of self' path is dropped for that template, because a home-grown bus's opaque token is not provably a retaining Disposable. The `signalDisposable` template (`start(next:)`) keeps `self.<disposable>.set(...)`, `.add(...)` and assignment. The template-level check also applies to user contracts declared with `"template": "disposeBag"`, so the template means one thing everywhere.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `matchUserContract`, the `.disposeBag, .signalDisposable` case
  - `Sources/ArcLeakCore/Config/Configuration.swift`: doc comment of `case disposeBag`
  - `README.md`: the `disposeBag` bullet of Custom retention contracts
  - `Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift`: the assigned `subscription` case removed
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift`: new gap 10 at the end
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/HomeGrownBusToken.swift`: new file
  - `Tests/ArcLeakCoreTests/ReactiveContractTests.swift`: one new test at the end

## Change

### Edit 1: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
            case .disposeBag, .signalDisposable:
                // Only a Disposable that `self` keeps matters: a reactive
                // subscription is not ended by dropping its Disposable, so
                // nothing else here is a finding.
                let consumption = classifyReactiveConsumption(of: node)
                guard consumption.storesIntoSelf else { return nil }
````

Replace it with:

````swift
            case .disposeBag, .signalDisposable:
                // Only a Disposable that `self` keeps matters: a reactive
                // subscription is not ended by dropping its Disposable, so
                // nothing else here is a finding. A bag subscription counts
                // only through `.disposed(by: self.<bag>)` or
                // `addDisposableTo(self.<bag>)`: `subscribe`, `bind` and
                // `drive` are common names, and a token that a home-grown bus
                // returns and `self` assigns to a member is not provably a
                // Disposable that keeps the closure.
                let consumption = classifyReactiveConsumption(of: node)
                if contract.template == .disposeBag, consumption != .chainedStoreIn(memberOfSelf: true) {
                    return nil
                }
                guard consumption.storesIntoSelf else { return nil }
````

### Edit 2: `Sources/ArcLeakCore/Config/Configuration.swift`

Find this exact text (it occurs once in the file):

````swift
            /// An RxSwift-style subscription (`subscribe(onNext:)`, `bind`,
            /// `drive`) whose Disposable goes into a bag on `self` through a
            /// chained `.disposed(by:)` (or `addDisposableTo(_:)`), or is
            /// assigned to a member of `self`: a strong-`self` closure feeds
            /// `combine-sink-self-cycle`. Built in for `subscribe`, `bind` and
            /// `drive`.
````

Replace it with:

````swift
            /// An RxSwift-style subscription (`subscribe(onNext:)`, `bind`,
            /// `drive`) whose Disposable goes into a bag on `self` through a
            /// chained `.disposed(by:)` (or `addDisposableTo(_:)`): a
            /// strong-`self` closure feeds `combine-sink-self-cycle`. A result
            /// assigned to a member of `self` does not count. Built in for
            /// `subscribe`, `bind` and `drive`.
````

### Edit 3: `README.md`

Find this exact text (it occurs once in the file):

````markdown
- **`disposeBag`** — an RxSwift-style subscription whose closure is analyzed
  for strong-`self` capture and whose Disposable goes into a bag on `self`
  through a chained `.disposed(by:)` or `addDisposableTo(_:)`, or is assigned to
  a member of `self`. Reports `combine-sink-self-cycle` as a `warning`; silent
  for finite sources (`Single`, `Completable`, `Maybe`, `just`, `take(1)`,
  `first()`, `subscribe(onSuccess:)`). Built in for `subscribe`, `bind` and
  `drive`.
````

Replace it with:

````markdown
- **`disposeBag`** — an RxSwift-style subscription whose closure is analyzed
  for strong-`self` capture and whose Disposable goes into a bag on `self`
  through a chained `.disposed(by:)` or `addDisposableTo(_:)`. Reports
  `combine-sink-self-cycle` as a `warning`; silent for finite sources
  (`Single`, `Completable`, `Maybe`, `just`, `take(1)`, `first()`,
  `subscribe(onSuccess:)`). Built in for `subscribe`, `bind` and `drive`. A
  result assigned to a member of `self` does not count: those names are also
  used by home-grown event buses, whose tokens need not keep the closure.
````

### Edit 4: `Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift`

Find this exact text (it occurs once in the file):

````swift
    let title = BehaviorRelay<String>(value: "")
    var subscription: Disposable?
    var count = 0

    func bindInputs() {
        refresh.subscribe(onNext: { _ in // #al:expect combine-sink-self-cycle
            self.count += 1
        }).disposed(by: disposeBag)
        title.asDriver().drive(onNext: { text in self.render(text) }).disposed(by: self.disposeBag) // #al:expect combine-sink-self-cycle
        refresh.bind { _ in self.count = 0 }.disposed(by: disposeBag) // #al:expect combine-sink-self-cycle
        subscription = refresh.subscribe(onNext: { _ in self.count += 2 }) // #al:expect combine-sink-self-cycle
    }
````

Replace it with:

````swift
    let title = BehaviorRelay<String>(value: "")
    var count = 0

    func bindInputs() {
        refresh.subscribe(onNext: { _ in // #al:expect combine-sink-self-cycle
            self.count += 1
        }).disposed(by: disposeBag)
        title.asDriver().drive(onNext: { text in self.render(text) }).disposed(by: self.disposeBag) // #al:expect combine-sink-self-cycle
        refresh.bind { _ in self.count = 0 }.disposed(by: disposeBag) // #al:expect combine-sink-self-cycle
    }
````

### Edit 5: `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift`

Find this exact text (it occurs once in the file):

````swift
    func stop() {
        observation?.invalidate()
    }

    func refresh() {}
}
````

Replace it with:

````swift
    func stop() {
        observation?.invalidate()
    }

    func refresh() {}
}

// Gap 10: an RxSwift Disposable assigned to a member of self instead of a
// bag. The built-in templates for subscribe, bind and drive require
// .disposed(by:) or addDisposableTo(_:), because a home-grown bus can use the
// same names for tokens that do not keep the closure.
final class SearchViewModel {
    let query = PublishSubject<String>()
    var subscription: Disposable?

    func bind() {
        subscription = query.subscribe(onNext: { text in self.search(text) })
    }

    func search(_ text: String) {}
}
````

### Edit 6: `Tests/ArcLeakCoreTests/ReactiveContractTests.swift`

Find this exact text (it occurs once in the file):

````swift
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])
        #expect(findings.first?.message.contains("self → disposable → closure → self") == true)
    }
}
````

Replace it with:

````swift
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])
        #expect(findings.first?.message.contains("self → disposable → closure → self") == true)
    }

    @Test("subscribe needs the bag spelling; start(next:) still counts when assigned to a member")
    func assignedTokens() {
        let source = """
            final class Feed {
                let bus = Bus()
                let signal = Signal<Int, NoError>()
                var token: Token?
                var disposable: Disposable?
                var last = 0

                func start() {
                    token = bus.subscribe { value in self.last = value }
                    disposable = signal.start(next: { value in self.last = value })
                }
            }
            """
        let findings = Analyzer().analyze(source: source, path: "Feed.swift").findings
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])
        #expect(findings.map(\.line) == [10])
    }
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Clean/HomeGrownBusToken.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
// A home-grown event bus whose subscribe(_:) returns an opaque token. For
// subscribe, bind and drive the built-in reactive template needs the RxSwift
// bag spelling (.disposed(by:) or addDisposableTo(_:)); a token assigned to a
// member of self is not provably a Disposable that keeps the closure. Here the
// bus keeps the handler and stop() unsubscribes it: a managed lifecycle.
final class EventBus {
    static let shared = EventBus()
    private var handlers: [Int: (String) -> Void] = [:]
    private var nextID = 0

    func subscribe(_ handler: @escaping (String) -> Void) -> Int {
        nextID += 1
        handlers[nextID] = handler
        return nextID
    }

    func unsubscribe(_ id: Int) {
        handlers[id] = nil
    }
}

final class InboxViewModel {
    var token: Int?
    var unread = 0

    func start() {
        token = EventBus.shared.subscribe { _ in self.unread += 1 }
    }

    func stop() {
        if let token { EventBus.shared.unsubscribe(token) }
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 199 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/SignalDisposableSelf.swift Tests/ArcLeakCoreTests/Fixtures/Clean/HomeGrownBusToken.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift --no-cache; echo EXIT=$?'`. Expected: the summary line `arcleak: 6 finding(s) (0 error(s), 6 warning(s)) in 4 file(s)`, then 6 `warning: [combine-sink-self-cycle]` lines: `RxDisposeBagSelf.swift` lines 16, 19 and 20, `SignalDisposableSelf.swift` lines 19, 22 and 23; nothing in the two Clean files; then `EXIT=0`.
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 40 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M`, `D` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Config/Configuration.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Tests/ArcLeakCoreTests/Fixtures/Clean/HomeGrownBusToken.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift Tests/ArcLeakCoreTests/ReactiveContractTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "fix: require a dispose bag for the built-in subscribe, bind and drive

The built-in disposeBag template matched subscribe, bind and drive by name
and also accepted a result assigned to a member of self. Those names are
common outside RxSwift: a home-grown bus that returns an opaque token was
reported as a cycle, though nothing proves that the token keeps the closure.

The disposeBag template now counts only a chained .disposed(by:) or
addDisposableTo(_:) into a member of self. The signalDisposable template
keeps the assignment path, so self.disposable = signal.start(next:) is still
reported. The assigned Rx shape leaves Leaks/RxDisposeBagSelf and is
recorded in KnownGaps (gap 10); Clean/HomeGrownBusToken pins the bus shape
and ReactiveContractTests pins both paths. 199 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `fix: require a dispose bag for the built-in subscribe, bind and drive`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

