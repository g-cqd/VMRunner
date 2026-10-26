# ARC12 — kvo-observation-self-cycle: any observed object, silent on a reachable invalidate()

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 2 of 8 (after ARC11; next ARC13)

Review fix (C, and finding 4). The KVO cycle self → observation → handler → self does not depend on the observed object, so the extraction no longer records whether the observed object is `self` or a member of `self` and the rule no longer requires it; it keeps the strong-self handler and the stored-on-self conditions, and it is silent when the type has a reachable `invalidate()` (`hasReachableRelease(.invalidate)`, like the timer rule). The Clean twin loses its parameter case (now a Leaks case) and gains a reachable invalidate-and-release case. Because `invalidate()` alone does not release the change handler (apple/swift@d6b4691dc8, `NSObject.swift`: the observation keeps `let helper`, the helper keeps `let callback`), the note asks for release too, and KnownGaps records an invalidate-only observation as gap 9.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: the `observe` case of the knowledge-base match (drop the observed-object lines)
  - `Sources/ArcLeakCore/Facts/APICallFact.swift`: doc comment of `targetIsSelf`
  - `Sources/ArcLeakCore/Rules/KVOObservationSelfCycleRule.swift`: doc comment, `check` guard, note text
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `explanation` of `.kvoObservationSelfCycle`
  - `README.md`: the `kvo-observation-self-cycle` row of the Rules table
  - `Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift`: header comment, one property, new `follow(_:)`
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift`: `QuietObserver` without the parameter case, new `ManagedObserver`
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift`: new gap 9 at the end

## Change

### Edit 1: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
                kind = .kvoObserve
                closureLabels = ["changeHandler"]
                // The observed object: `self` itself, or a member of self.
                targetIsSelf = isSelf(member.base)
                if let base = member.base {
                    receiverIsSelfMember = memberOfSelfName(base) != nil
                }
            case "addPeriodicTimeObserver":
````

Replace it with:

````swift
                kind = .kvoObserve
                closureLabels = ["changeHandler"]
            case "addPeriodicTimeObserver":
````

### Edit 2: `Sources/ArcLeakCore/Facts/APICallFact.swift`

Find this exact text (it occurs once in the file):

````swift
    /// True when a `target:`/`on:`/`delegate:` style argument is literally `self`
    /// (for `observe(\.keyPath)`: the observed object is `self`).
    public let targetIsSelf: Bool
````

Replace it with:

````swift
    /// True when a `target:`/`on:`/`delegate:` style argument is literally `self`.
    public let targetIsSelf: Bool
````

### Edit 3: `Sources/ArcLeakCore/Rules/KVOObservationSelfCycleRule.swift`

Find this exact text (it occurs once in the file):

````swift
/// `self.observation = player.observe(\.rate) { _, _ in self.… }` — the
/// NSKeyValueObservation keeps its change handler, the handler keeps `self`,
/// and `self` keeps the observation: a closed cycle, the sink proof applied to
/// KVO. Foundation: "invalidate() will be called automatically when an
/// NSKeyValueObservation is deinited" — which never happens inside the cycle.
///
/// Gated on the observed object being `self` or a member of `self`, the shape
/// of the public fixes (wikipedia-ios@9db7aa718d); the observation token must
/// be stored on `self`.
struct KVOObservationSelfCycleRule: Rule {
    static let emits: [RuleID] = [.kvoObservationSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        return type.apiCalls.compactMap { call in
            guard call.kind == .kvoObserve,
                call.targetIsSelf || call.receiverIsSelfMember,
                call.closureSelfCapture?.isStrong == true,
                call.consumption.storesIntoSelf
            else { return nil }
````

Replace it with:

````swift
/// `self.observation = player.observe(\.rate) { _, _ in self.… }` — the
/// NSKeyValueObservation keeps its change handler, the handler keeps `self`,
/// and `self` keeps the observation: a closed cycle, the sink proof applied to
/// KVO. Foundation: "invalidate() will be called automatically when an
/// NSKeyValueObservation is deinited" — which never happens inside the cycle.
///
/// The cycle runs through the observation, so any observed object counts
/// (a member of `self`, `self`, a parameter); the observation token must be
/// stored on `self`. A public fix of this shape: wikipedia-ios@9db7aa718d.
/// A reachable `invalidate()` in the type means a managed lifecycle (silent),
/// as for timers.
struct KVOObservationSelfCycleRule: Rule {
    static let emits: [RuleID] = [.kvoObservationSelfCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.invalidate) else { return [] }
        return type.apiCalls.compactMap { call in
            guard call.kind == .kvoObserve,
                call.closureSelfCapture?.isStrong == true,
                call.consumption.storesIntoSelf
            else { return nil }
````

### Edit 4: `Sources/ArcLeakCore/Rules/KVOObservationSelfCycleRule.swift`

Find this exact text (it occurs once in the file):

````swift
                    "the observation invalidates only when deinited, which the cycle prevents; capture [weak self] in the change handler, or invalidate() it from a reachable path"
````

Replace it with:

````swift
                    "the observation invalidates only when deinited, which the cycle prevents; capture [weak self] in the change handler, or invalidate() and release (set to nil) the observation from a reachable path"
````

### Edit 5: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            `self.observation = object.observe(\\.keyPath) { … self … }`, where the
            observed object is `self` or one of its members. The returned
            NSKeyValueObservation keeps its change handler, which keeps `self`, which
            keeps the observation: self → observation → change handler → self.
            Foundation, NSKeyValueObservation.invalidate(): "invalidate() will be
            called automatically when an NSKeyValueObservation is deinited" — and the
            observation is deinited only after `self`, which the cycle prevents.

            Fix: `[weak self]` in the change handler, or invalidate() the observation
            from a reachable path. A public fix of this shape:
            wikipedia-ios@9db7aa718d.
````

Replace it with:

````swift
            `self.observation = object.observe(\\.keyPath) { … self … }`, whatever the
            observed object is: the cycle runs through the observation, not through
            the observed object. The returned NSKeyValueObservation keeps its change
            handler, which keeps `self`, which keeps the observation: self →
            observation → change handler → self. Foundation,
            NSKeyValueObservation.invalidate(): "invalidate() will be called
            automatically when an NSKeyValueObservation is deinited" — and the
            observation is deinited only after `self`, which the cycle prevents.

            A reachable `invalidate()` in the type silences the rule, as it does for
            timers. invalidate() stops the notifications, but the observation keeps
            its handler until it is released (apple/swift@d6b4691dc8,
            NSObject.swift), so release it too.

            Fix: `[weak self]` in the change handler, or invalidate() and release
            (`observation = nil`) the observation from a reachable path. A public fix
            of this shape: wikipedia-ios@9db7aa718d.
````

### Edit 6: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `kvo-observation-self-cycle` | warning | `self.<obs> = <x>.observe(\.keyPath) { … self … }` where `<x>` is `self` or a member of `self` and the change handler captures `self` strongly |
````

Replace it with:

````markdown
| `kvo-observation-self-cycle` | warning | `self.<obs> = <x>.observe(\.keyPath) { … self … }` (any observed object `<x>`) whose change handler captures `self` strongly, with no reachable `invalidate()` in the type |
````

### Edit 7: `Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift`

Find this exact text (it occurs once in the file):

````swift
// self → NSKeyValueObservation → change handler → self. The observation
// invalidates only when deinited, which happens after self's deinit — never,
// inside the cycle. A public fix of this shape: wikipedia-ios@9db7aa718d.
final class PlayerObserver: NSObject {
    let player = AVPlayer()
    @objc dynamic var progress = 0.0
    var rateObservation: NSKeyValueObservation?
    var progressObservation: NSKeyValueObservation?

    func start() {
        rateObservation = player.observe(\.rate) { _, _ in // #al:expect kvo-observation-self-cycle
            self.update()
        }
        self.progressObservation = self.observe(\.progress, options: [.new], changeHandler: { _, _ in self.update() }) // #al:expect kvo-observation-self-cycle
    }
````

Replace it with:

````swift
// self → NSKeyValueObservation → change handler → self. The observation
// invalidates only when deinited, which happens after self's deinit — never,
// inside the cycle. A public fix of this shape: wikipedia-ios@9db7aa718d.
// The observed object does not matter: the cycle runs through the
// observation, so observing a parameter closes it too.
final class PlayerObserver: NSObject {
    let player = AVPlayer()
    @objc dynamic var progress = 0.0
    var rateObservation: NSKeyValueObservation?
    var progressObservation: NSKeyValueObservation?
    var otherObservation: NSKeyValueObservation?

    func start() {
        rateObservation = player.observe(\.rate) { _, _ in // #al:expect kvo-observation-self-cycle
            self.update()
        }
        self.progressObservation = self.observe(\.progress, options: [.new], changeHandler: { _, _ in self.update() }) // #al:expect kvo-observation-self-cycle
    }

    func follow(_ other: AVPlayer) {
        otherObservation = other.observe(\.rate) { _, _ in // #al:expect kvo-observation-self-cycle
            self.update()
        }
    }
````

### Edit 8: `Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift`

Find this exact text (it occurs once in the file):

````swift
// KVO observations that do not close a cycle: [weak self] in the handler, a
// handler that never touches self, and an observed object that self does not
// keep (a parameter).
final class QuietObserver: NSObject {
    let player = AVPlayer()
    var rateObservation: NSKeyValueObservation?
    var itemObservation: NSKeyValueObservation?
    var otherObservation: NSKeyValueObservation?

    func start(other: AVPlayer) {
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            self?.update()
        }
        itemObservation = player.observe(\.currentItem) { player, _ in
            print(player.rate)
        }
        otherObservation = other.observe(\.rate) { _, _ in
            self.update()
        }
    }

    func update() {}
}
````

Replace it with:

````swift
// KVO observations that do not close a cycle: [weak self] in the handler,
// and a handler that never touches self.
final class QuietObserver: NSObject {
    let player = AVPlayer()
    var rateObservation: NSKeyValueObservation?
    var itemObservation: NSKeyValueObservation?

    func start() {
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            self?.update()
        }
        itemObservation = player.observe(\.currentItem) { player, _ in
            print(player.rate)
        }
    }

    func update() {}
}

// A managed lifecycle: stop() invalidates and releases the observation from a
// reachable path, which drops the handler and with it the hold on self.
final class ManagedObserver: NSObject {
    let player = AVPlayer()
    var rateObservation: NSKeyValueObservation?

    func start() {
        rateObservation = player.observe(\.rate) { _, _ in
            self.update()
        }
    }

    func stop() {
        rateObservation?.invalidate()
        rateObservation = nil
    }

    func update() {}
}
````

### Edit 9: `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift`

Find this exact text (it occurs once in the file):

````swift
    func handle(_ value: Int) {}
    func reset() {}

    deinit {
        continuation?.finish()
        consumer?.cancel()
    }
}
````

Replace it with:

````swift
    func handle(_ value: Int) {}
    func reset() {}

    deinit {
        continuation?.finish()
        consumer?.cancel()
    }
}

// Gap 9: a KVO observation invalidated from a reachable stop() but never
// released. invalidate() stops the notifications, but the observation keeps
// its change handler until it is deallocated (apple/swift@d6b4691dc8,
// stdlib/public/Darwin/Foundation/NSObject.swift), so self → observation →
// handler → self stays. kvo-observation-self-cycle treats a reachable
// invalidate() as a managed lifecycle, as timer-retains-self does.
final class RateWatcher: NSObject {
    let player = AVPlayer()
    var observation: NSKeyValueObservation?

    func start() {
        observation = player.observe(\.rate) { _, _ in
            self.refresh()
        }
    }

    func stop() {
        observation?.invalidate()
    }

    func refresh() {}
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 198 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift --no-cache; echo EXIT=$?'`. Expected: the summary line `arcleak: 3 finding(s) (0 error(s), 3 warning(s)) in 3 file(s)`, then 3 `warning: [kvo-observation-self-cycle]` lines at `KVOObservationSelf.swift` lines 18, 21 and 25; nothing in the two Clean files; then `EXIT=0`.
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 80 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M`, `D` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/APICallFact.swift Sources/ArcLeakCore/Rules/KVOObservationSelfCycleRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "fix: flag KVO self cycles on any observed object

The cycle self -> observation -> change handler -> self runs through the
NSKeyValueObservation, not through the observed object, so the gate on the
observed object being self or a member of self hid real cycles: the Clean
twin asserted a parameter observation with a strong-self handler as clean.
The gate is gone; the strong-self handler and the token stored on self are
still required. A reachable invalidate() in the type now silences the rule,
as it does for timer-retains-self, and the note says to release the
observation as well, since invalidate() keeps the handler
(apple/swift@d6b4691dc8).

The parameter case moves to Leaks/KVOObservationSelf, Clean/KVOObservationWeak
gains an invalidated-and-released observation, and KnownGaps records an
observation invalidated but never released (gap 9). 198 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `fix: flag KVO self cycles on any observed object`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

