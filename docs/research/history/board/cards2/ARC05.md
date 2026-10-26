# ARC05 — new rule kvo-observation-self-cycle

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 5 of 10 (after ARC04; next ARC06)

Task item 5. `self.<obs> = <x>.observe(\.keyPath, …) { … self … }` with `<x>` `self` or a member of self (the `observe` KB match now fills `targetIsSelf` / `receiverIsSelfMember`). Default warning. Proof text quotes Foundation's NSKeyValueObservation.invalidate() page (apple-docs): "invalidate() will be called automatically when an NSKeyValueObservation is deinited"; public fix wikipedia-ios@9db7aa718d (verified with `gh api`: `observation = task.observe(\.state, changeHandler: { … self.finish() })` → `[weak self]`).

- **Model:** haiku, low. **Size:** about 110 lines (code about 55). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `matchKnowledgeBase`, the `case "observe"` branch
  - `Sources/ArcLeakCore/Facts/APICallFact.swift`: doc comment of `targetIsSelf`
  - `Sources/ArcLeakCore/Rules/Rule.swift`: `RuleEngine.rules`
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: new case `kvoObservationSelfCycle`, `defaultSeverity`, `summary`, `explanation`
  - new `Sources/ArcLeakCore/Rules/KVOObservationSelfCycleRule.swift`
  - `README.md`: new Rules table row before `dead-weak-capture`
  - new `Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift`, new `Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift`

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `dispatch-source-cycle` | error | dispatch source stored on `self` whose handler captures `self` strongly, no reachable `cancel()` |
| `unowned-outlives-owner` | warning | `[unowned self]` in an anchor-held closure — traps if `self` deallocates first |
| `webview-script-handler-cycle` | warning† | `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`) with no reachable `removeScriptMessageHandler(forName:)` or `removeAllScriptMessageHandlers()` |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |

````

Replace it with:

````markdown
| `dispatch-source-cycle` | error | dispatch source stored on `self` whose handler captures `self` strongly, no reachable `cancel()` |
| `unowned-outlives-owner` | warning | `[unowned self]` in an anchor-held closure — traps if `self` deallocates first |
| `webview-script-handler-cycle` | warning† | `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`) with no reachable `removeScriptMessageHandler(forName:)` or `removeAllScriptMessageHandlers()` |
| `kvo-observation-self-cycle` | warning | `self.<obs> = <x>.observe(\.keyPath) { … self … }` where `<x>` is `self` or a member of `self` and the change handler captures `self` strongly |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |

````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    case deadWeakCapture = "dead-weak-capture"
    case delegateStrongProperty = "delegate-strong-property"
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

Replace it with:

````swift
    case deadWeakCapture = "dead-weak-capture"
    case delegateStrongProperty = "delegate-strong-property"
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"
    case kvoObservationSelfCycle = "kvo-observation-self-cycle"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        case .timerRetainsSelf, .notificationObserverLeak, .taskNonterminatingSelf,
            .unstoredLifetimeToken, .tokenStoredInLocal, .mutualStrongProperties,
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle:
            .warning
        }
    }
````

Replace it with:

````swift
        case .timerRetainsSelf, .notificationObserverLeak, .taskNonterminatingSelf,
            .unstoredLifetimeToken, .tokenStoredInLocal, .mutualStrongProperties,
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle, .kvoObservationSelfCycle:
            .warning
        }
    }
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            "Strong stored property named/typed like a delegate — likely back-reference cycle (opt-in)"
        case .webviewScriptHandlerCycle:
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        }
    }

````

Replace it with:

````swift
            "Strong stored property named/typed like a delegate — likely back-reference cycle (opt-in)"
        case .webviewScriptHandlerCycle:
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
        }
    }

````

### Edit 5: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            Fix: remove the handler from a reachable teardown path (viewDidDisappear,
            a close() method), or register a proxy that holds `self` weakly.
            """
        }
    }
}
````

Replace it with:

````swift
            Fix: remove the handler from a reachable teardown path (viewDidDisappear,
            a close() method), or register a proxy that holds `self` weakly.
            """
        case .kvoObservationSelfCycle:
            """
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
            """
        }
    }
}
````

### Edit 6: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
            case "observe" where node.arguments.first?.expression.is(KeyPathExprSyntax.self) == true:
                kind = .kvoObserve
                closureLabels = ["changeHandler"]
            case "addPeriodicTimeObserver":
                kind = .periodicTimeObserver
                closureLabels = ["using"]
````

Replace it with:

````swift
            case "observe" where node.arguments.first?.expression.is(KeyPathExprSyntax.self) == true:
                kind = .kvoObserve
                closureLabels = ["changeHandler"]
                // The observed object: `self` itself, or a member of self.
                targetIsSelf = isSelf(member.base)
                if let base = member.base {
                    receiverIsSelfMember = memberOfSelfName(base) != nil
                }
            case "addPeriodicTimeObserver":
                kind = .periodicTimeObserver
                closureLabels = ["using"]
````

### Edit 7: `Sources/ArcLeakCore/Facts/APICallFact.swift` (near `public struct APICallFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    public let position: SourcePosition
    /// `repeats:` argument when it is a boolean literal; nil when absent/dynamic.
    public let repeats: Bool?
    /// True when a `target:`/`on:`/`delegate:` style argument is literally `self`.
    public let targetIsSelf: Bool
    /// True when the call's receiver is a stored member of the enclosing type
    /// (`self.source.setEventHandler { … }`) — the edge self → receiver exists.
````

Replace it with:

````swift
    public let position: SourcePosition
    /// `repeats:` argument when it is a boolean literal; nil when absent/dynamic.
    public let repeats: Bool?
    /// True when a `target:`/`on:`/`delegate:` style argument is literally `self`
    /// (for `observe(\.keyPath)`: the observed object is `self`).
    public let targetIsSelf: Bool
    /// True when the call's receiver is a stored member of the enclosing type
    /// (`self.source.setEventHandler { … }`) — the edge self → receiver exists.
````

### New file `Sources/ArcLeakCore/Rules/KVOObservationSelfCycleRule.swift`

Create it with exactly this content (ending with one newline):

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
            return Finding(
                rule: .kvoObservationSelfCycle,
                severity: configuration.severity(for: .kvoObservationSelfCycle),
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "retain cycle: the KVO change handler captures self strongly and the NSKeyValueObservation is stored on self (self → observation → handler → self)",
                note:
                    "the observation invalidates only when deinited, which the cycle prevents; capture [weak self] in the change handler, or invalidate() it from a reachable path"
            )
        }
    }
}
````

### Edit 8: `Sources/ArcLeakCore/Rules/Rule.swift` (near `public enum RuleEngine {`)

Find this exact text (it occurs once in the file):

````swift
        DeadWeakCaptureRule.self,
        DelegateStrongPropertyRule.self,
        WebViewScriptHandlerRule.self,
    ]

    private static let corpusRules: [any CorpusRule.Type] = [
````

Replace it with:

````swift
        DeadWeakCaptureRule.self,
        DelegateStrongPropertyRule.self,
        WebViewScriptHandlerRule.self,
        KVOObservationSelfCycleRule.self,
    ]

    private static let corpusRules: [any CorpusRule.Type] = [
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import AVFoundation
import Foundation

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

### New file `Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import AVFoundation
import Foundation

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

    func update() {}
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 193 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 81 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Fixture probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/DiscardedTokens.swift --no-cache; echo EXIT=$?'`. Expected: the summary line `arcleak: 6 finding(s) (0 error(s), 6 warning(s)) in 3 file(s)`; exactly two `warning: [kvo-observation-self-cycle]` lines, at `KVOObservationSelf.swift` lines 15 and 18; none for `KVOObservationWeak.swift`; the other four lines are the unchanged `DiscardedTokens.swift` findings (`unstored-lifetime-token` / `token-stored-in-local`); then `EXIT=0`.
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/APICallFact.swift Sources/ArcLeakCore/Rules/KVOObservationSelfCycleRule.swift Sources/ArcLeakCore/Rules/Rule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/KVOObservationWeak.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/KVOObservationSelf.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: add kvo-observation-self-cycle

self.<observation> = <object>.observe(keyPath) { ... self ... }, where the
observed object is self or a member of self, closes a cycle: the
NSKeyValueObservation keeps its change handler, the handler keeps self and
self keeps the observation. Foundation documents that invalidate() is
called automatically when the observation is deinited, which the cycle
prevents. A public fix of this shape is wikipedia-ios@9db7aa718d.

Default warning. Leaks/KVOObservationSelf (2 findings) and
Clean/KVOObservationWeak pin it; the discarded and local-token cases of
Leaks/DiscardedTokens are unchanged; 193 tests pass."'
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
