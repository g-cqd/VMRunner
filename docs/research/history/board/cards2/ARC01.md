# ARC01 — stored-closure-strong-self: closures stored on a child self owns

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 1 of 10 (first card; branch from main at 5c234f3; next ARC02)

Task item 1. `self.<p>.<q> = { … self … }` and `self.<p>.<q>.append { … }` close self → p → closure → self when `p` is a strong stored property of the enclosing type. The extraction records the store one level down with the child's name (`ownedChild`); `finish()` keeps it only when the child is a strong stored property whose declared type is not a struct or enum of the same file; the rule reports it as a warning (capped by the configured severity).

- **Model:** haiku, low. **Size:** about 160 lines (code about 90). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Facts/StoredClosureFact.swift`: `struct StoredClosureFact` (new field `ownedChild`, new init parameter with default)
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `func finish()` (filter), new `isOwnedReferenceChild` before `resolveUpstreams`, `override func visit(_ node: SequenceExprSyntax)`, `recordAppendedClosureIfAny`, new `ownedChildTarget` after it
  - `Sources/ArcLeakCore/Rules/StoredClosureStrongSelfRule.swift`: `static func check` (doc comment and owned-child branch)
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `summary` and `explanation` of `.storedClosureStrongSelf`
  - `README.md`: the `stored-closure-strong-self` row of the Rules table, and the footnote after the table
  - new `Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift`, new `Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift`

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown

| id | default | detects |
|---|---|---|
| `stored-closure-strong-self` | error | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` — including `self` captured only to feed a nested closure's `[weak self]` |
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
````

Replace it with:

````markdown

| id | default | detects |
|---|---|---|
| `stored-closure-strong-self` | error‡ | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly; also one level down, on a child `self` owns through a strong stored property (`self.toolbar.onTap = { self… }`, `.append`) |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` — including `self` captured only to feed a nested closure's `[weak self]` |
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
````

### Edit 2: `README.md` (near `capture pipeline as closures.`)

Find this exact text (it occurs once in the file):

````markdown
† upgraded to **error** when the only release call sits in `deinit` (or the
task handle is stored on `self`) — the release is unreachable by construction.

## Limits

Cross-file cycle detection covers the analyzed corpus: every file passed in
````

Replace it with:

````markdown
† upgraded to **error** when the only release call sits in `deinit` (or the
task handle is stored on `self`) — the release is unreachable by construction.

‡ the owned-child path reports a **warning**: a child may clear its callback
after firing, which the owner's source cannot show.

## Limits

Cross-file cycle detection covers the analyzed corpus: every file passed in
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    public var summary: String {
        switch self {
        case .storedClosureStrongSelf:
            "A closure stored on `self` captures `self` strongly — guaranteed retain cycle"
        case .timerRetainsSelf:
            "A repeating Timer/CADisplayLink retains `self` (run loop → timer → self) with no reachable invalidate()"
        case .notificationObserverLeak:
````

Replace it with:

````swift
    public var summary: String {
        switch self {
        case .storedClosureStrongSelf:
            "A closure stored on `self`, or on a child `self` owns, captures `self` strongly — retain cycle"
        case .timerRetainsSelf:
            "A repeating Timer/CADisplayLink retains `self` (run loop → timer → self) with no reachable invalidate()"
        case .notificationObserverLeak:
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            `[unowned self]` only when "the closure and the instance … will always be
            deallocated at the same time" (TSPL, Automatic Reference Counting).
            Value types are exempt: struct `self` is copied, not retained.
            """
        case .timerRetainsSelf:
            """
````

Replace it with:

````swift
            `[unowned self]` only when "the closure and the instance … will always be
            deallocated at the same time" (TSPL, Automatic Reference Counting).
            Value types are exempt: struct `self` is copied, not retained.

            One level down the proof is the same: `self.toolbar.onTap = { self… }`
            (or `.append`) where `toolbar` is a strong stored property of `self` gives
            self → toolbar → closure → self. Reported as a warning, since a child may
            clear its callback after firing. Weak or unowned children, children held
            in a local, and children typed as a struct or enum of the same file are
            not reported.
            """
        case .timerRetainsSelf:
            """
````

### Edit 5: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
            type.attributeNames = memberTable[name]?.typeAttributes ?? []
            type.deadWeakCaptures = collectedFacts.deadWeakCaptures
            type.storedProperties = collectedFacts.storedProperties
            type.storedClosures = collectedFacts.storedClosures
            type.apiCalls = Self.resolveUpstreams(
                collectedFacts.apiCalls,
                properties: collectedFacts.storedProperties
````

Replace it with:

````swift
            type.attributeNames = memberTable[name]?.typeAttributes ?? []
            type.deadWeakCaptures = collectedFacts.deadWeakCaptures
            type.storedProperties = collectedFacts.storedProperties
            type.storedClosures = collectedFacts.storedClosures.filter { closure in
                guard let child = closure.ownedChild else { return true }
                return isOwnedReferenceChild(child, properties: collectedFacts.storedProperties)
            }
            type.apiCalls = Self.resolveUpstreams(
                collectedFacts.apiCalls,
                properties: collectedFacts.storedProperties
````

### Edit 6: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
        return facts
    }

    /// Post-pass once the whole type is collected: an unknown upstream whose
    /// chain root is a subject-backed or `@Published` property is infinite.
    private static func resolveUpstreams(
````

Replace it with:

````swift
        return facts
    }

    /// A closure stored through `self.<child>.<member>` closes a cycle only
    /// when `self` owns the child: a strong stored property of this type. A
    /// child whose declared type is a struct or enum of this file is exempt;
    /// a child of unknown type (declared in another file or the SDK) counts.
    private func isOwnedReferenceChild(_ child: String, properties: [StoredPropertyFact]) -> Bool {
        guard let property = properties.first(where: { $0.name == child }),
            property.strength == .strong
        else { return false }
        guard let typeName = property.referencedTypeNames.first else { return true }
        return memberTable[typeName]?.isReferenceType != false
    }

    /// Post-pass once the whole type is collected: an unknown upstream whose
    /// chain root is a subject-backed or `@Published` property is infinite.
    private static func resolveUpstreams(
````

### Edit 7: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard
            elements.count == 3,
            elements[1].is(AssignmentExprSyntax.self),
            let member = memberOfSelfName(elements[0])
        else { return .visitChildren }

        if let closure = unwrapped(elements[2]).as(ClosureExprSyntax.self) {
            let analysis = ClosureCaptureAnalysis.analyze(
````

Replace it with:

````swift

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self) else { return .visitChildren }
        let member: String
        let ownedChild: String?
        if let name = memberOfSelfName(elements[0]) {
            member = name
            ownedChild = nil
        } else if let target = ownedChildTarget(elements[0]) {
            member = "\(target.child).\(target.member)"
            ownedChild = target.child
        } else {
            return .visitChildren
        }

        if let closure = unwrapped(elements[2]).as(ClosureExprSyntax.self) {
            let analysis = ClosureCaptureAnalysis.analyze(
````

### Edit 8: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
                StoredClosureFact(
                    position: position(of: closure),
                    targetMember: member,
                    selfCapture: analysis.selfCapture
                )
            )
        } else if strongCaptureEquivalent(elements[2]) {
````

Replace it with:

````swift
                StoredClosureFact(
                    position: position(of: closure),
                    targetMember: member,
                    selfCapture: analysis.selfCapture,
                    ownedChild: ownedChild
                )
            )
        } else if strongCaptureEquivalent(elements[2]) {
````

### Edit 9: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
                    position: position(of: elements[2]),
                    targetMember: member,
                    selfCapture: .strong(implicit: false),
                    isMethodReference: true
                )
            )
        }
````

Replace it with:

````swift
                    position: position(of: elements[2]),
                    targetMember: member,
                    selfCapture: .strong(implicit: false),
                    isMethodReference: true,
                    ownedChild: ownedChild
                )
            )
        }
````

### Edit 10: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
        guard
            let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            ["append", "insert"].contains(member.declName.baseName.text),
            let base = member.base,
            let collection = memberOfSelfName(base)
        else { return }

        var closure = node.trailingClosure
        if closure == nil {
````

Replace it with:

````swift
        guard
            let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            ["append", "insert"].contains(member.declName.baseName.text),
            let base = member.base
        else { return }
        let collection: String
        let ownedChild: String?
        if let name = memberOfSelfName(base) {
            collection = name
            ownedChild = nil
        } else if let target = ownedChildTarget(base) {
            collection = "\(target.child).\(target.member)"
            ownedChild = target.child
        } else {
            return
        }

        var closure = node.trailingClosure
        if closure == nil {
````

### Edit 11: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
            StoredClosureFact(
                position: position(of: closure),
                targetMember: collection,
                selfCapture: analysis.selfCapture
            )
        )
    }

    /// `self.method`, a bare member-method name, or a self-referencing local
    /// function used as a VALUE — a strong capture of `self` with no
    /// capture-list syntax available.
````

Replace it with:

````swift
            StoredClosureFact(
                position: position(of: closure),
                targetMember: collection,
                selfCapture: analysis.selfCapture,
                ownedChild: ownedChild
            )
        )
    }

    /// `self.toolbar.onTap` / `toolbar?.onTap` / `toolbar!.onTap` → ("toolbar",
    /// "onTap") when `toolbar` is a member of `self` (not a shadowing local).
    /// Exactly one level: `self.a.b.c` is not matched.
    private func ownedChildTarget(_ expr: some ExprSyntaxProtocol) -> (child: String, member: String)? {
        guard let access = ExprSyntax(expr).as(MemberAccessExprSyntax.self), var base = access.base else {
            return nil
        }
        if let optional = base.as(OptionalChainingExprSyntax.self) {
            base = optional.expression
        } else if let forced = base.as(ForceUnwrapExprSyntax.self) {
            base = forced.expression
        }
        guard let child = memberOfSelfName(base) else { return nil }
        return (child, access.declName.baseName.text)
    }

    /// `self.method`, a bare member-method name, or a self-referencing local
    /// function used as a VALUE — a strong capture of `self` with no
    /// capture-list syntax available.
````

### Edit 12: `Sources/ArcLeakCore/Facts/StoredClosureFact.swift` (near `public struct StoredClosureFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    /// `handler = self.method` — a bound method value; no capture-list syntax
    /// exists, so the fix is wrapping in a closure.
    public let isMethodReference: Bool

    public init(
        position: SourcePosition,
        targetMember: String,
        selfCapture: SelfCaptureKind,
        isMethodReference: Bool = false
    ) {
        self.position = position
        self.targetMember = targetMember
        self.selfCapture = selfCapture
        self.isMethodReference = isMethodReference
    }
}
````

Replace it with:

````swift
    /// `handler = self.method` — a bound method value; no capture-list syntax
    /// exists, so the fix is wrapping in a closure.
    public let isMethodReference: Bool
    /// The stored property of `self` that holds the closure's owner when the
    /// closure is stored one level down (`self.toolbar.onTap = { … }` gives
    /// "toolbar"); nil when the closure is stored on `self` itself.
    public let ownedChild: String?

    public init(
        position: SourcePosition,
        targetMember: String,
        selfCapture: SelfCaptureKind,
        isMethodReference: Bool = false,
        ownedChild: String? = nil
    ) {
        self.position = position
        self.targetMember = targetMember
        self.selfCapture = selfCapture
        self.isMethodReference = isMethodReference
        self.ownedChild = ownedChild
    }
}
````

### Edit 13: `Sources/ArcLeakCore/Rules/StoredClosureStrongSelfRule.swift`

Find this exact text (it occurs once in the file):

````swift
/// instance strongly is a guaranteed retain cycle (self → property → closure →
/// self). Gated on the enclosing type being a known reference type: struct
/// `self` is copied into the closure and cannot cycle.
struct StoredClosureStrongSelfRule: Rule {
    static let emits: [RuleID] = [.storedClosureStrongSelf]

````

Replace it with:

````swift
/// instance strongly is a guaranteed retain cycle (self → property → closure →
/// self). Gated on the enclosing type being a known reference type: struct
/// `self` is copied into the closure and cannot cycle.
///
/// One level down, `self.toolbar.onTap = { self.… }` (or `.append`) closes the
/// same loop through a child `self` owns: self → toolbar → onTap → self. The
/// child must be a strong stored property of this type (extraction drops weak
/// or unowned children, locals, and children typed as a struct or enum of the
/// same file). Warning, not error: a child may clear its callback after
/// firing, which the source of `self` cannot show.
struct StoredClosureStrongSelfRule: Rule {
    static let emits: [RuleID] = [.storedClosureStrongSelf]

````

### Edit 14: `Sources/ArcLeakCore/Rules/StoredClosureStrongSelfRule.swift` (near `struct StoredClosureStrongSelfRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
        guard type.isReferenceType == true else { return [] }
        return type.storedClosures.compactMap { stored in
            guard stored.selfCapture.isStrong else { return nil }
            if stored.isMethodReference {
                return Finding(
                    rule: .storedClosureStrongSelf,
````

Replace it with:

````swift
        guard type.isReferenceType == true else { return [] }
        return type.storedClosures.compactMap { stored in
            guard stored.selfCapture.isStrong else { return nil }
            if let child = stored.ownedChild {
                let member = stored.targetMember.dropFirst(child.count + 1)
                let value = stored.isMethodReference ? "bound method reference" : "closure"
                return Finding(
                    rule: .storedClosureStrongSelf,
                    severity: min(configuration.severity(for: .storedClosureStrongSelf), .warning),
                    path: path,
                    line: stored.position.line,
                    column: stored.position.column,
                    message:
                        "\(value) stored in '\(stored.targetMember)' captures self strongly — retain cycle through an owned child: self → \(child) → \(member) → self",
                    note:
                        "self keeps '\(child)' in a strong stored property and '\(child)' keeps the closure; capture [weak self], or clear '\(stored.targetMember)' when it is done"
                )
            }
            if stored.isMethodReference {
                return Finding(
                    rule: .storedClosureStrongSelf,
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
// The owned-child shapes that do not close a cycle: [weak self], a child held
// only in a local, a weak child, a child typed as a struct of this file, and
// a member that is not a stored property of self.
final class Panel {
    var onTap: (() -> Void)?
}

struct PanelStyle {
    var onTap: (() -> Void)?
}

final class Host {
    let panel = Panel()
    weak var parentPanel: Panel?
    var style = PanelStyle()
    var computedPanel: Panel { Panel() }

    func setUp() {
        panel.onTap = { [weak self] in
            self?.refresh()
        }
        let local = Panel()
        local.onTap = { self.refresh() }
        parentPanel?.onTap = { self.refresh() }
        style.onTap = { self.refresh() }
        computedPanel.onTap = { self.refresh() }
    }

    func refresh() {}
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
// A closure stored on a child that self owns closes the same loop as one
// stored on self: self → toolbar → onTap → self. The fix is [weak self] in
// the closure, or clearing the callback once it has fired. Warning, not
// error: a child may drop its callback after firing.
final class Toolbar {
    var onTap: (() -> Void)?
    var actions: [() -> Void] = []
}

final class Screen {
    let toolbar = Toolbar()
    var footer: Toolbar?
    var count = 0

    func setUp() {
        toolbar.onTap = { // #al:expect stored-closure-strong-self
            self.reload()
        }
        self.footer?.onTap = { self.reload() } // #al:expect stored-closure-strong-self
        self.toolbar.actions.append { // #al:expect stored-closure-strong-self
            self.count += 1
        }
        toolbar.onTap = reload // #al:expect stored-closure-strong-self
    }

    func reload() {}
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 190 tests in 40 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 79 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Fixture probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift --no-cache; echo EXIT=$?'`. Expected: the output contains the summary line `arcleak: 4 finding(s) (0 error(s), 4 warning(s)) in 2 file(s)`, then 4 `warning: [stored-closure-strong-self]` lines at `OwnedChildClosure.swift` lines 17, 20, 21, 24 (messages contain `retain cycle through an owned child`), then `EXIT=0`.
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/StoredClosureFact.swift Sources/ArcLeakCore/Rules/StoredClosureStrongSelfRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: flag closures stored on a child self owns

A closure assigned to self.<child>.<member>, or appended to it, closes the
same loop as one stored on self when the child is a strong stored property:
self -> child -> closure -> self. stored-closure-strong-self now records
these one level down and reports them as warnings, since a child may clear
its callback after firing. Weak or unowned children, children held in a
local and children typed as a struct or enum of the same file stay silent.

Leaks/OwnedChildClosure (4 findings) and Clean/OwnedChildClosureWeak pin
both sides; 190 tests pass."'
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
