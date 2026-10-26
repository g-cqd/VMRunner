# ARC20 — webview-script-handler-cycle: the error needs the add receiver rooted in an owned WebKit property

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (final review fixes), card 1 of 2: **dispatch ARC20 first** (after ARC18, lane/rules at 30610af); next ARC19

Review fix S1 (the only behaviour change of this pair). `webview-script-handler-cycle` decided `error` from a property of the type (`keepsWebView`), not from the receiver of the `add` call: a class that keeps a `WKWebView` for something else and registers `self` on a controller it receives as a parameter, with a deinit-only removal, was reported as `error` with the message `web view → configuration → controller → self`. The `add` call now records the stored member of `self` that its receiver chain starts from (`APICallFact.receiverRootMember`, set only for `scriptMessageHandlerAdd`). `error` needs that root to be a strong stored property typed exactly `WKWebView`, `WKWebViewConfiguration` or `WKUserContentController`; any other receiver (parameter, local) is capped at `warning` with a message starting `observed:`. The type-name test is exact, so SwiftUI's `WebView` struct does not count. Nit in the same commit: the finite Rx markers `first`, `just` and `empty` now match only in call form (`first()`, `just(`, `empty()`, like `take(1)`), so `users.first?.events.subscribe { self… }.disposed(by: disposeBag)` is reported. The `return nil` on a bag-spelling mismatch stays (it is not equivalent to `continue`, see INDEX-ARC3); a comment says why. 199 → 200 tests.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Facts/APICallFact.swift`: new field `receiverRootMember` (declaration, init parameter, assignment, both copy methods)
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: the `return nil` comment in `matchUserContract`, the finite reactive calls, the `receiverRootMember` recording and the new helper `rootMemberOfSelf`
  - `Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift`: doc comment, `check`, `ownedWebViewMembers` (replaces `keepsWebView`)
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `explanation` of `.webviewScriptHandlerCycle`
  - `README.md`: the `webview-script-handler-cycle` row of the Rules table
  - `Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift`: `OwningBridge` rewritten, new class `PreviewBridge` at the end
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift`: new class `SwiftUIPreviewBridge` at the end
  - `Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift`: new class `UserListViewModel` at the end
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift`: two new lines (`first()`, `empty()`)
  - `Tests/ArcLeakCoreTests/PrecisionRegressionTests.swift`: one new test at the end of the suite

## Change

### Edit 1: `Sources/ArcLeakCore/Facts/APICallFact.swift`

Find this exact text (it occurs once in the file):

````swift
    /// (`self.source.setEventHandler { … }`) — the edge self → receiver exists.
    public let receiverIsSelfMember: Bool
````

Replace it with:

````swift
    /// (`self.source.setEventHandler { … }`) — the edge self → receiver exists.
    public let receiverIsSelfMember: Bool
    /// The stored member of `self` that the call's receiver chain starts from
    /// (`webView` in `webView.configuration.userContentController.add(…)`);
    /// nil for a local, a parameter or any other root. Recorded only for
    /// `scriptMessageHandlerAdd`.
    public let receiverRootMember: String?
````

### Edit 2: `Sources/ArcLeakCore/Facts/APICallFact.swift`

Find this exact text (it occurs once in the file):

````swift
        receiverIsSelfMember: Bool = false,
````

Replace it with:

````swift
        receiverIsSelfMember: Bool = false,
        receiverRootMember: String? = nil,
````

### Edit 3: `Sources/ArcLeakCore/Facts/APICallFact.swift`

Find this exact text (it occurs once in the file):

````swift
        self.receiverIsSelfMember = receiverIsSelfMember
````

Replace it with:

````swift
        self.receiverIsSelfMember = receiverIsSelfMember
        self.receiverRootMember = receiverRootMember
````

### Edit 4: `Sources/ArcLeakCore/Facts/APICallFact.swift`

Find this exact text (it occurs once in the file):

````swift
            receiverIsSelfMember: receiverIsSelfMember,
            upstreamFiniteness: finiteness,
````

Replace it with:

````swift
            receiverIsSelfMember: receiverIsSelfMember,
            receiverRootMember: receiverRootMember,
            upstreamFiniteness: finiteness,
````

### Edit 5: `Sources/ArcLeakCore/Facts/APICallFact.swift`

Find this exact text (it occurs once in the file):

````swift
            receiverIsSelfMember: receiverIsSelfMember,
            upstreamFiniteness: upstreamFiniteness,
````

Replace it with:

````swift
            receiverIsSelfMember: receiverIsSelfMember,
            receiverRootMember: receiverRootMember,
            upstreamFiniteness: upstreamFiniteness,
````

### Edit 6: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
                let consumption = classifyReactiveConsumption(of: node)
                if contract.template == .disposeBag, consumption != .chainedStoreIn(memberOfSelf: true) {
````

Replace it with:

````swift
                let consumption = classifyReactiveConsumption(of: node)
                // `return nil`, not `continue`: a contract whose callee, base
                // and labels match decides the call, also when it decides that
                // there is no finding (`continue` would hand a call that a
                // user contract declares bag-only to a later contract, such as
                // the built-in `signalDisposable` for `start(next:)`).
                if contract.template == .disposeBag, consumption != .chainedStoreIn(memberOfSelf: true) {
````

### Edit 7: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
    /// Sources and operators that complete: RxSwift's `Single`, `Completable`
    /// and `Maybe` (and their `as…` conversions), `just`, `empty`, `first()`,
    /// `take(1)` in the receiver, or a `subscribe(onSuccess:)` that only a
    /// `Single` or `Maybe` offers. A completed subscription releases its
    /// closures, so the cycle is transient.
````

Replace it with:

````swift
    /// Sources and operators that complete: RxSwift's `Single`, `Completable`
    /// and `Maybe` (and their `as…` conversions), the calls `just(…)`,
    /// `empty()`, `first()` and `take(1)` in the receiver, or a
    /// `subscribe(onSuccess:)` that only a `Single` or `Maybe` offers. A
    /// completed subscription releases its closures, so the cycle is transient.
````

### Edit 8: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
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
````

Replace it with:

````swift
        for (index, token) in tokens.enumerated() {
            if Self.finiteReactiveMarkers.contains(token) { return .finite }
            if let call = Self.finiteReactiveCalls[token],
                tokens.dropFirst(index + 1).prefix(call.count).elementsEqual(call)
            {
                return .finite
            }
        }
        return .unknown
    }

    private static let finiteReactiveMarkers: Set<String> = [
        "Single", "Completable", "Maybe", "asSingle", "asCompletable", "asMaybe",
    ]

    /// Finite calls, matched with the tokens that follow the name: a property
    /// named `first` (`users.first?.events`) is not the operator `first()`.
    private static let finiteReactiveCalls: [String: [String]] = [
        "just": ["("], "empty": ["(", ")"], "first": ["(", ")"], "take": ["(", "1", ")"],
    ]
````

### Edit 9: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
        var receiverIsSelfMember = false
        var closureLabels: [String] = []
````

Replace it with:

````swift
        var receiverIsSelfMember = false
        var receiverRootMember: String?
        var closureLabels: [String] = []
````

### Edit 10: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
                kind = .scriptMessageHandlerAdd
                if let handler = node.arguments.first, handler.label == nil {
                    targetIsSelf = isSelf(handler.expression)
                }
````

Replace it with:

````swift
                kind = .scriptMessageHandlerAdd
                if let handler = node.arguments.first, handler.label == nil {
                    targetIsSelf = isSelf(handler.expression)
                }
                receiverRootMember = rootMemberOfSelf(member.base)
````

### Edit 11: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
            receiverIsSelfMember: receiverIsSelfMember,
            upstreamFiniteness: finiteness,
````

Replace it with:

````swift
            receiverIsSelfMember: receiverIsSelfMember,
            receiverRootMember: receiverRootMember,
            upstreamFiniteness: finiteness,
````

### Edit 12: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
        guard let name else { return false }
        return name.lowercased().hasSuffix("contentcontroller")
    }
````

Replace it with:

````swift
        guard let name else { return false }
        return name.lowercased().hasSuffix("contentcontroller")
    }

    /// The stored member of `self` that a receiver chain starts from, through
    /// member accesses, `?` and `!`: `webView` in
    /// `self.webView.configuration.userContentController`. Nil when the chain
    /// starts at a local, a parameter or anything else.
    private func rootMemberOfSelf(_ base: ExprSyntax?) -> String? {
        var current = base
        while let expr = current {
            if let name = memberOfSelfName(expr) { return name }
            if let member = expr.as(MemberAccessExprSyntax.self) {
                current = member.base
            } else if let optional = expr.as(OptionalChainingExprSyntax.self) {
                current = optional.expression
            } else if let forced = expr.as(ForceUnwrapExprSyntax.self) {
                current = forced.expression
            } else {
                return nil
            }
        }
        return nil
    }
````

### Edit 13: `Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift`

Find this exact text (it occurs once in the file):

````swift
/// Same reachability contract as the notification-observer rule: a removal
/// reachable outside `deinit` means a managed lifecycle (silent). A removal
/// that only exists in `deinit` can never run when `self` closes the loop by
/// keeping the web view, its configuration or its content controller in a
/// strong stored property (error). Without that edge `self` is not in a
/// cycle: the controller keeps it only while the web view lives, so a
/// deinit-only removal is silent and a missing removal is a warning about the
/// observed retention.
struct WebViewScriptHandlerRule: Rule {
    static let emits: [RuleID] = [.webviewScriptHandlerCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.removeScriptMessageHandler) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.removeScriptMessageHandler)
        let ownsWebView = keepsWebView(type)
        guard ownsWebView || !deinitOnly else { return [] }

        return type.apiCalls.compactMap { call in
            guard call.kind == .scriptMessageHandlerAdd, call.targetIsSelf else { return nil }

            let severity: Severity
            let message: String
            let note: String
            if !ownsWebView {
                severity = min(configuration.severity(for: .webviewScriptHandlerCycle), .warning)
                message =
                    "observed: the user content controller keeps its script message handler (self) until it is removed — self lives as long as the web view"
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; this type keeps no web view, configuration or content controller, so no cycle is proven — remove the handler when the page is done or register a weak proxy"
            } else if deinitOnly {
                severity = .error
                message = cycleMessage
                note =
                    "the handler is removed only in deinit — the controller's hold on self means deinit never runs; remove it from a reachable teardown path or register a weak proxy"
            } else {
                severity = configuration.severity(for: .webviewScriptHandlerCycle)
                message = cycleMessage
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; remove the handler from a reachable teardown path or register a weak proxy"
            }
````

Replace it with:

````swift
/// Same reachability contract as the notification-observer rule: a removal
/// reachable outside `deinit` means a managed lifecycle (silent). A removal
/// that only exists in `deinit` can never run when the `add` call's receiver
/// starts at a strong stored property of `self` typed `WKWebView`,
/// `WKWebViewConfiguration` or `WKUserContentController`
/// (`webView.configuration.userContentController`, `contentController`):
/// `self` closes the loop (error). A receiver that is a parameter or a local
/// proves no cycle, even when the type keeps a web view for something else:
/// the finding is capped at warning with an "observed" message. A type that
/// keeps none of them is not in a cycle (the controller keeps it only while
/// the web view lives), so a deinit-only removal is silent there.
struct WebViewScriptHandlerRule: Rule {
    static let emits: [RuleID] = [.webviewScriptHandlerCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.removeScriptMessageHandler) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.removeScriptMessageHandler)
        let owned = ownedWebViewMembers(type)
        guard !owned.isEmpty || !deinitOnly else { return [] }
        let configured = configuration.severity(for: .webviewScriptHandlerCycle)

        return type.apiCalls.compactMap { call in
            guard call.kind == .scriptMessageHandlerAdd, call.targetIsSelf else { return nil }

            let severity: Severity
            let message: String
            let note: String
            if let root = call.receiverRootMember, owned.contains(root) {
                severity = deinitOnly ? .error : configured
                message = cycleMessage
                note =
                    deinitOnly
                    ? "the handler is removed only in deinit — the controller's hold on self means deinit never runs; remove it from a reachable teardown path or register a weak proxy"
                    : "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; remove the handler from a reachable teardown path or register a weak proxy"
            } else if owned.isEmpty {
                severity = min(configured, .warning)
                message =
                    "observed: the user content controller keeps its script message handler (self) until it is removed — self lives as long as the web view"
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; this type keeps no web view, configuration or content controller, so no cycle is proven — remove the handler when the page is done or register a weak proxy"
            } else {
                severity = min(configured, .warning)
                message =
                    "observed: the user content controller keeps its script message handler (self) until it is removed — when this controller belongs to the web view this type keeps, web view → configuration → controller → self"
                note =
                    deinitOnly
                    ? "the handler is removed only in deinit, and this controller is not reached from a web view, configuration or content controller this type keeps (it is a parameter or a local), so no cycle is proven; when it belongs to the owned web view, deinit never runs — remove the handler from a reachable teardown path or register a weak proxy"
                    : "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; this controller is not reached from a web view, configuration or content controller this type keeps (it is a parameter or a local), so no cycle is proven — remove the handler when the page is done or register a weak proxy"
            }
````

### Edit 14: `Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift`

Find this exact text (it occurs once in the file):

````swift
    /// A strong stored property typed as a web view (`WKWebView` or a
    /// subclass named `…WebView`), its configuration or its user content
    /// controller: the edge from `self` that closes the loop.
    private static func keepsWebView(_ type: TypeFacts) -> Bool {
        type.storedProperties.contains { property in
            property.strength == .strong
                && property.referencedTypeNames.contains { name in
                    name.hasSuffix("WebView") || name == "WKWebViewConfiguration" || name == "WKUserContentController"
                }
        }
    }
````

Replace it with:

````swift
    /// Names of the strong stored properties typed `WKWebView`,
    /// `WKWebViewConfiguration` or `WKUserContentController`: the edges from
    /// `self` that can close the loop. Exact names only, so SwiftUI's
    /// `WebView` struct (and any other `…WebView` type) does not count.
    private static func ownedWebViewMembers(_ type: TypeFacts) -> Set<String> {
        Set(
            type.storedProperties.filter { property in
                property.strength == .strong
                    && property.referencedTypeNames.contains { webKitOwnerTypes.contains($0) }
            }
            .map(\.name)
        )
    }

    private static let webKitOwnerTypes: Set<String> = [
        "WKWebView", "WKWebViewConfiguration", "WKUserContentController",
    ]
````

### Edit 15: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            self. When `self` also keeps the web view, its configuration or its content
            controller in a strong stored property, the loop is closed and a removal
            that only exists in deinit can never run: that is reported as an error.
            A type that keeps none of them is not in a cycle (the controller keeps it
            only while the web view lives): a deinit-only removal is silent there, and
            a missing removal is a warning about the observed retention.
````

Replace it with:

````swift
            self. When the add call's receiver starts at a strong stored property of
            `self` typed WKWebView, WKWebViewConfiguration or WKUserContentController
            (`webView.configuration.userContentController.add(self, name:)`), the
            loop is closed and a removal that only exists in deinit can never run:
            that is reported as an error. A receiver that is a parameter or a local
            proves no cycle, even when the type keeps a web view for something else:
            the finding is then at most a warning about the observed retention. A
            type that keeps none of them is not in a cycle (the controller keeps it
            only while the web view lives): a deinit-only removal is silent there.
````

### Edit 16: `README.md`

Find this exact text (it occurs once in the file):

````markdown
the deinit-only **error** needs a strong stored web view, configuration or content controller on the type (without one, a deinit-only removal is silent and a missing removal is an "observed" warning) |
````

Replace it with:

````markdown
the deinit-only **error** needs the `add` receiver to start at a strong stored `WKWebView`, `WKWebViewConfiguration` or `WKUserContentController` property of the type; a parameter or local receiver is at most an "observed" warning, and a type that keeps none of them is silent on a deinit-only removal |
````

### Edit 17: `Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift`

Find this exact text (it occurs once in the file):

````swift
// Keeping the content controller strongly closes the loop too: self →
// controller → self, and the deinit-only removal never runs (error).
final class OwningBridge: NSObject, WKScriptMessageHandler {
    var contentController: WKUserContentController?

    func attach(to contentController: WKUserContentController) {
        self.contentController = contentController
        contentController.add(self, name: "owning") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController?.removeScriptMessageHandler(forName: "owning")
    }
}
````

Replace it with:

````swift
// Keeping the content controller strongly closes the loop too: self →
// controller → self, and the deinit-only removal never runs (error).
final class OwningBridge: NSObject, WKScriptMessageHandler {
    let contentController = WKUserContentController()

    func attach() {
        contentController.add(self, name: "owning") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController.removeScriptMessageHandler(forName: "owning")
    }
}
````

### Edit 18: `Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift`

Find this exact text (it occurs once in the file):

````swift
final class AttachedBridge: NSObject, WKScriptMessageHandler {
    func attach(to contentController: WKUserContentController) {
        contentController.add(self, name: "attached") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
````

Replace it with:

````swift
final class AttachedBridge: NSObject, WKScriptMessageHandler {
    func attach(to contentController: WKUserContentController) {
        contentController.add(self, name: "attached") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// The type keeps a web view for something else and registers on a controller
// it is given: the receiver is a parameter, so no cycle is proven (warning,
// with a message that starts with observed:), not the deinit-only error.
final class PreviewBridge: NSObject, WKScriptMessageHandler {
    let preview = WKWebView()
    weak var contentController: WKUserContentController?

    func attach(to contentController: WKUserContentController) {
        self.contentController = contentController
        contentController.add(self, name: "a") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController?.removeScriptMessageHandler(forName: "a")
    }
}
````

### Edit 19: `Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift`

Find this exact text (it occurs once in the file):

````swift
    deinit {
        contentController?.removeScriptMessageHandler(forName: "b")
    }
}
````

Replace it with:

````swift
    deinit {
        contentController?.removeScriptMessageHandler(forName: "b")
    }
}

// SwiftUI's WebView struct is not a WKWebView: keeping one does not make a
// parameter controller the owned web view's, so the deinit-only removal is
// silent, as for a type that keeps no web view.
final class SwiftUIPreviewBridge: NSObject, WKScriptMessageHandler {
    var preview: WebView?
    weak var contentController: WKUserContentController?

    func attach(to contentController: WKUserContentController) {
        self.contentController = contentController
        contentController.add(self, name: "a")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController?.removeScriptMessageHandler(forName: "a")
    }
}
````

### Edit 20: `Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift`

Find this exact text (it occurs once in the file):

````swift
    func render(_ text: String) {}
}
````

Replace it with:

````swift
    func render(_ text: String) {}
}

// A property named first is not the operator first(): users.first?.events
// is an ordinary source, so the subscription is reported like any other.
final class UserListViewModel {
    let disposeBag = DisposeBag()
    var users: [UserSession] = []
    var count = 0

    func bindUsers() {
        users.first?.events.subscribe { _ in self.count += 1 }.disposed(by: disposeBag) // #al:expect combine-sink-self-cycle
    }
}
````

### Edit 21: `Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift`

Find this exact text (it occurs once in the file):

````swift
        refresh.take(1).subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
````

Replace it with:

````swift
        refresh.take(1).subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        refresh.first().asObservable().subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
        Observable<Int>.empty().subscribe(onNext: { _ in self.count += 1 }).disposed(by: disposeBag)
````

### Edit 22: `Tests/ArcLeakCoreTests/PrecisionRegressionTests.swift`

Find this exact text (it occurs once in the file):

````swift
        #expect(handlerFindings.map(\.line) == [5, 23])
        #expect(handlerFindings.map(\.severity) == [.error, .warning])
        #expect(handlerFindings.last?.message.hasPrefix("observed:") == true)
    }
}
````

Replace it with:

````swift
        #expect(handlerFindings.map(\.line) == [5, 23])
        #expect(handlerFindings.map(\.severity) == [.error, .warning])
        #expect(handlerFindings.last?.message.hasPrefix("observed:") == true)
    }

    @Test("webview-script-handler-cycle: the error needs the add receiver rooted in an owned WebKit property")
    func scriptHandlerErrorNeedsOwnedReceiver() {
        let source = """
            import SwiftUI
            import WebKit
            final class Unrelated: NSObject, WKScriptMessageHandler {
                let preview = WKWebView()
                weak var contentController: WKUserContentController?
                func attach(to contentController: WKUserContentController) {
                    self.contentController = contentController
                    contentController.add(self, name: "a")
                }
                deinit {
                    contentController?.removeScriptMessageHandler(forName: "a")
                }
            }
            final class OwnedController: NSObject, WKScriptMessageHandler {
                let contentController = WKUserContentController()
                func attach() {
                    contentController.add(self, name: "b")
                }
                deinit {
                    contentController.removeScriptMessageHandler(forName: "b")
                }
            }
            final class SwiftUIPreview: NSObject, WKScriptMessageHandler {
                var preview: WebView?
                weak var contentController: WKUserContentController?
                func attach(to contentController: WKUserContentController) {
                    self.contentController = contentController
                    contentController.add(self, name: "c")
                }
                deinit {
                    contentController?.removeScriptMessageHandler(forName: "c")
                }
            }
            """
        let handlerFindings = findings(source).filter { $0.rule == .webviewScriptHandlerCycle }
        #expect(handlerFindings.map(\.line) == [8, 17])
        #expect(handlerFindings.map(\.severity) == [.warning, .error])
        #expect(handlerFindings.first?.message.hasPrefix("observed:") == true)
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 200 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift --no-cache; echo EXIT=$?'`. Expected: the summary line `arcleak: 10 finding(s) (2 error(s), 8 warning(s)) in 4 file(s)` (it may print between other lines), then 10 finding lines: in `RxDisposeBagSelf.swift`, `warning` `[combine-sink-self-cycle]` at lines 16, 19, 20 and 34 (34 is the new `users.first?.events` line); in `WebViewScriptHandler.swift`, `[webview-script-handler-cycle]` `error` at lines 15 and 54, and `warning` at lines 31, 42, 68 and 83 (the messages at 31, 68 and 83 start with `observed:`; those at 31 and 83 contain `when this controller belongs to the web view this type keeps`); nothing in `WebViewScriptHandlerRemoved.swift` or `RxFiniteOrWeak.swift`; then `EXIT=1` (error findings make the exit status 1; that is expected here).
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 40 s on the orchestrator's copy after the build above).

## Stop conditions

- A Find text is not found exactly once.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (all `M`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/APICallFact.swift Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/RxFiniteOrWeak.swift Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/RxDisposeBagSelf.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift Tests/ArcLeakCoreTests/PrecisionRegressionTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "fix: require an owned receiver for the deinit-only script handler error

webview-script-handler-cycle reported error whenever the type kept a web
view, whatever the add call was made on. A class that keeps a WKWebView for
something else and registers self on a controller it receives as a
parameter, with a removal only in deinit, was reported as a definite cycle.

The add call now records the stored member of self that its receiver chain
starts from (receiverRootMember on APICallFact). The error needs that root to
be a strong stored WKWebView, WKWebViewConfiguration or
WKUserContentController property. A parameter or local receiver is capped at
warning with an observed message. The type-name test is exact, so the
SwiftUI WebView struct no longer counts as a web view.

The finite Rx markers first, just and empty now match only as calls
(first(), just(...), empty()), so users.first?.events.subscribe is reported.

The Leaks and Clean fixtures gain the parameter-controller shape, the
SwiftUI WebView shape, the first-property subscription and the first() and
empty() calls; PrecisionRegressionTests pins the severities.
200 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `fix: require an owned receiver for the deinit-only script handler error`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.
