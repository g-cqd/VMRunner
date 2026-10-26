# ARC04 — task-nonterminating-self: stored Task cancelled only in deinit

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 4 of 10 (after ARC03; next ARC05)

Task item 4. A Task stored on self whose body awaits (at its own level) and captures self strongly, with `cancel()` only in deinit, now reports even when the body is finite. Severity decision: the non-terminating paths keep their severities (error when the handle is stored on self); the new finite path reports at the configured severity (warning by default), because a finite await usually returns and the repo reserves `error` for definite leaks. New facts: `ClosureCaptureAnalysis.hasAwait`, `TaskSpawnFact.bodyAwaits`.

- **Model:** haiku, low. **Size:** about 170 lines (code about 60). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift`: `struct ClosureCaptureAnalysis` (`hasAwait`, both returns of `analyze`, private init), `BodyWalker` (`sawAwait`, new `visit(_ node: AwaitExprSyntax)` before `visit(_ node: ForStmtSyntax)`)
  - `Sources/ArcLeakCore/Facts/TaskSpawnFact.swift`: `bodyAwaits` field and init parameter
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `popMethod` (TaskSpawnFact rebuild), `matchTaskSpawn`
  - `Sources/ArcLeakCore/Rules/TaskNonterminatingSelfRule.swift`: doc comment, `check`
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `summary` and `explanation` of `.taskNonterminatingSelf`
  - `README.md`: `task-nonterminating-self` row and the † footnote
  - new `Tests/ArcLeakCoreTests/Fixtures/Leaks/StoredTaskDeinitCancel.swift`, new `Tests/ArcLeakCoreTests/Fixtures/Clean/StoredTaskWeakOrCancelled.swift`

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
| `notification-observer-leak` | warning† | strong-`self` block observer; the center holds block and token until removal |
| `task-nonterminating-self` | warning† | `while true`/`for await` `Task` capturing `self` strongly |
| `unstored-lifetime-token` | warning | lifetime token discarded — from framework APIs or same-file functions whose return type is a token |
| `token-stored-in-local` | warning | token bound to storage that dies at scope end, or to a local captured by an escaping closure (never removed → unbounded growth) |
| `mutual-strong-properties` | warning | cross-file ownership-graph cycle: strong stored properties whose types point at each other, reported with the retention path |
````

Replace it with:

````markdown
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
| `notification-observer-leak` | warning† | strong-`self` block observer; the center holds block and token until removal |
| `task-nonterminating-self` | warning† | `while true`/`for await` `Task` capturing `self` strongly; also a `Task` stored on `self` whose body awaits, captures `self` strongly and is cancelled only in `deinit` (warning) |
| `unstored-lifetime-token` | warning | lifetime token discarded — from framework APIs or same-file functions whose return type is a token |
| `token-stored-in-local` | warning | token bound to storage that dies at scope end, or to a local captured by an escaping closure (never removed → unbounded growth) |
| `mutual-strong-properties` | warning | cross-file ownership-graph cycle: strong stored properties whose types point at each other, reported with the retention path |
````

### Edit 2: `README.md`

Find this exact text (it occurs once in the file):

````markdown
handle)`) and self-referencing local functions passed as values feed the same
capture pipeline as closures.

† upgraded to **error** when the only release call sits in `deinit` (or the
task handle is stored on `self`) — the release is unreachable by construction.

‡ the owned-child path reports a **warning**: a child may clear its callback
after firing, which the owner's source cannot show.
````

Replace it with:

````markdown
handle)`) and self-referencing local functions passed as values feed the same
capture pipeline as closures.

† upgraded to **error** when the only release call sits in `deinit` (or a
non-terminating task's handle is stored on `self`) — the release is
unreachable by construction.

‡ the owned-child path reports a **warning**: a child may clear its callback
after firing, which the owner's source cannot show.
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        case .combineAssignSelfCycle:
            "assign(to:on: self) retains `self` strongly while `self` stores the cancellable"
        case .taskNonterminatingSelf:
            "A non-terminating Task captures `self` strongly (Task bodies capture `self` implicitly)"
        case .unstoredLifetimeToken:
            "Lifetime token (AnyCancellable, observation, observer handle) is discarded — the work it owns stops immediately"
        case .tokenStoredInLocal:
````

Replace it with:

````swift
        case .combineAssignSelfCycle:
            "assign(to:on: self) retains `self` strongly while `self` stores the cancellable"
        case .taskNonterminatingSelf:
            "A non-terminating Task, or a stored Task cancelled only in deinit, captures `self` strongly"
        case .unstoredLifetimeToken:
            "Lifetime token (AnyCancellable, observation, observer handle) is discarded — the work it owns stops immediately"
        case .tokenStoredInLocal:
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            `self` forever; storing the handle on `self` makes it a cycle whose only exit
            is a cancel() that deinit can never reach.

            Fix: `[weak self]` and exit when self is nil, or cancel from a reachable
            path. Finite tasks are deliberately not flagged — lifetime extension is not
            a leak.
            """
        case .unstoredLifetimeToken:
            """
````

Replace it with:

````swift
            `self` forever; storing the handle on `self` makes it a cycle whose only exit
            is a cancel() that deinit can never reach.

            A finite task whose body awaits is flagged in one shape only: its handle is
            stored on `self` and its only `cancel()` sits in deinit. That cancel cannot
            run while the task holds `self`, so `self` lives as long as the awaited
            work, forever if it never returns — the deinit-only idiom of
            timer-retains-self. Reported at the configured severity (warning by
            default), since the awaited work usually does return.

            Fix: `[weak self]` and exit when self is nil, or cancel from a reachable
            path. Other finite tasks are deliberately not flagged — lifetime extension
            is not a leak.
            """
        case .unstoredLifetimeToken:
            """
````

### Edit 5: `Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift` (near `import SwiftSyntax`)

Find this exact text (it occurs once in the file):

````swift
struct ClosureCaptureAnalysis: Sendable, Equatable {
    let selfCapture: SelfCaptureKind
    let hasNonterminatingBody: Bool
    /// True when the ONLY evidence for a strong capture is `self` in a nested
    /// closure's capture list (`sink { Task { [weak self] … } }`): the outer
    /// closure still captures `self` strongly to materialize the nested weak
````

Replace it with:

````swift
struct ClosureCaptureAnalysis: Sendable, Equatable {
    let selfCapture: SelfCaptureKind
    let hasNonterminatingBody: Bool
    /// The closure's own body (not a nested closure) contains `await`: a Task
    /// with such a body can outlive the call that spawned it by an unbounded
    /// time.
    let hasAwait: Bool
    /// True when the ONLY evidence for a strong capture is `self` in a nested
    /// closure's capture list (`sink { Task { [weak self] … } }`): the outer
    /// closure still captures `self` strongly to materialize the nested weak
````

### Edit 6: `Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift` (near `struct ClosureCaptureAnalysis: Sendable, Equatable {`)

Find this exact text (it occurs once in the file):

````swift
            return ClosureCaptureAnalysis(
                selfCapture: listed,
                hasNonterminatingBody: walker.sawNonterminatingLoop,
                strongViaNestedCaptureOnly: false
            )
        }
````

Replace it with:

````swift
            return ClosureCaptureAnalysis(
                selfCapture: listed,
                hasNonterminatingBody: walker.sawNonterminatingLoop,
                hasAwait: walker.sawAwait,
                strongViaNestedCaptureOnly: false
            )
        }
````

### Edit 7: `Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift` (near `struct ClosureCaptureAnalysis: Sendable, Equatable {`)

Find this exact text (it occurs once in the file):

````swift
        return ClosureCaptureAnalysis(
            selfCapture: capture,
            hasNonterminatingBody: walker.sawNonterminatingLoop,
            strongViaNestedCaptureOnly: !walker.sawDirectSelf && walker.sawNestedCaptureListSelf
        )
    }
````

Replace it with:

````swift
        return ClosureCaptureAnalysis(
            selfCapture: capture,
            hasNonterminatingBody: walker.sawNonterminatingLoop,
            hasAwait: walker.sawAwait,
            strongViaNestedCaptureOnly: !walker.sawDirectSelf && walker.sawNestedCaptureListSelf
        )
    }
````

### Edit 8: `Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift` (near `struct ClosureCaptureAnalysis: Sendable, Equatable {`)

Find this exact text (it occurs once in the file):

````swift
    private init(
        selfCapture: SelfCaptureKind,
        hasNonterminatingBody: Bool,
        strongViaNestedCaptureOnly: Bool
    ) {
        self.selfCapture = selfCapture
        self.hasNonterminatingBody = hasNonterminatingBody
        self.strongViaNestedCaptureOnly = strongViaNestedCaptureOnly
    }
}
````

Replace it with:

````swift
    private init(
        selfCapture: SelfCaptureKind,
        hasNonterminatingBody: Bool,
        hasAwait: Bool,
        strongViaNestedCaptureOnly: Bool
    ) {
        self.selfCapture = selfCapture
        self.hasNonterminatingBody = hasNonterminatingBody
        self.hasAwait = hasAwait
        self.strongViaNestedCaptureOnly = strongViaNestedCaptureOnly
    }
}
````

### Edit 9: `Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift` (near `private final class BodyWalker: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
    private var memberCandidates: Set<String> = []
    private var localNames: Set<String> = []
    private(set) var sawNonterminatingLoop = false
    /// Depth below the analyzed body: loops only count at depth 0.
    private var nestingDepth = 0

````

Replace it with:

````swift
    private var memberCandidates: Set<String> = []
    private var localNames: Set<String> = []
    private(set) var sawNonterminatingLoop = false
    /// `await` at depth 0 (nested closures run on their own schedule).
    private(set) var sawAwait = false
    /// Depth below the analyzed body: loops only count at depth 0.
    private var nestingDepth = 0

````

### Edit 10: `Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift` (near `private final class BodyWalker: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if nestingDepth == 0, node.awaitKeyword != nil {
            sawNonterminatingLoop = true
````

Replace it with:

````swift
        return .visitChildren
    }

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        if nestingDepth == 0 { sawAwait = true }
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if nestingDepth == 0, node.awaitKeyword != nil {
            sawNonterminatingLoop = true
````

### Edit 11: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
                    position: spawn.position,
                    selfCapture: spawn.selfCapture,
                    hasNonterminatingBody: spawn.hasNonterminatingBody,
                    consumption: finalize(spawn.consumption)
                )
            )
        }
````

Replace it with:

````swift
                    position: spawn.position,
                    selfCapture: spawn.selfCapture,
                    hasNonterminatingBody: spawn.hasNonterminatingBody,
                    consumption: finalize(spawn.consumption),
                    bodyAwaits: spawn.bodyAwaits
                )
            )
        }
````

### Edit 12: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
            position: position(of: node),
            selfCapture: analysis.selfCapture,
            hasNonterminatingBody: analysis.hasNonterminatingBody,
            consumption: classifyConsumption(of: node)
        )
    }

````

Replace it with:

````swift
            position: position(of: node),
            selfCapture: analysis.selfCapture,
            hasNonterminatingBody: analysis.hasNonterminatingBody,
            consumption: classifyConsumption(of: node),
            bodyAwaits: analysis.hasAwait
        )
    }

````

### Edit 13: `Sources/ArcLeakCore/Facts/TaskSpawnFact.swift` (near `public struct TaskSpawnFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    /// the syntactic markers of a task that plausibly never completes.
    public let hasNonterminatingBody: Bool
    public let consumption: ResultConsumption

    public init(
        position: SourcePosition,
        selfCapture: SelfCaptureKind,
        hasNonterminatingBody: Bool,
        consumption: ResultConsumption
    ) {
        self.position = position
        self.selfCapture = selfCapture
        self.hasNonterminatingBody = hasNonterminatingBody
        self.consumption = consumption
    }
}
````

Replace it with:

````swift
    /// the syntactic markers of a task that plausibly never completes.
    public let hasNonterminatingBody: Bool
    public let consumption: ResultConsumption
    /// Body contains `await` at its own level — a finite task that can still
    /// hold its captures for as long as the awaited work takes.
    public let bodyAwaits: Bool

    public init(
        position: SourcePosition,
        selfCapture: SelfCaptureKind,
        hasNonterminatingBody: Bool,
        consumption: ResultConsumption,
        bodyAwaits: Bool = false
    ) {
        self.position = position
        self.selfCapture = selfCapture
        self.hasNonterminatingBody = hasNonterminatingBody
        self.consumption = consumption
        self.bodyAwaits = bodyAwaits
    }
}
````

### Edit 14: `Sources/ArcLeakCore/Rules/TaskNonterminatingSelfRule.swift`

Find this exact text (it occurs once in the file):

````swift
/// `self` with no `self` token in source — the compiler's explicit-self guard
/// is deliberately absent here, which is exactly why this rule exists.
/// Finite tasks capturing `self` are lifetime extension, not leaks; they are
/// not flagged.
struct TaskNonterminatingSelfRule: Rule {
    static let emits: [RuleID] = [.taskNonterminatingSelf]

````

Replace it with:

````swift
/// `self` with no `self` token in source — the compiler's explicit-self guard
/// is deliberately absent here, which is exactly why this rule exists.
/// Finite tasks capturing `self` are lifetime extension, not leaks; they are
/// not flagged — except one shape: a task whose body awaits, whose handle is
/// stored on `self`, and whose only `cancel()` sits in `deinit`. That cancel
/// cannot run while the task holds `self`, so `self` lives as long as the
/// awaited work, forever if it never returns (the timer rule's deinit-only
/// idiom). Not definite, so it reports at the configured severity.
struct TaskNonterminatingSelfRule: Rule {
    static let emits: [RuleID] = [.taskNonterminatingSelf]

````

### Edit 15: `Sources/ArcLeakCore/Rules/TaskNonterminatingSelfRule.swift` (near `struct TaskNonterminatingSelfRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
        // observer, and dispatch-source rules. Deinit-only cancel stays a
        // finding: deinit is unreachable while the task retains self.
        guard !type.hasReachableRelease(.cancel) else { return [] }
        return type.taskSpawns.compactMap { spawn in
            guard spawn.selfCapture.isStrong, spawn.hasNonterminatingBody else { return nil }

            let implicitly: String
            if case .strong(implicit: true) = spawn.selfCapture {
````

Replace it with:

````swift
        // observer, and dispatch-source rules. Deinit-only cancel stays a
        // finding: deinit is unreachable while the task retains self.
        guard !type.hasReachableRelease(.cancel) else { return [] }
        let cancelOnlyInDeinit = type.releaseOnlyInDeinit(.cancel)
        return type.taskSpawns.compactMap { spawn in
            guard spawn.selfCapture.isStrong else { return nil }
            guard spawn.hasNonterminatingBody else {
                guard cancelOnlyInDeinit, spawn.bodyAwaits, spawn.consumption.storesIntoSelf else { return nil }
                return Finding(
                    rule: .taskNonterminatingSelf,
                    severity: configuration.severity(for: .taskNonterminatingSelf),
                    path: path,
                    line: spawn.position.line,
                    column: spawn.position.column,
                    message:
                        "Task stored on self captures self strongly and is cancelled only in deinit — self lives until every await in the task returns",
                    note:
                        "deinit cannot run while the task holds self, so its cancel() never fires; if an await never returns, self leaks — capture [weak self] or cancel from a reachable path (viewDidDisappear/stop())"
                )
            }

            let implicitly: String
            if case .strong(implicit: true) = spawn.selfCapture {
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Clean/StoredTaskWeakOrCancelled.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
// Stored finite tasks that do not pin self: [weak self]; a cancel() reachable
// outside deinit; a body with nothing to await; a handle self does not keep.
final class WeakLoader {
    var loader: Task<Void, Never>?

    func start() {
        loader = Task { [weak self] in
            await self?.load()
        }
    }

    func load() async {}

    deinit {
        loader?.cancel()
    }
}

final class StoppableLoader {
    var loader: Task<Void, Never>?

    func start() {
        loader = Task {
            await self.load()
        }
    }

    func stop() {
        loader?.cancel()
    }

    func load() async {}

    deinit {
        loader?.cancel()
    }
}

final class SyncWorker {
    var job: Task<Void, Never>?
    var done = false

    func start() {
        job = Task {
            self.done = true
        }
    }

    deinit {
        job?.cancel()
    }
}

final class FireAndForget {
    func start() {
        Task {
            await self.load()
        }
    }

    func load() async {}

    deinit {}
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Leaks/StoredTaskDeinitCancel.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
// A finite task that awaits, stored on self, whose only cancel() sits in
// deinit: deinit cannot run while the task holds self, so the cancel never
// fires and self lives as long as the awaited work — forever if it never
// returns. Same deinit-only idiom as Leaks/TimerBlockDeinitOnly (warning).
final class ProfileLoader {
    var loader: Task<Void, Never>?

    func start() {
        loader = Task { // #al:expect task-nonterminating-self
            await self.load()
        }
    }

    func load() async {}

    deinit {
        loader?.cancel()
    }
}

// Task.init is @_implicitSelfCapture: `fetch()` and `apply` capture self.
final class FeedRefresher {
    var task: Task<Void, Never>?

    func refresh() {
        self.task = Task { // #al:expect task-nonterminating-self
            let items = await fetch()
            apply(items)
        }
    }

    func fetch() async -> [Int] { [] }
    func apply(_ items: [Int]) {}

    deinit {
        task?.cancel()
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 193 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 80 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Fixture probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/StoredTaskDeinitCancel.swift Tests/ArcLeakCoreTests/Fixtures/Clean/StoredTaskWeakOrCancelled.swift --no-cache; echo EXIT=$?'`. Expected: the output contains the summary line `arcleak: 2 finding(s) (0 error(s), 2 warning(s)) in 2 file(s)`: `warning: [task-nonterminating-self] Task stored on self captures self strongly and is cancelled only in deinit` at `StoredTaskDeinitCancel.swift` lines 10 and 27; then `EXIT=0`.
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 40 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump: that is a release step), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/ClosureCaptureAnalysis.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/TaskSpawnFact.swift Sources/ArcLeakCore/Rules/TaskNonterminatingSelfRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/StoredTaskWeakOrCancelled.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/StoredTaskDeinitCancel.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: flag stored tasks cancelled only in deinit

A Task stored on self whose body awaits and captures self strongly keeps
self alive until every await returns. When its only cancel() sits in
deinit, that cancel cannot run while the task holds self, so an await that
never returns leaks self: the deinit-only idiom timer-retains-self already
reports. task-nonterminating-self now reports this finite shape at its
configured severity (warning by default); the non-terminating shapes keep
their severities.

Leaks/StoredTaskDeinitCancel (2 findings) and
Clean/StoredTaskWeakOrCancelled pin it; 193 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. If the branch does not exist yet (first card only), create it with `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane checkout -b lane/rules'` from `main` at `5c234f3`.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (verified: build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint; 36 s incremental on the orchestrator's copy). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned, identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook runs swift-format checks and prints `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.
