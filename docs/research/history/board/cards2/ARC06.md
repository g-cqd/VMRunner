# ARC06 — security pack 1/3: opt-in sec-cleanup-in-unreachable-deinit

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 6 of 10 (after ARC05; next ARC07)

Task item 6, first rule. New `SecurityPack` (not a `Rule`: it reads the type's own findings) called from `RuleEngine.check(file:)` per type. When enabled through `.arcleak.json` `rules.sec-cleanup-in-unreachable-deinit.enabled` (no new key, no flag), a type with a deinit-only cleanup (new release kinds `zeroBytes` for `resetBytes`/`memset`/`memset_s` — also read from bare `memset(...)` calls — and `close` for `close`/`closeFile`, plus the existing invalidate/cancel/removeObserver/session/script-handler kinds) and a finding of a rule in `SecurityPack.keepsSelfAlive` gets one note-severity finding anchored on the first such finding. Limitation stated in the explanation: cross-type `mutual-strong-properties` cycles are not linked.

- **Model:** haiku, low. **Size:** about 210 lines (code about 120). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Facts/ReleaseSite.swift`: `enum Kind` (new cases `zeroBytes`, `close`), `init?(calleeName:)`
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `recordReleaseSiteIfAny`
  - `Sources/ArcLeakCore/Rules/Rule.swift`: `RuleEngine.check(file:configuration:systemEntryPoints:)` loop body
  - new `Sources/ArcLeakCore/Rules/SecurityPack.swift`
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: new case `secCleanupInUnreachableDeinit`, `defaultSeverity` (`.note`), `enabledByDefault` (false), `summary`, `explanation`
  - `README.md`: new Rules row after `delegate-strong-property`; new "Security pack" paragraph before "Bound method references"
  - new `Tests/ArcLeakCoreTests/Fixtures/Leaks/SecCleanupInUnreachableDeinit.swift`; `Tests/ArcLeakCoreTests/OptInRulesTests.swift` (suite doc comment, two new tests at the end)

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `kvo-observation-self-cycle` | warning | `self.<obs> = <x>.observe(\.keyPath) { … self … }` where `<x>` is `self` or a member of `self` and the change handler captures `self` strongly |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |

Bound method references (`handler = self.method`, `sink(receiveValue:
handle)`) and self-referencing local functions passed as values feed the same
````

Replace it with:

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

Bound method references (`handler = self.method`, `sink(receiveValue:
handle)`) and self-referencing local functions passed as values feed the same
````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    case delegateStrongProperty = "delegate-strong-property"
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"
    case kvoObservationSelfCycle = "kvo-observation-self-cycle"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

Replace it with:

````swift
    case delegateStrongProperty = "delegate-strong-property"
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"
    case kvoObservationSelfCycle = "kvo-observation-self-cycle"
    case secCleanupInUnreachableDeinit = "sec-cleanup-in-unreachable-deinit"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle, .kvoObservationSelfCycle:
            .warning
        }
    }

    /// Opt-in rules ship disabled; enable per-rule in `.arcleak.json`.
    public var enabledByDefault: Bool {
        switch self {
        case .deadWeakCapture, .delegateStrongProperty: false
        default: true
        }
    }
````

Replace it with:

````swift
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle, .kvoObservationSelfCycle:
            .warning
        case .secCleanupInUnreachableDeinit:
            .note
        }
    }

    /// Opt-in rules ship disabled; enable per-rule in `.arcleak.json`.
    public var enabledByDefault: Bool {
        switch self {
        case .deadWeakCapture, .delegateStrongProperty, .secCleanupInUnreachableDeinit: false
        default: true
        }
    }
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            "Strong stored property named/typed like a delegate — likely back-reference cycle (opt-in)"
        case .webviewScriptHandlerCycle:
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
        }
````

Replace it with:

````swift
            "Strong stored property named/typed like a delegate — likely back-reference cycle (opt-in)"
        case .webviewScriptHandlerCycle:
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .secCleanupInUnreachableDeinit:
            "deinit wipes bytes, invalidates a session, closes a handle or cancels work in a type kept alive by a reported cycle (opt-in)"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
        }
````

### Edit 5: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            from a reachable path. A public fix of this shape:
            wikipedia-ios@9db7aa718d.
            """
        }
    }
}
````

Replace it with:

````swift
            from a reachable path. A public fix of this shape:
            wikipedia-ios@9db7aa718d.
            """
        case .secCleanupInUnreachableDeinit:
            """
            Security pack, opt-in (CWE-401, CWE-226). A deinit that zeroes memory
            (`resetBytes(in:)`, `memset`), invalidates a session or timer, closes a
            handle, cancels work or removes an observer is cleanup the type relies
            on. When the same type is kept alive by a cycle arcleak reports
            (stored-closure-strong-self, combine-sink-self-cycle,
            task-nonterminating-self, …), deinit never runs: secrets stay in memory,
            sessions stay valid, handles stay open. The finding is a note anchored
            on the cycle finding it depends on.

            Covers the cycles reported per type; the cross-type cycles of
            mutual-strong-properties are not linked to deinit bodies.

            Enable with `{"rules": {"sec-cleanup-in-unreachable-deinit": {"enabled":
            true}}}` (arcleak 0.10.2 and earlier reject the id).

            Fix: break the cycle, and move cleanup that must happen to a reachable
            teardown path (logout, close(), viewDidDisappear).
            """
        }
    }
}
````

### Edit 6: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
    }

    private func recordReleaseSiteIfAny(_ node: FunctionCallExprSyntax) {
        guard
            let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            let kind = ReleaseSite.Kind(calleeName: member.declName.baseName.text)
        else { return }
        let site = ReleaseSite(kind: kind, inDeinit: methodStack.last?.isDeinit ?? false)
        collected[typeStack.last ?? Self.fileScopeKey, default: CollectedFacts()]
            .releaseSites.append(site)
````

Replace it with:

````swift
    }

    private func recordReleaseSiteIfAny(_ node: FunctionCallExprSyntax) {
        let kind: ReleaseSite.Kind
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            let memberKind = ReleaseSite.Kind(calleeName: member.declName.baseName.text)
        {
            kind = memberKind
        } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
            ReleaseSite.Kind(calleeName: reference.baseName.text) == .zeroBytes
        {
            // `memset(buffer, 0, count)` is a free function. Only the
            // zeroing kind is read from bare calls: a bare `cancel()` is a
            // method of self, not a release of a stored handle.
            kind = .zeroBytes
        } else {
            return
        }
        let site = ReleaseSite(kind: kind, inDeinit: methodStack.last?.isDeinit ?? false)
        collected[typeStack.last ?? Self.fileScopeKey, default: CollectedFacts()]
            .releaseSites.append(site)
````

### Edit 7: `Sources/ArcLeakCore/Facts/ReleaseSite.swift` (near `public struct ReleaseSite: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        case removeObserver
        case sessionInvalidate
        case removeScriptMessageHandler

        public init?(calleeName: String) {
            switch calleeName {
````

Replace it with:

````swift
        case removeObserver
        case sessionInvalidate
        case removeScriptMessageHandler
        /// `resetBytes(in:)`, `memset`, `memset_s` — wiping memory, typically
        /// key material (only the deinit occurrences matter, to the opt-in
        /// `sec-cleanup-in-unreachable-deinit`).
        case zeroBytes
        /// `close()`, `closeFile()` — releasing a file, socket or database
        /// handle.
        case close

        public init?(calleeName: String) {
            switch calleeName {
````

### Edit 8: `Sources/ArcLeakCore/Facts/ReleaseSite.swift` (near `public struct ReleaseSite: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            case "invalidateAndCancel", "finishTasksAndInvalidate": self = .sessionInvalidate
            case "removeScriptMessageHandler", "removeAllScriptMessageHandlers":
                self = .removeScriptMessageHandler
            default: return nil
            }
        }
````

Replace it with:

````swift
            case "invalidateAndCancel", "finishTasksAndInvalidate": self = .sessionInvalidate
            case "removeScriptMessageHandler", "removeAllScriptMessageHandlers":
                self = .removeScriptMessageHandler
            case "resetBytes", "memset", "memset_s": self = .zeroBytes
            case "close", "closeFile": self = .close
            default: return nil
            }
        }
````

### Edit 9: `Sources/ArcLeakCore/Rules/Rule.swift` (near `public enum RuleEngine {`)

Find this exact text (it occurs once in the file):

````swift
        var findings: [Finding] = []
        for type in file.types {
            let isSystemEntryPoint = systemEntryPoints.contains(type.name)
            for rule in rules where rule.emits.contains(where: configuration.isEnabled) {
                let typeFindings = rule.check(type: type, path: file.path, configuration: configuration)
                    .filter { configuration.isEnabled($0.rule) }
                findings.append(
                    contentsOf: isSystemEntryPoint
                        ? typeFindings.map { ProjectContext.systemEntryPoint($0, typeName: type.name) }
                        : typeFindings
                )
            }
        }
        return findings.sorted()
    }
````

Replace it with:

````swift
        var findings: [Finding] = []
        for type in file.types {
            let isSystemEntryPoint = systemEntryPoints.contains(type.name)
            var typeFindings: [Finding] = []
            for rule in rules where rule.emits.contains(where: configuration.isEnabled) {
                typeFindings.append(
                    contentsOf: rule.check(type: type, path: file.path, configuration: configuration)
                        .filter { configuration.isEnabled($0.rule) }
                )
            }
            // The opt-in security pack reads the type's own findings.
            typeFindings = SecurityPack.apply(
                to: typeFindings,
                type: type,
                path: file.path,
                configuration: configuration
            )
            findings.append(
                contentsOf: isSystemEntryPoint
                    ? typeFindings.map { ProjectContext.systemEntryPoint($0, typeName: type.name) }
                    : typeFindings
            )
        }
        return findings.sorted()
    }
````

### New file `Sources/ArcLeakCore/Rules/SecurityPack.swift`

Create it with exactly this content (ending with one newline):

````swift
/// The opt-in security pack: rules that read the findings already reported
/// for a type rather than its facts alone. Each is disabled by default and
/// enabled through `rules.<id>.enabled` in `.arcleak.json`.
///
/// `sec-cleanup-in-unreachable-deinit` (CWE-401, CWE-226): the type's deinit
/// wipes bytes, invalidates, closes, cancels or removes something, and a cycle
/// reported on the same type keeps it alive, so that cleanup never runs.
enum SecurityPack {
    /// Findings meaning "this instance can never deinit": a cycle through
    /// `self`, or an anchor (run loop, notification center, session, user
    /// content controller) that holds `self` until a release deinit cannot
    /// reach.
    static let keepsSelfAlive: Set<RuleID> = [
        .storedClosureStrongSelf, .combineSinkSelfCycle, .combineAssignSelfCycle, .dispatchSourceCycle,
        .taskNonterminatingSelf, .timerRetainsSelf, .notificationObserverLeak, .urlSessionDelegateLeak,
        .webviewScriptHandlerCycle, .kvoObservationSelfCycle,
    ]

    /// `findings` (one type's, already filtered by configuration) plus the
    /// enabled security findings derived from them.
    static func apply(
        to findings: [Finding],
        type: TypeFacts,
        path: String,
        configuration: Configuration
    ) -> [Finding] {
        guard let cycle = findings.filter({ keepsSelfAlive.contains($0.rule) }).min() else { return findings }
        var result = findings
        if configuration.isEnabled(.secCleanupInUnreachableDeinit),
            let cleanup = unreachableCleanup(type: type, cycle: cycle, path: path, configuration: configuration)
        {
            result.append(cleanup)
        }
        return result
    }

    private static func unreachableCleanup(
        type: TypeFacts,
        cycle: Finding,
        path: String,
        configuration: Configuration
    ) -> Finding? {
        let kinds = Set(type.releaseSites.filter(\.inDeinit).map(\.kind))
        let actions = cleanupDescriptions.compactMap { kinds.contains($0.kind) ? $0.text : nil }
        guard !actions.isEmpty else { return nil }
        return Finding(
            rule: .secCleanupInUnreachableDeinit,
            severity: configuration.severity(for: .secCleanupInUnreachableDeinit),
            path: path,
            line: cycle.line,
            column: cycle.column,
            message:
                "security: deinit of '\(type.name)' \(actions.joined(separator: ", ")), but the \(cycle.rule.rawValue) finding here keeps '\(type.name)' alive, so that cleanup never runs",
            note:
                "CWE-401/CWE-226: break the cycle, and move cleanup that must happen (wiping secrets, invalidating sessions, closing handles) to a reachable teardown path"
        )
    }

    /// In report order.
    private static let cleanupDescriptions: [(kind: ReleaseSite.Kind, text: String)] = [
        (.zeroBytes, "wipes memory"),
        (.sessionInvalidate, "invalidates a URL session"),
        (.invalidate, "invalidates a timer or observation"),
        (.close, "closes a handle"),
        (.cancel, "cancels work"),
        (.removeObserver, "removes an observer"),
        (.removeScriptMessageHandler, "removes a script message handler"),
    ]
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Leaks/SecCleanupInUnreachableDeinit.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import Foundation

// A type that wipes its key in deinit, kept alive by a stored closure that
// captures self: deinit never runs, so the key is never wiped. By default
// only the cycle is reported; with the opt-in security pack enabled,
// sec-cleanup-in-unreachable-deinit adds a note on the same line
// (OptInRulesTests).
final class KeyVault {
    var key = Data(count: 32)
    var onChange: (() -> Void)?

    func arm() {
        onChange = { // #al:expect stored-closure-strong-self
            self.rotate()
        }
    }

    func rotate() {}

    deinit {
        key.resetBytes(in: 0..<key.count)
    }
}
````

### Edit 10: `Tests/ArcLeakCoreTests/OptInRulesTests.swift`

Find this exact text (it occurs once in the file):

````swift
import ArcLeakCore
import Testing

/// The two opt-in rules: disabled by default, precise when enabled.
@Suite struct OptInRulesTests {
    private let deadWeakSource = """
        final class Noisy {
````

Replace it with:

````swift
import ArcLeakCore
import Testing

/// The opt-in rules: disabled by default, precise when enabled.
@Suite struct OptInRulesTests {
    private let deadWeakSource = """
        final class Noisy {
````

### Edit 11: `Tests/ArcLeakCoreTests/OptInRulesTests.swift` (near `import Testing`)

Find this exact text (it occurs once in the file):

````swift
        #expect(findings.map(\.rule) == [.delegateStrongProperty])
        #expect(findings.first?.message.contains("'delegate'") == true)
    }
}
````

Replace it with:

````swift
        #expect(findings.map(\.rule) == [.delegateStrongProperty])
        #expect(findings.first?.message.contains("'delegate'") == true)
    }

    private let vaultSource = """
        import Foundation

        final class KeyVault {
            var key = Data(count: 32)
            var onChange: (() -> Void)?

            func arm() {
                onChange = { self.rotate() }
            }

            func rotate() {}

            deinit {
                key.resetBytes(in: 0..<key.count)
            }
        }

        final class Session {
            var handle: FileHandle?

            deinit {
                handle?.closeFile()
            }
        }
        """

    @Test("sec-cleanup-in-unreachable-deinit is silent by default")
    func secCleanupDisabledByDefault() {
        let findings = Analyzer().analyze(source: vaultSource, path: "Vault.swift").findings
        #expect(findings.map(\.rule) == [.storedClosureStrongSelf])
    }

    @Test("sec-cleanup-in-unreachable-deinit notes a deinit cleanup that a reported cycle makes unreachable")
    func secCleanupWhenEnabled() throws {
        let configuration = Configuration(
            rules: ["sec-cleanup-in-unreachable-deinit": .init(enabled: true)]
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: vaultSource, path: "Vault.swift").findings
        // Only KeyVault: Session closes its handle in deinit but no cycle keeps it alive.
        #expect(findings.map(\.rule) == [.secCleanupInUnreachableDeinit, .storedClosureStrongSelf])
        let cleanup = try #require(findings.first { $0.rule == .secCleanupInUnreachableDeinit })
        #expect(cleanup.severity == .note)
        #expect(cleanup.line == 8)
        #expect(cleanup.message.contains("deinit of 'KeyVault' wipes memory"))
        #expect(cleanup.message.contains("stored-closure-strong-self"))
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 195 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Opt-in probe. With the Write tool create `/tmp/arc-lane-sec.json` containing exactly `{"rules": {"sec-cleanup-in-unreachable-deinit": {"enabled": true}}}`. Then `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/SecCleanupInUnreachableDeinit.swift --no-cache --config /tmp/arc-lane-sec.json'` prints the summary line `arcleak: 2 finding(s) (1 error(s), 0 warning(s), 1 note(s)) in 1 file(s)`, with a `note: [sec-cleanup-in-unreachable-deinit] security: deinit of 'KeyVault' wipes memory` line at line 14 (exit status 1 is expected: the cycle is an error). Without `--config` the same command prints the summary line `arcleak: 1 finding(s) (1 error(s), 0 warning(s)) in 1 file(s)`. Then `/bin/bash --noprofile --norc -c 'rm /tmp/arc-lane-sec.json'`.
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/ReleaseSite.swift Sources/ArcLeakCore/Rules/Rule.swift Sources/ArcLeakCore/Rules/SecurityPack.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/SecCleanupInUnreachableDeinit.swift Tests/ArcLeakCoreTests/OptInRulesTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: add the opt-in sec-cleanup-in-unreachable-deinit rule

A deinit that wipes memory, invalidates a session or timer, closes a
handle, cancels work or removes an observer is cleanup a type relies on.
When a cycle arcleak reports on the same type keeps it alive, that deinit
never runs (CWE-401, CWE-226). The new rule, disabled by default and
enabled through rules.<id>.enabled in .arcleak.json, adds a note anchored
on the cycle finding. No configuration key or flag is added.

Deinit bodies now record resetBytes, memset, memset_s, close and closeFile
as release sites. The rule covers cycles reported per type; the cross-type
cycles of mutual-strong-properties are not linked to deinit bodies.

Leaks/SecCleanupInUnreachableDeinit keeps the default output to the cycle
alone; OptInRulesTests pins the opt-in note; 195 tests pass."'
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
