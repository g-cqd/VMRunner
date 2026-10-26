# ARC07 — security pack 2/3: opt-in sec-session-in-cycle (annotation)

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 7 of 10 (after ARC06; next ARC08)

Task item 6, second rule. Decision: an extra note line on the existing cycle findings, not a new finding (the existing `Finding.adding(note:)` makes it a few lines, and the note is outside the fingerprint so baselines keep matching). When `rules.sec-session-in-cycle.enabled` is true, every finding of a `keepsSelfAlive` rule on a type that keeps a `WKWebView`, `LAContext`, `ASWebAuthenticationSession` (strong stored property by declared type name), registers a script message handler, or creates a `URLSession` with a delegate, gets `security (sec-session-in-cycle, CWE-401): this cycle keeps … alive with '<Type>' …`.

- **Model:** haiku, low. **Size:** about 120 lines (code about 50). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Rules/SecurityPack.swift`: doc comment, `apply` (new `isEnabled(.secSessionInCycle)` block), new `sensitiveHeld(by:)` before `cleanupDescriptions`
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: new case `secSessionInCycle`, `defaultSeverity`, `enabledByDefault`, `summary`, `explanation`
  - `README.md`: new Rules row before `sec-cleanup-in-unreachable-deinit`; the Security pack paragraph example
  - `Tests/ArcLeakCoreTests/OptInRulesTests.swift`: new `webSource` and test at the end

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `kvo-observation-self-cycle` | warning | `self.<obs> = <x>.observe(\.keyPath) { … self … }` where `<x>` is `self` or a member of `self` and the change handler captures `self` strongly |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |
| `sec-cleanup-in-unreachable-deinit` | note, opt-in | security (CWE-401, CWE-226): a `deinit` that wipes bytes, invalidates a session, closes a handle or cancels work, in a type kept alive by a cycle reported on that type |

Security pack: the `sec-` rules ship disabled and are enabled one by one in
`.arcleak.json`, like the other opt-in rules (`{"rules":
{"sec-cleanup-in-unreachable-deinit": {"enabled": true}}}`). There is no
separate switch. A configuration that names them is rejected by arcleak
0.10.2 and earlier as an unknown rule id.

````

Replace it with:

````markdown
| `kvo-observation-self-cycle` | warning | `self.<obs> = <x>.observe(\.keyPath) { … self … }` where `<x>` is `self` or a member of `self` and the change handler captures `self` strongly |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |
| `sec-session-in-cycle` | opt-in tag | security (CWE-401): adds a note to each cycle finding on a type that keeps a `WKWebView`, `LAContext`, `ASWebAuthenticationSession` or a `URLSession` with a delegate; no finding of its own |
| `sec-cleanup-in-unreachable-deinit` | note, opt-in | security (CWE-401, CWE-226): a `deinit` that wipes bytes, invalidates a session, closes a handle or cancels work, in a type kept alive by a cycle reported on that type |

Security pack: the `sec-` rules ship disabled and are enabled one by one in
`.arcleak.json`, like the other opt-in rules (`{"rules":
{"sec-cleanup-in-unreachable-deinit": {"enabled": true},
"sec-session-in-cycle": {"enabled": true}}}`). There is no
separate switch. A configuration that names them is rejected by arcleak
0.10.2 and earlier as an unknown rule id.

````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"
    case kvoObservationSelfCycle = "kvo-observation-self-cycle"
    case secCleanupInUnreachableDeinit = "sec-cleanup-in-unreachable-deinit"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

Replace it with:

````swift
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"
    case kvoObservationSelfCycle = "kvo-observation-self-cycle"
    case secCleanupInUnreachableDeinit = "sec-cleanup-in-unreachable-deinit"
    case secSessionInCycle = "sec-session-in-cycle"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle, .kvoObservationSelfCycle:
            .warning
        case .secCleanupInUnreachableDeinit:
            .note
        }
    }
````

Replace it with:

````swift
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle, .kvoObservationSelfCycle:
            .warning
        case .secCleanupInUnreachableDeinit, .secSessionInCycle:
            .note
        }
    }
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    /// Opt-in rules ship disabled; enable per-rule in `.arcleak.json`.
    public var enabledByDefault: Bool {
        switch self {
        case .deadWeakCapture, .delegateStrongProperty, .secCleanupInUnreachableDeinit: false
        default: true
        }
    }
````

Replace it with:

````swift
    /// Opt-in rules ship disabled; enable per-rule in `.arcleak.json`.
    public var enabledByDefault: Bool {
        switch self {
        case .deadWeakCapture, .delegateStrongProperty, .secCleanupInUnreachableDeinit, .secSessionInCycle:
            false
        default: true
        }
    }
````

### Edit 5: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .secCleanupInUnreachableDeinit:
            "deinit wipes bytes, invalidates a session, closes a handle or cancels work in a type kept alive by a reported cycle (opt-in)"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
        }
````

Replace it with:

````swift
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .secCleanupInUnreachableDeinit:
            "deinit wipes bytes, invalidates a session, closes a handle or cancels work in a type kept alive by a reported cycle (opt-in)"
        case .secSessionInCycle:
            "Tags cycle findings on a type holding a WKWebView, LAContext, ASWebAuthenticationSession or delegate URLSession (opt-in)"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
        }
````

### Edit 6: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            Fix: break the cycle, and move cleanup that must happen to a reachable
            teardown path (logout, close(), viewDidDisappear).
            """
        }
    }
}
````

Replace it with:

````swift
            Fix: break the cycle, and move cleanup that must happen to a reachable
            teardown path (logout, close(), viewDidDisappear).
            """
        case .secSessionInCycle:
            """
            Security pack, opt-in (CWE-401). A cycle that keeps a web view, an
            LAContext, an ASWebAuthenticationSession or a URL session with a
            delegate alive keeps authenticated state alive past the screen or flow
            that owned it. This rule adds no finding of its own: when enabled, every
            cycle finding on a type that keeps one of those objects (a strong stored
            property of that declared type, a script message handler registration, a
            URLSession created with a delegate) gets a note naming them.

            Types are matched by name; cross-type cycles of mutual-strong-properties
            are not tagged.

            Enable with `{"rules": {"sec-session-in-cycle": {"enabled": true}}}`
            (arcleak 0.10.2 and earlier reject the id).

            Fix: break the cycle the note is attached to.
            """
        }
    }
}
````

### Edit 7: `Sources/ArcLeakCore/Rules/SecurityPack.swift`

Find this exact text (it occurs once in the file):

````swift
/// `sec-cleanup-in-unreachable-deinit` (CWE-401, CWE-226): the type's deinit
/// wipes bytes, invalidates, closes, cancels or removes something, and a cycle
/// reported on the same type keeps it alive, so that cleanup never runs.
enum SecurityPack {
    /// Findings meaning "this instance can never deinit": a cycle through
    /// `self`, or an anchor (run loop, notification center, session, user
````

Replace it with:

````swift
/// `sec-cleanup-in-unreachable-deinit` (CWE-401, CWE-226): the type's deinit
/// wipes bytes, invalidates, closes, cancels or removes something, and a cycle
/// reported on the same type keeps it alive, so that cleanup never runs.
///
/// `sec-session-in-cycle` (CWE-401): a tag, not a finding of its own. When the
/// type holds a web view, an authentication context or session, or a URL
/// session with a delegate, each cycle finding on it gets a note saying what
/// the cycle keeps alive.
enum SecurityPack {
    /// Findings meaning "this instance can never deinit": a cycle through
    /// `self`, or an anchor (run loop, notification center, session, user
````

### Edit 8: `Sources/ArcLeakCore/Rules/SecurityPack.swift` (near `enum SecurityPack {`)

Find this exact text (it occurs once in the file):

````swift
    ) -> [Finding] {
        guard let cycle = findings.filter({ keepsSelfAlive.contains($0.rule) }).min() else { return findings }
        var result = findings
        if configuration.isEnabled(.secCleanupInUnreachableDeinit),
            let cleanup = unreachableCleanup(type: type, cycle: cycle, path: path, configuration: configuration)
        {
````

Replace it with:

````swift
    ) -> [Finding] {
        guard let cycle = findings.filter({ keepsSelfAlive.contains($0.rule) }).min() else { return findings }
        var result = findings
        if configuration.isEnabled(.secSessionInCycle) {
            let held = sensitiveHeld(by: type)
            if !held.isEmpty {
                let tag =
                    "security (sec-session-in-cycle, CWE-401): this cycle keeps \(held.joined(separator: ", ")) alive with '\(type.name)' — authenticated state outlives the object that owns it"
                result = result.map { keepsSelfAlive.contains($0.rule) ? $0.adding(note: tag) : $0 }
            }
        }
        if configuration.isEnabled(.secCleanupInUnreachableDeinit),
            let cleanup = unreachableCleanup(type: type, cycle: cycle, path: path, configuration: configuration)
        {
````

### Edit 9: `Sources/ArcLeakCore/Rules/SecurityPack.swift` (near `enum SecurityPack {`)

Find this exact text (it occurs once in the file):

````swift
        )
    }

    /// In report order.
    private static let cleanupDescriptions: [(kind: ReleaseSite.Kind, text: String)] = [
        (.zeroBytes, "wipes memory"),
````

Replace it with:

````swift
        )
    }

    /// Sensitive objects the type keeps, by declared type name (SDK types are
    /// matched by name: no index is needed). A URL session counts only when
    /// the type creates one with a delegate; a web view also counts when the
    /// type registers a script message handler.
    private static func sensitiveHeld(by type: TypeFacts) -> [String] {
        let declared = Set(
            type.storedProperties.filter { $0.strength == .strong }.flatMap(\.referencedTypeNames)
        )
        var held: [String] = []
        if declared.contains("WKWebView") || type.apiCalls.contains(where: { $0.kind == .scriptMessageHandlerAdd }) {
            held.append("a WKWebView")
        }
        if declared.contains("LAContext") {
            held.append("an LAContext")
        }
        if declared.contains("ASWebAuthenticationSession") {
            held.append("an ASWebAuthenticationSession")
        }
        if type.apiCalls.contains(where: { $0.kind == .urlSessionWithDelegate }) {
            held.append("a URLSession with a delegate")
        }
        return held
    }

    /// In report order.
    private static let cleanupDescriptions: [(kind: ReleaseSite.Kind, text: String)] = [
        (.zeroBytes, "wipes memory"),
````

### Edit 10: `Tests/ArcLeakCoreTests/OptInRulesTests.swift` (near `import Testing`)

Find this exact text (it occurs once in the file):

````swift
        #expect(cleanup.message.contains("deinit of 'KeyVault' wipes memory"))
        #expect(cleanup.message.contains("stored-closure-strong-self"))
    }
}
````

Replace it with:

````swift
        #expect(cleanup.message.contains("deinit of 'KeyVault' wipes memory"))
        #expect(cleanup.message.contains("stored-closure-strong-self"))
    }

    private let webSource = """
        import WebKit

        final class LoginController {
            let webView = WKWebView()
            var onDone: (() -> Void)?

            func arm() {
                onDone = { self.finish() }
            }

            func finish() {}
        }

        final class PlainController {
            var onDone: (() -> Void)?

            func arm() {
                onDone = { self.finish() }
            }

            func finish() {}
        }
        """

    @Test("sec-session-in-cycle tags cycle findings on a type holding a web view, and adds no finding")
    func secSessionTag() throws {
        let plain = Analyzer().analyze(source: webSource, path: "Login.swift").findings
        #expect(plain.map(\.rule) == [.storedClosureStrongSelf, .storedClosureStrongSelf])
        #expect(plain.allSatisfy { $0.note?.contains("sec-session-in-cycle") != true })

        let configuration = Configuration(rules: ["sec-session-in-cycle": .init(enabled: true)])
        let tagged = Analyzer(configuration: configuration)
            .analyze(source: webSource, path: "Login.swift").findings
        #expect(tagged.map(\.rule) == [.storedClosureStrongSelf, .storedClosureStrongSelf])
        let login = try #require(tagged.first { $0.line == 8 })
        let tag = "security (sec-session-in-cycle, CWE-401): this cycle keeps a WKWebView alive"
        #expect(login.note?.contains(tag) == true)
        let other = try #require(tagged.first { $0.line == 18 })
        #expect(other.note?.contains("sec-session-in-cycle") != true)
        // The note is not part of the fingerprint: baselines keep matching.
        #expect(login.fingerprint == plain.first { $0.line == 8 }?.fingerprint)
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 196 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak rules sec-session-in-cycle'` prints first `sec-session-in-cycle  [default: note]`.
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Rules/SecurityPack.swift Tests/ArcLeakCoreTests/OptInRulesTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: add the opt-in sec-session-in-cycle tag

A cycle that keeps a web view, an LAContext, an ASWebAuthenticationSession
or a URL session with a delegate alive keeps authenticated state alive past
the object that owned it (CWE-401). sec-session-in-cycle, disabled by
default and enabled through rules.<id>.enabled, adds a note to each cycle
finding on a type that keeps one of them, matched by declared type name,
script message handler registration or URLSession(configuration:delegate:).

It adds no finding of its own: the cycle is already reported, and the note
is outside the fingerprint, so baselines keep matching when it is turned
on. OptInRulesTests pins it; 196 tests pass."'
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
