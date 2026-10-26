# ARC03 — combine-sink-self-cycle: Rx and SwiftSignalKit subscriptions (contract templates disposeBag, signalDisposable)

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 3 of 10 (after ARC02; next ARC04)

Task item 3. Two new `contracts` templates next to `tokenProducer`/`sinkWrapper`, plus built-in contracts for RxSwift `subscribe`/`bind`/`drive` (Disposable into `.disposed(by:)`/`addDisposableTo(_:)` on a member of self, or assigned to a member) and SwiftSignalKit `start(next:)` (passed to `self.<d>.set(_:)`/`.add(_:)` or assigned to a member). They produce a new `APICallFact.Kind.reactiveSubscription` that feeds only `combine-sink-self-cycle` (warning: completion unknown); finite sources (`Single`, `Completable`, `Maybe`, `as…`, `just`, `empty`, `first`, `take(1)`, `subscribe(onSuccess:)`) are silent. `producesLifetimeToken` is false: a dropped reactive Disposable does not end its subscription. This closes the planned gap 9, so KnownGaps gets no SwiftSignalKit entry (ARC10).

- **Model:** haiku, low. **Size:** about 330 lines (code about 160). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Config/Configuration.swift`: `contracts` doc comment, `UserContract.Template` (new cases `disposeBag`, `signalDisposable`)
  - `Sources/ArcLeakCore/Facts/APICallFact.swift`: `enum Kind` (new case `reactiveSubscription(String)`), `producesLifetimeToken`, `feedsSinkCycleRule`
  - `Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift`: `tokenName(for:)`, `consequence(for:)`
  - `Sources/ArcLeakCore/Rules/CombineSinkSelfCycleRule.swift`: doc comment, noun selection, note and message strings
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `matchUserContract` (guard and loop header; new `case .disposeBag, .signalDisposable`), new `builtInContracts`, `classifyReactiveConsumption`, `reactiveFiniteness`, `finiteReactiveMarkers` after it
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `summary` and `explanation` of `.combineSinkSelfCycle`
  - `README.md`: `combine-sink-self-cycle` row; two template bullets after the `sinkWrapper` bullet in "Custom retention contracts"
  - new `Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift`, `Tests/ArcLeakCoreTests/Fixtures/Leaks/SignalDisposableSelf.swift`, `Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift`, `Tests/ArcLeakCoreTests/ReactiveContractTests.swift`

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
  `.sink`. Because the real upstream is hidden inside the wrapper, completion is
  unknown, so the finding is a `warning` with an explicit "completion could not
  be determined" note rather than an over-claimed `error`.

With the contract above, `becomeInactiveTask = React.to(.willResignActive) { _ in
self.disconnect() }` (the `AnyCancellable` stored on `self`, the closure
````

Replace it with:

````markdown
  `.sink`. Because the real upstream is hidden inside the wrapper, completion is
  unknown, so the finding is a `warning` with an explicit "completion could not
  be determined" note rather than an over-claimed `error`.
- **`disposeBag`** — an RxSwift-style subscription whose closure is analyzed
  for strong-`self` capture and whose Disposable goes into a bag on `self`
  through a chained `.disposed(by:)` or `addDisposableTo(_:)`, or is assigned to
  a member of `self`. Reports `combine-sink-self-cycle` as a `warning`; silent
  for finite sources (`Single`, `Completable`, `Maybe`, `just`, `take(1)`,
  `first()`, `subscribe(onSuccess:)`). Built in for `subscribe`, `bind` and
  `drive`.
- **`signalDisposable`** — a SwiftSignalKit-style subscription whose
  Disposable is passed to `self.<disposable>.set(_:)` or `.add(_:)`, or assigned
  to a member of `self`. Same report and finiteness rules. Built in for
  `start(next:)` (declare it with `"requiredLabels": ["next"]` for other
  callees of that shape).

A dropped reactive Disposable does not end its subscription, so the two
reactive templates feed only the cycle rule, never the premature-release rules.

With the contract above, `becomeInactiveTask = React.to(.willResignActive) { _ in
self.disconnect() }` (the `AnyCancellable` stored on `self`, the closure
````

### Edit 2: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| id | default | detects |
|---|---|---|
| `stored-closure-strong-self` | error‡ | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly; also one level down, on a child `self` owns through a strong stored property (`self.toolbar.onTap = { self… }`, `.append`) |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` — including `self` captured only to feed a nested closure's `[weak self]` |
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
| `notification-observer-leak` | warning† | strong-`self` block observer; the center holds block and token until removal |
````

Replace it with:

````markdown
| id | default | detects |
|---|---|---|
| `stored-closure-strong-self` | error‡ | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly; also one level down, on a child `self` owns through a strong stored property (`self.toolbar.onTap = { self… }`, `.append`) |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` — including `self` captured only to feed a nested closure's `[weak self]`; also, as a warning, RxSwift `subscribe(onNext:)`/`bind`/`drive` + `.disposed(by:)` into a bag on `self`, and SwiftSignalKit `start(next:)` kept in a disposable on `self` (finite sources stay silent) |
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
| `notification-observer-leak` | warning† | strong-`self` block observer; the center holds block and token until removal |
````

### Edit 3: `Sources/ArcLeakCore/Config/Configuration.swift` (near `public struct Configuration: Sendable, Codable, Equatable {`)

Find this exact text (it occurs once in the file):

````swift
    /// Supports `tokenProducer` (the call returns a lifetime token that must be
    /// owned) and `sinkWrapper` (a custom Combine wrapper such as `React.to`
    /// that returns an AnyCancellable-like token AND whose closure argument is
    /// analyzed for a strong-`self` cycle exactly like `.sink`); `anchorLeak`
    /// lands with cross-file release plumbing.
    public var contracts: [UserContract]?
    /// Regions (comma-separated: `preview,debug,test,mock,generated,script`,
    /// or `all`) to treat as first-class code: a leak or cycle withheld
````

Replace it with:

````swift
    /// Supports `tokenProducer` (the call returns a lifetime token that must be
    /// owned) and `sinkWrapper` (a custom Combine wrapper such as `React.to`
    /// that returns an AnyCancellable-like token AND whose closure argument is
    /// analyzed for a strong-`self` cycle exactly like `.sink`), and
    /// `disposeBag` / `signalDisposable` (reactive subscriptions whose
    /// Disposable `self` keeps; built in for the RxSwift and SwiftSignalKit
    /// spellings); `anchorLeak` lands with cross-file release plumbing.
    public var contracts: [UserContract]?
    /// Regions (comma-separated: `preview,debug,test,mock,generated,script`,
    /// or `all`) to treat as first-class code: a leak or cycle withheld
````

### Edit 4: `Sources/ArcLeakCore/Config/Configuration.swift` (near `public struct Configuration: Sendable, Codable, Equatable {`)

Find this exact text (it occurs once in the file):

````swift
            /// premature-release rules; a strong-`self` closure whose token is
            /// stored on `self` feeds `combine-sink-self-cycle`.
            case sinkWrapper
        }

        /// Callee name (`subscribe` in `bus.subscribe(handler:)`, `to` in
````

Replace it with:

````swift
            /// premature-release rules; a strong-`self` closure whose token is
            /// stored on `self` feeds `combine-sink-self-cycle`.
            case sinkWrapper
            /// An RxSwift-style subscription (`subscribe(onNext:)`, `bind`,
            /// `drive`) whose Disposable goes into a bag on `self` through a
            /// chained `.disposed(by:)` (or `addDisposableTo(_:)`), or is
            /// assigned to a member of `self`: a strong-`self` closure feeds
            /// `combine-sink-self-cycle`. Built in for `subscribe`, `bind` and
            /// `drive`.
            case disposeBag
            /// A SwiftSignalKit-style subscription (`signal.start(next:)`)
            /// whose Disposable is passed to `self.<disposable>.set(_:)` or
            /// `.add(_:)`, or assigned to a member of `self`: a strong-`self`
            /// closure feeds `combine-sink-self-cycle`. Built in for
            /// `start(next:)`.
            case signalDisposable
        }

        /// Callee name (`subscribe` in `bus.subscribe(handler:)`, `to` in
````

### Edit 5: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        case .notificationObserverLeak:
            "Block-based NotificationCenter observer captures `self` strongly; the center holds the block until removal"
        case .combineSinkSelfCycle:
            "sink closure captures `self` strongly and the AnyCancellable is stored on `self`"
        case .combineAssignSelfCycle:
            "assign(to:on: self) retains `self` strongly while `self` stores the cancellable"
        case .taskNonterminatingSelf:
````

Replace it with:

````swift
        case .notificationObserverLeak:
            "Block-based NotificationCenter observer captures `self` strongly; the center holds the block until removal"
        case .combineSinkSelfCycle:
            "sink (or Rx/SwiftSignalKit subscription) closure captures `self` strongly and its token is stored on `self`"
        case .combineAssignSelfCycle:
            "assign(to:on: self) retains `self` strongly while `self` stores the cancellable"
        case .taskNonterminatingSelf:
````

### Edit 6: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            closes the loop: self → cancellables → AnyCancellable → closure → self.
            AnyCancellable's deinit-cancel never fires — deinit is inside the cycle.

            Fix: `[weak self]` in the sink closure.
            """
        case .combineAssignSelfCycle:
````

Replace it with:

````swift
            closes the loop: self → cancellables → AnyCancellable → closure → self.
            AnyCancellable's deinit-cancel never fires — deinit is inside the cycle.

            Reactive subscriptions close the same loop: RxSwift `subscribe(onNext:)`,
            `bind` or `drive` followed by `.disposed(by: self.bag)`, and SwiftSignalKit
            `self.disposable.set(signal.start(next:))`, give self → bag/disposable →
            subscription → closure → self; the bag disposes only in its own deinit.
            These report as warnings, since completion of the source cannot be read
            from the call; finite sources (`Single`, `Completable`, `Maybe`, `just`,
            `take(1)`, `first()`) stay silent. Other spellings are declared with the
            `disposeBag` and `signalDisposable` contract templates.

            Fix: `[weak self]` in the sink closure.
            """
        case .combineAssignSelfCycle:
````

### Edit 7: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
    /// their closure argument analyzed for a strong-`self` cycle exactly like
    /// `.sink` (`React.to { self.… }` stored on `self`).
    private func matchUserContract(_ node: FunctionCallExprSyntax) -> APICallFact? {
        guard !userContracts.isEmpty,
            let member = node.calledExpression.as(MemberAccessExprSyntax.self)
        else { return nil }
        let callee = member.declName.baseName.text
        let labels = node.arguments.compactMap { $0.label?.text }
        for contract in userContracts where contract.callee == callee {
            if let base = contract.base,
                member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text != base
            {
````

Replace it with:

````swift
    /// their closure argument analyzed for a strong-`self` cycle exactly like
    /// `.sink` (`React.to { self.… }` stored on `self`).
    private func matchUserContract(_ node: FunctionCallExprSyntax) -> APICallFact? {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let callee = member.declName.baseName.text
        let labels = node.arguments.compactMap { $0.label?.text }
        for contract in userContracts + Self.builtInContracts where contract.callee == callee {
            if let base = contract.base,
                member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text != base
            {
````

### Edit 8: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
                    selfCaptureViaNestedListOnly: nestedListOnly,
                    consumption: classifyConsumption(of: node)
                )
            }
        }
        return nil
    }

    /// Strongest `self` capture across every closure a wrapper call carries —
    /// trailing, additional-trailing, and closure-literal arguments — plus
    /// bound-method values (`React.to(.x, with: self.handle)`). Mirrors the
````

Replace it with:

````swift
                    selfCaptureViaNestedListOnly: nestedListOnly,
                    consumption: classifyConsumption(of: node)
                )
            case .disposeBag, .signalDisposable:
                // Only a Disposable that `self` keeps matters: a reactive
                // subscription is not ended by dropping its Disposable, so
                // nothing else here is a finding.
                let consumption = classifyReactiveConsumption(of: node)
                guard consumption.storesIntoSelf else { return nil }
                return APICallFact(
                    kind: .reactiveSubscription(name),
                    position: position(of: node),
                    repeats: nil,
                    targetIsSelf: false,
                    upstreamFiniteness: reactiveFiniteness(of: node, labels: labels),
                    closureSelfCapture: capture,
                    selfCaptureViaNestedListOnly: nestedListOnly,
                    consumption: consumption
                )
            }
        }
        return nil
    }

    /// Reactive subscriptions matched with no configuration: RxSwift's
    /// `subscribe`/`bind`/`drive` and SwiftSignalKit's `start(next:)`. User
    /// contracts are tried first, so a user can redeclare any of these names.
    private static let builtInContracts: [Configuration.UserContract] = [
        .init(callee: "subscribe", tokenName: "the subscription's Disposable", template: .disposeBag),
        .init(callee: "bind", tokenName: "the subscription's Disposable", template: .disposeBag),
        .init(callee: "drive", tokenName: "the subscription's Disposable", template: .disposeBag),
        .init(
            callee: "start",
            requiredLabels: ["next"],
            tokenName: "the signal's Disposable",
            template: .signalDisposable
        ),
    ]

    /// Where a reactive Disposable goes: a chained `.disposed(by: bag)` or
    /// `.addDisposableTo(bag)` stores it in `bag`; an argument of
    /// `self.<disposable>.set(_:)` / `.add(_:)` stores it in that member;
    /// otherwise the ordinary classification (assignment, local, discard).
    private func classifyReactiveConsumption(of node: FunctionCallExprSyntax) -> ResultConsumption {
        if let member = node.parent?.as(MemberAccessExprSyntax.self),
            member.base?.id == node.id,
            let chained = member.parent?.as(FunctionCallExprSyntax.self),
            chained.calledExpression.id == member.id,
            let bag = chained.arguments.first
        {
            let name = member.declName.baseName.text
            if (name == "disposed" && bag.label?.text == "by") || (name == "addDisposableTo" && bag.label == nil) {
                return .chainedStoreIn(memberOfSelf: memberOfSelfName(bag.expression) != nil)
            }
        }
        if let argument = node.parent?.as(LabeledExprSyntax.self),
            argument.label == nil,
            let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
            let setter = call.calledExpression.as(MemberAccessExprSyntax.self),
            ["set", "add"].contains(setter.declName.baseName.text),
            let base = setter.base,
            let holder = memberOfSelfName(base)
        {
            return .storedToSelfMember(holder)
        }
        return classifyConsumption(of: node)
    }

    /// Sources and operators that complete: RxSwift's `Single`, `Completable`
    /// and `Maybe` (and their `as…` conversions), `just`, `empty`, `first()`,
    /// `take(1)` in the receiver, or a `subscribe(onSuccess:)` that only a
    /// `Single` or `Maybe` offers. A completed subscription releases its
    /// closures, so the cycle is transient.
    private func reactiveFiniteness(
        of node: FunctionCallExprSyntax,
        labels: [String]
    ) -> APICallFact.UpstreamFiniteness {
        if labels.contains("onSuccess") { return .finite }
        guard let receiver = node.calledExpression.as(MemberAccessExprSyntax.self)?.base else {
            return .unknown
        }
        let tokens = receiver.tokens(viewMode: .sourceAccurate).map(\.text)
        for (index, token) in tokens.enumerated() {
            if Self.finiteReactiveMarkers.contains(token) { return .finite }
            if token == "take", tokens.dropFirst(index + 1).prefix(3).elementsEqual(["(", "1", ")"]) {
                return .finite
            }
        }
        return .unknown
    }

    private static let finiteReactiveMarkers: Set<String> = [
        "Single", "Completable", "Maybe", "asSingle", "asCompletable", "asMaybe", "just", "empty", "first",
    ]

    /// Strongest `self` capture across every closure a wrapper call carries —
    /// trailing, additional-trailing, and closure-literal arguments — plus
    /// bound-method values (`React.to(.x, with: self.handle)`). Mirrors the
````

### Edit 9: `Sources/ArcLeakCore/Facts/APICallFact.swift` (near `public struct APICallFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        /// for a strong-`self` cycle (associated value = diagnostic name). Feeds
        /// both the premature-release rules and `combine-sink-self-cycle`.
        case userSinkWrapper(String)
    }

    /// Whether a Combine upstream provably completes. `Subscribers.Sink`
````

Replace it with:

````swift
        /// for a strong-`self` cycle (associated value = diagnostic name). Feeds
        /// both the premature-release rules and `combine-sink-self-cycle`.
        case userSinkWrapper(String)
        /// `disposeBag` / `signalDisposable` contract (built in or
        /// user-declared): a reactive subscription whose Disposable `self`
        /// keeps (associated value = diagnostic name). Feeds only
        /// `combine-sink-self-cycle`: dropping a reactive Disposable does not
        /// end the subscription, so it is no premature-release token.
        case reactiveSubscription(String)
    }

    /// Whether a Combine upstream provably completes. `Subscribers.Sink`
````

### Edit 10: `Sources/ArcLeakCore/Facts/APICallFact.swift` (near `public struct APICallFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            false
        case .userTokenProducer, .userSinkWrapper:
            true
        }
    }

````

Replace it with:

````swift
            false
        case .userTokenProducer, .userSinkWrapper:
            true
        case .reactiveSubscription:
            false
        }
    }

````

### Edit 11: `Sources/ArcLeakCore/Facts/APICallFact.swift` (near `public struct APICallFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    /// user-declared `sinkWrapper` contracts (`React.to` and friends).
    public var feedsSinkCycleRule: Bool {
        switch kind {
        case .combineSink, .userSinkWrapper:
            true
        default:
            false
````

Replace it with:

````swift
    /// user-declared `sinkWrapper` contracts (`React.to` and friends).
    public var feedsSinkCycleRule: Bool {
        switch kind {
        case .combineSink, .userSinkWrapper, .reactiveSubscription:
            true
        default:
            false
````

### Edit 12: `Sources/ArcLeakCore/Rules/CombineSinkSelfCycleRule.swift`

Find this exact text (it occurs once in the file):

````swift
/// `publisher.sink { self.… }` stored into `self`'s cancellables — closed cycle:
/// self → cancellable set → AnyCancellable → sink closure → self. Also fires on
/// user-declared `sinkWrapper` contracts (custom Combine wrappers like
/// `React.to`) whose returned token is stored on `self`.
struct CombineSinkSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineSinkSelfCycle]

````

Replace it with:

````swift
/// `publisher.sink { self.… }` stored into `self`'s cancellables — closed cycle:
/// self → cancellable set → AnyCancellable → sink closure → self. Also fires on
/// user-declared `sinkWrapper` contracts (custom Combine wrappers like
/// `React.to`) whose returned token is stored on `self`, and on reactive
/// subscriptions (`disposeBag` / `signalDisposable` contracts, built in for
/// RxSwift `subscribe`/`bind`/`drive` + `.disposed(by:)` and SwiftSignalKit
/// `start(next:)`) whose Disposable `self` keeps.
struct CombineSinkSelfCycleRule: Rule {
    static let emits: [RuleID] = [.combineSinkSelfCycle]

````

### Edit 13: `Sources/ArcLeakCore/Rules/CombineSinkSelfCycleRule.swift` (near `struct CombineSinkSelfCycleRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
            // its contract diagnostic name and say "wrapper closure".
            let closureNoun: String
            let tokenNoun: String
            if case .userSinkWrapper(let name) = call.kind {
                closureNoun = "wrapper closure"
                tokenNoun = name
            } else {
                closureNoun = "sink closure"
                tokenNoun = "its AnyCancellable"
            }
````

Replace it with:

````swift
            // its contract diagnostic name and say "wrapper closure".
            let closureNoun: String
            let tokenNoun: String
            var holder = "cancellable"
            var ending = "the publisher completes or cancel() runs"
            switch call.kind {
            case .userSinkWrapper(let name):
                closureNoun = "wrapper closure"
                tokenNoun = name
            case .reactiveSubscription(let name):
                closureNoun = "subscription closure"
                tokenNoun = name
                holder = "disposable"
                ending = "the source completes or the subscription is disposed"
            default:
                closureNoun = "sink closure"
                tokenNoun = "its AnyCancellable"
            }
````

### Edit 14: `Sources/ArcLeakCore/Rules/CombineSinkSelfCycleRule.swift` (near `struct CombineSinkSelfCycleRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
            case .unknown, .finite:
                severity = .warning
                note =
                    "capture [weak self]; upstream completion could not be determined — the cycle persists until the publisher completes or cancel() runs"
            }
            var message =
                "retain cycle: \(closureNoun) captures self strongly and \(tokenNoun) is stored on self (self → cancellable → closure → self)"
            if call.selfCaptureViaNestedListOnly {
                // The dev sees only a nested [weak self] and will disbelieve a
                // bare "captures self strongly" — spell the mechanism out.
                message =
                    "retain cycle: the \(closureNoun) captures self strongly — its only `self` sits in a nested closure's capture list, and forming that nested [weak self] box forces the \(closureNoun) itself to capture self strongly (self → cancellable → closure → self)"
                note = "the nested [weak self] does not protect the outer closure; " + note
            }
            if isTestCase {
````

Replace it with:

````swift
            case .unknown, .finite:
                severity = .warning
                note =
                    "capture [weak self]; upstream completion could not be determined — the cycle persists until \(ending)"
            }
            var message =
                "retain cycle: \(closureNoun) captures self strongly and \(tokenNoun) is stored on self (self → \(holder) → closure → self)"
            if call.selfCaptureViaNestedListOnly {
                // The dev sees only a nested [weak self] and will disbelieve a
                // bare "captures self strongly" — spell the mechanism out.
                message =
                    "retain cycle: the \(closureNoun) captures self strongly — its only `self` sits in a nested closure's capture list, and forming that nested [weak self] box forces the \(closureNoun) itself to capture self strongly (self → \(holder) → closure → self)"
                note = "the nested [weak self] does not protect the outer closure; " + note
            }
            if isTestCase {
````

### Edit 15: `Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift` (near `struct UnstoredLifetimeTokenRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler, .scriptMessageHandlerAdd:
            "the token"
        case .userTokenProducer(let name), .userSinkWrapper(let name):
            name
        }
    }
````

Replace it with:

````swift
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler, .scriptMessageHandlerAdd:
            "the token"
        case .userTokenProducer(let name), .userSinkWrapper(let name), .reactiveSubscription(let name):
            name
        }
    }
````

### Edit 16: `Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift` (near `struct UnstoredLifetimeTokenRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler, .scriptMessageHandlerAdd:
            "the work it owns stops immediately"
        case .userTokenProducer:
            "the work it owns stops immediately (user contract)"
        case .userSinkWrapper:
            "the AnyCancellable-like token cancels on deinit, so the subscription ends before any value arrives (user contract)"
````

Replace it with:

````swift
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler, .scriptMessageHandlerAdd:
            "the work it owns stops immediately"
        case .userTokenProducer, .reactiveSubscription:
            "the work it owns stops immediately (user contract)"
        case .userSinkWrapper:
            "the AnyCancellable-like token cancels on deinit, so the subscription ends before any value arrives (user contract)"
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import RxSwift
import SwiftSignalKit

// Reactive subscriptions that do not close a cycle: finite sources (Single,
// Completable, Maybe, just, take(1), first()) release their closures when
// they complete; [weak self] never holds self; a bag held in a local disposes
// at the end of the call; a Disposable that self does not keep holds nothing
// of self's.
final class ProfileViewModel {
    let disposeBag = DisposeBag()
    let refresh = PublishSubject<Void>()
    let api = ProfileAPI()
    let statusDisposable = MetaDisposable()
    let peerSignal: Signal<String, NoError>
    var count = 0

    init(peerSignal: Signal<String, NoError>) {
        self.peerSignal = peerSignal
    }

    func bindInputs() {
        api.fetch().asSingle().subscribe(onSuccess: { _ in self.count += 1 }).disposed(by: disposeBag)
        Completable.empty().subscribe(onCompleted: { self.count = 0 }).disposed(by: disposeBag)
        Maybe<Int>.empty().subscribe(onNext: { _ in self.count = 0 }).disposed(by: disposeBag)
        Observable.just(1).subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        refresh.take(1).subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        refresh.subscribe(onNext: { [weak self] _ in self?.count += 1 }).disposed(by: disposeBag)

        let bag = DisposeBag()
        refresh.subscribe(onNext: { _ in self.count += 1 }).disposed(by: bag)

        _ = refresh.subscribe(onNext: { _ in self.count += 1 })

        statusDisposable.set((peerSignal |> take(1)).start(next: { _ in self.count += 1 }))
        statusDisposable.set(peerSignal.start(next: { [weak self] _ in self?.count += 1 }))
    }
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import RxCocoa
import RxSwift

// self → disposeBag → subscription → onNext closure → self. The bag disposes
// its subscriptions in its own deinit, which runs only after self's — never,
// while the closure holds self. Warning: whether the source completes cannot
// be read from the source.
final class FeedViewModel {
    let disposeBag = DisposeBag()
    let refresh = PublishSubject<Void>()
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

    func render(_ text: String) {}
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Leaks/SignalDisposableSelf.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import SwiftSignalKit

// SwiftSignalKit: self → disposable → subscription → next closure → self.
// MetaDisposable and DisposableSet dispose in their own deinit, which never
// runs while the closure holds self. Warning: completion of the signal
// cannot be read from the source.
final class PeerController {
    let statusDisposable = MetaDisposable()
    let disposables = DisposableSet()
    var stateDisposable: Disposable?
    let peerSignal: Signal<String, NoError>

    init(peerSignal: Signal<String, NoError>) {
        self.peerSignal = peerSignal
    }

    func load() {
        self.statusDisposable.set(peerSignal.start(next: { value in // #al:expect combine-sink-self-cycle
            self.apply(value)
        }))
        disposables.add(peerSignal.start(next: { value in self.apply(value) })) // #al:expect combine-sink-self-cycle
        stateDisposable = (peerSignal |> deliverOnMainQueue).start(next: { value in self.apply(value) }) // #al:expect combine-sink-self-cycle
    }

    func apply(_ value: String) {}
}
````

### New file `Tests/ArcLeakCoreTests/ReactiveContractTests.swift`

Create it with exactly this content (ending with one newline):

````swift
import ArcLeakCore
import Foundation
import Testing

/// The `disposeBag` and `signalDisposable` contract templates: built in for
/// RxSwift's `subscribe`/`bind`/`drive` and SwiftSignalKit's `start(next:)`,
/// and declarable through `contracts` for other spellings, like `sinkWrapper`.
@Suite struct ReactiveContractTests {
    /// RxSwift 2 spellings: `subscribeNext` and `addDisposableTo(_:)`.
    private let legacySource = """
        import RxSwift

        final class LegacyViewModel {
            let disposeBag = DisposeBag()
            let refresh = PublishSubject<Void>()
            var count = 0

            func bindInputs() {
                refresh.subscribeNext { _ in
                    self.count += 1
                }.addDisposableTo(disposeBag)
            }
        }
        """

    /// A home-grown signal type whose subscription method is `observe(each:)`.
    private let customSignalSource = """
        final class Watcher {
            let disposable = SerialDisposable()
            let values = ValueSignal<Int>()
            var last = 0

            func watch() {
                disposable.set(values.observe(each: { value in self.last = value }))
            }
        }
        """

    private func load(_ json: String) throws -> Configuration {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "arcleak-reactive-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Configuration.load(path: url.path)
    }

    @Test("Without a contract, other reactive spellings stay silent")
    func silentWithoutContract() {
        #expect(Analyzer().analyze(source: legacySource, path: "Legacy.swift").findings.isEmpty)
        #expect(Analyzer().analyze(source: customSignalSource, path: "Watcher.swift").findings.isEmpty)
    }

    @Test("A disposeBag contract flags a strong-self subscription kept in a bag on self")
    func disposeBagContract() throws {
        let configuration = try load(
            """
            {"contracts": [{"callee": "subscribeNext", "template": "disposeBag", "tokenName": "the subscribeNext Disposable"}]}
            """
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: legacySource, path: "Legacy.swift").findings
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("the subscribeNext Disposable") == true)
    }

    @Test("A signalDisposable contract flags a strong-self subscription set into a member")
    func signalDisposableContract() throws {
        let configuration = try load(
            """
            {"contracts": [{"callee": "observe", "requiredLabels": ["each"], "template": "signalDisposable"}]}
            """
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: customSignalSource, path: "Watcher.swift").findings
        #expect(findings.map(\.rule) == [.combineSinkSelfCycle])
        #expect(findings.first?.message.contains("self → disposable → closure → self") == true)
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 193 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 80 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Fixture probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/SignalDisposableSelf.swift Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift --no-cache; echo EXIT=$?'`. Expected: the output contains the summary line `arcleak: 7 finding(s) (0 error(s), 7 warning(s)) in 3 file(s)`: `warning: [combine-sink-self-cycle]` at `RxDisposeBagSelf.swift` lines 17, 20, 21, 22 and `SignalDisposableSelf.swift` lines 19, 22, 23; none in `RxFiniteOrWeak.swift`; then `EXIT=0`.
7. `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel --filter ReactiveContractTests 2>&1 | tail -3'` contains `Test run with 3 tests in 1 suite passed`.
8. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 40 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump: that is a release step), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Config/Configuration.swift Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/APICallFact.swift Sources/ArcLeakCore/Rules/CombineSinkSelfCycleRule.swift Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/SignalDisposableSelf.swift Tests/ArcLeakCoreTests/ReactiveContractTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: extend combine-sink-self-cycle to Rx and SwiftSignalKit subscriptions

A subscription whose closure captures self strongly and whose Disposable
self keeps closes the same loop as a stored sink: self -> bag or disposable
-> subscription -> closure -> self, and the bag disposes only in its own
deinit. Two contract templates model it: disposeBag (subscribe, bind or
drive followed by .disposed(by:) or addDisposableTo(_:) into a member of
self, or assigned to one) and signalDisposable (start(next:) passed to
self.<disposable>.set(_:) or .add(_:), or assigned to a member). Both are
built in for the RxSwift and SwiftSignalKit spellings and declarable in
contracts for others.

The findings are warnings, since completion of the source cannot be read
from the call; Single, Completable, Maybe, just, take(1), first() and
subscribe(onSuccess:) stay silent. A dropped reactive Disposable does not
end the subscription, so these templates never feed the premature-release
rules. Leaks/RxDisposeBagSelf (4), Leaks/SignalDisposableSelf (3),
Clean/RxFiniteOrWeak and ReactiveContractTests pin it; 193 tests pass."'
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
