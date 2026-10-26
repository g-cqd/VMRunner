# ARC02 — new rule webview-script-handler-cycle

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 2 of 10 (after ARC01; next ARC03)

Task item 2. `<…>.userContentController.add(self, name:)`, `add(_:contentWorld:name:)` and `addScriptMessageHandler(_:contentWorld:name:)` with no `removeScriptMessageHandler(forName:)` / `removeAllScriptMessageHandlers()` reachable outside deinit. Same reachable-release idiom as `NotificationObserverLeakRule` (silent when reachable, error when deinit-only, configured warning otherwise). Apple's documentation for `add(_:name:)` (checked with the apple-docs index) lists the removal methods but does NOT state that the controller retains the handler, so the rule text calls it observed behaviour and cites the public fixes firefox-ios@4d83f60171 (LeakAvoider weak proxy) and element-x-ios@f8d094516d (WKScriptMessageHandlerWrapper), both verified with `gh api`.

- **Model:** haiku, low. **Size:** about 170 lines (code about 90). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Facts/APICallFact.swift`: `enum Kind` (new case `scriptMessageHandlerAdd`), `producesLifetimeToken`
  - `Sources/ArcLeakCore/Facts/ReleaseSite.swift`: `enum Kind` (new case `removeScriptMessageHandler`) and `init?(calleeName:)`
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `matchKnowledgeBase` (new `case _ where … "add"…`), new `isUserContentController` before `finiteChainMarkers`
  - `Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift`: `tokenName(for:)` and `consequence(for:)` (two identical case lists)
  - `Sources/ArcLeakCore/Rules/Rule.swift`: `RuleEngine.rules`
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: new case `webviewScriptHandlerCycle`, `defaultSeverity`, `summary`, `explanation`
  - new `Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift`
  - `README.md`: new Rules table row before `dead-weak-capture`
  - new `Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift`, new `Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift`

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `urlsession-delegate-leak` | warning† | `URLSession(configuration:delegate: self, …)` with no reachable invalidation |
| `dispatch-source-cycle` | error | dispatch source stored on `self` whose handler captures `self` strongly, no reachable `cancel()` |
| `unowned-outlives-owner` | warning | `[unowned self]` in an anchor-held closure — traps if `self` deallocates first |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |

````

Replace it with:

````markdown
| `urlsession-delegate-leak` | warning† | `URLSession(configuration:delegate: self, …)` with no reachable invalidation |
| `dispatch-source-cycle` | error | dispatch source stored on `self` whose handler captures `self` strongly, no reachable `cancel()` |
| `unowned-outlives-owner` | warning | `[unowned self]` in an anchor-held closure — traps if `self` deallocates first |
| `webview-script-handler-cycle` | warning† | `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`) with no reachable `removeScriptMessageHandler(forName:)` or `removeAllScriptMessageHandlers()` |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |

````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
    case unownedOutlivesOwner = "unowned-outlives-owner"
    case deadWeakCapture = "dead-weak-capture"
    case delegateStrongProperty = "delegate-strong-property"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

Replace it with:

````swift
    case unownedOutlivesOwner = "unowned-outlives-owner"
    case deadWeakCapture = "dead-weak-capture"
    case delegateStrongProperty = "delegate-strong-property"
    case webviewScriptHandlerCycle = "webview-script-handler-cycle"

    /// Default severity before configuration overrides.
    public var defaultSeverity: Severity {
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        case .timerRetainsSelf, .notificationObserverLeak, .taskNonterminatingSelf,
            .unstoredLifetimeToken, .tokenStoredInLocal, .mutualStrongProperties,
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty:
            .warning
        }
    }
````

Replace it with:

````swift
        case .timerRetainsSelf, .notificationObserverLeak, .taskNonterminatingSelf,
            .unstoredLifetimeToken, .tokenStoredInLocal, .mutualStrongProperties,
            .urlSessionDelegateLeak, .unownedOutlivesOwner, .deadWeakCapture,
            .delegateStrongProperty, .webviewScriptHandlerCycle:
            .warning
        }
    }
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            "[weak self] whose body never uses self — capture-list noise (opt-in)"
        case .delegateStrongProperty:
            "Strong stored property named/typed like a delegate — likely back-reference cycle (opt-in)"
        }
    }

````

Replace it with:

````swift
            "[weak self] whose body never uses self — capture-list noise (opt-in)"
        case .delegateStrongProperty:
            "Strong stored property named/typed like a delegate — likely back-reference cycle (opt-in)"
        case .webviewScriptHandlerCycle:
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        }
    }

````

### Edit 5: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            Fix: `[weak self]` for anchor-held closures; keep `unowned` for the
            book-blessed same-lifetime shape (closure stored on self, never escaping it).
            """
        }
    }
}
````

Replace it with:

````swift
            Fix: `[weak self]` for anchor-held closures; keep `unowned` for the
            book-blessed same-lifetime shape (closure stored on self, never escaping it).
            """
        case .webviewScriptHandlerCycle:
            """
            `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`,
            `addScriptMessageHandler(_:contentWorld:name:)`) registers `self` as a
            script message handler. The user content controller
            keeps the handler until `removeScriptMessageHandler(forName:)` or
            `removeAllScriptMessageHandlers()` runs, and the web view's configuration
            keeps the controller: WKWebView → configuration → userContentController →
            self. When `self` also owns the web view the loop is closed, and a removal
            that only exists in deinit can never run.

            Apple's documentation for add(_:name:) lists the removal methods next to it
            but does not state the retention; this rule rests on observed behaviour.
            Public fixes register a weak proxy instead of `self` for this reason
            (firefox-ios@4d83f60171, element-x-ios@f8d094516d).

            Fix: remove the handler from a reachable teardown path (viewDidDisappear,
            a close() method), or register a proxy that holds `self` weakly.
            """
        }
    }
}
````

### Edit 6: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
            case "addPeriodicTimeObserver":
                kind = .periodicTimeObserver
                closureLabels = ["using"]
            case "setEventHandler", "setCancelHandler", "setRegistrationHandler":
                kind = .dispatchSourceHandler
                closureLabels = ["handler"]
````

Replace it with:

````swift
            case "addPeriodicTimeObserver":
                kind = .periodicTimeObserver
                closureLabels = ["using"]
            case _
            where ["add", "addScriptMessageHandler"].contains(callee) && labels.contains("name")
                && Self.isUserContentController(member.base):
                kind = .scriptMessageHandlerAdd
                if let handler = node.arguments.first, handler.label == nil {
                    targetIsSelf = isSelf(handler.expression)
                }
            case "setEventHandler", "setCancelHandler", "setRegistrationHandler":
                kind = .dispatchSourceHandler
                closureLabels = ["handler"]
````

### Edit 7: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift` (near `final class FactsExtractor: SyntaxVisitor {`)

Find this exact text (it occurs once in the file):

````swift
        )
    }

    /// Operators that force completion regardless of what feeds them.
    private static let finiteChainMarkers: Set<String> = [
        "first", "prefix", "output", "dataTaskPublisher", "Just", "Empty", "Fail",
````

Replace it with:

````swift
        )
    }

    /// `webView.configuration.userContentController`, or any receiver whose
    /// last name component ends in `ContentController` (a local or property
    /// holding a `WKUserContentController`).
    private static func isUserContentController(_ base: ExprSyntax?) -> Bool {
        let name: String? =
            base?.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? base?.as(DeclReferenceExprSyntax.self)?.baseName.text
        guard let name else { return false }
        return name.lowercased().hasSuffix("contentcontroller")
    }

    /// Operators that force completion regardless of what feeds them.
    private static let finiteChainMarkers: Set<String> = [
        "first", "prefix", "output", "dataTaskPublisher", "Just", "Empty", "Fail",
````

### Edit 8: `Sources/ArcLeakCore/Facts/APICallFact.swift` (near `public struct APICallFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        /// `setEventHandler`/`setCancelHandler` on a dispatch source — handlers are
        /// Block_copy-ed and held by the source until replaced or cancelled.
        case dispatchSourceHandler
        /// User-KB contract: the call returns a lifetime token that must be
        /// owned (associated value = diagnostic name).
        case userTokenProducer(String)
````

Replace it with:

````swift
        /// `setEventHandler`/`setCancelHandler` on a dispatch source — handlers are
        /// Block_copy-ed and held by the source until replaced or cancelled.
        case dispatchSourceHandler
        /// `<…>.userContentController.add(_:name:)` / `add(_:contentWorld:name:)`
        /// / `addScriptMessageHandler(_:contentWorld:name:)` — the controller keeps the script message handler until
        /// `removeScriptMessageHandler(forName:)` or
        /// `removeAllScriptMessageHandlers()` (observed behaviour; Apple's
        /// documentation does not state the retention).
        case scriptMessageHandlerAdd
        /// User-KB contract: the call returns a lifetime token that must be
        /// owned (associated value = diagnostic name).
        case userTokenProducer(String)
````

### Edit 9: `Sources/ArcLeakCore/Facts/APICallFact.swift` (near `public struct APICallFact: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            .periodicTimeObserver:
            true
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler:
            false
        case .userTokenProducer, .userSinkWrapper:
            true
````

Replace it with:

````swift
            .periodicTimeObserver:
            true
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler, .scriptMessageHandlerAdd:
            false
        case .userTokenProducer, .userSinkWrapper:
            true
````

### Edit 10: `Sources/ArcLeakCore/Facts/ReleaseSite.swift` (near `public struct ReleaseSite: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        case cancel
        case removeObserver
        case sessionInvalidate

        public init?(calleeName: String) {
            switch calleeName {
````

Replace it with:

````swift
        case cancel
        case removeObserver
        case sessionInvalidate
        case removeScriptMessageHandler

        public init?(calleeName: String) {
            switch calleeName {
````

### Edit 11: `Sources/ArcLeakCore/Facts/ReleaseSite.swift` (near `public struct ReleaseSite: Sendable, Equatable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
            case "cancel": self = .cancel
            case "removeObserver": self = .removeObserver
            case "invalidateAndCancel", "finishTasksAndInvalidate": self = .sessionInvalidate
            default: return nil
            }
        }
````

Replace it with:

````swift
            case "cancel": self = .cancel
            case "removeObserver": self = .removeObserver
            case "invalidateAndCancel", "finishTasksAndInvalidate": self = .sessionInvalidate
            case "removeScriptMessageHandler", "removeAllScriptMessageHandlers":
                self = .removeScriptMessageHandler
            default: return nil
            }
        }
````

### Edit 12: `Sources/ArcLeakCore/Rules/Rule.swift` (near `public enum RuleEngine {`)

Find this exact text (it occurs once in the file):

````swift
        UnownedOutlivesOwnerRule.self,
        DeadWeakCaptureRule.self,
        DelegateStrongPropertyRule.self,
    ]

    private static let corpusRules: [any CorpusRule.Type] = [
````

Replace it with:

````swift
        UnownedOutlivesOwnerRule.self,
        DeadWeakCaptureRule.self,
        DelegateStrongPropertyRule.self,
        WebViewScriptHandlerRule.self,
    ]

    private static let corpusRules: [any CorpusRule.Type] = [
````

### Edit 13: `Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift` (near `struct UnstoredLifetimeTokenRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
        case .kvoObserve: "the NSKeyValueObservation"
        case .periodicTimeObserver: "the time-observer token"
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler:
            "the token"
        case .userTokenProducer(let name), .userSinkWrapper(let name):
            name
````

Replace it with:

````swift
        case .kvoObserve: "the NSKeyValueObservation"
        case .periodicTimeObserver: "the time-observer token"
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler, .scriptMessageHandlerAdd:
            "the token"
        case .userTokenProducer(let name), .userSinkWrapper(let name):
            name
````

### Edit 14: `Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift` (near `struct UnstoredLifetimeTokenRule: Rule {`)

Find this exact text (it occurs once in the file):

````swift
        case .periodicTimeObserver:
            "the observer cannot be removed and callbacks may stop or leak"
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler:
            "the work it owns stops immediately"
        case .userTokenProducer:
            "the work it owns stops immediately (user contract)"
````

Replace it with:

````swift
        case .periodicTimeObserver:
            "the observer cannot be removed and callbacks may stop or leak"
        case .timerScheduledBlock, .timerScheduledTarget, .displayLinkTarget,
            .urlSessionWithDelegate, .dispatchSourceHandler, .scriptMessageHandlerAdd:
            "the work it owns stops immediately"
        case .userTokenProducer:
            "the work it owns stops immediately (user contract)"
````

### New file `Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift`

Create it with exactly this content (ending with one newline):

````swift
/// `<…>.userContentController.add(self, name:)` — the user content controller
/// keeps its script message handlers until they are removed, and the web
/// view's configuration keeps the controller, so `self` lives as long as the
/// web view. Apple's documentation does not state the retention; public fixes
/// replace `self` with a weak proxy (firefox-ios@4d83f60171,
/// element-x-ios@f8d094516d).
///
/// Same reachability contract as the notification-observer rule: a removal
/// reachable outside `deinit` means a managed lifecycle (silent); a removal
/// that only exists in `deinit` can never run (error).
struct WebViewScriptHandlerRule: Rule {
    static let emits: [RuleID] = [.webviewScriptHandlerCycle]

    static func check(type: TypeFacts, path: String, configuration: Configuration) -> [Finding] {
        guard type.isReferenceType == true else { return [] }
        guard !type.hasReachableRelease(.removeScriptMessageHandler) else { return [] }
        let deinitOnly = type.releaseOnlyInDeinit(.removeScriptMessageHandler)

        return type.apiCalls.compactMap { call in
            guard call.kind == .scriptMessageHandlerAdd, call.targetIsSelf else { return nil }

            let severity: Severity
            let note: String
            if deinitOnly {
                severity = .error
                note =
                    "the handler is removed only in deinit — the controller's hold on self means deinit never runs; remove it from a reachable teardown path or register a weak proxy"
            } else {
                severity = configuration.severity(for: .webviewScriptHandlerCycle)
                note =
                    "no removeScriptMessageHandler(forName:) or removeAllScriptMessageHandlers() found in this type; remove the handler from a reachable teardown path or register a weak proxy"
            }
            return Finding(
                rule: .webviewScriptHandlerCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message:
                    "leak: the user content controller keeps its script message handler (self) until it is removed — web view → configuration → controller → self",
                note: note
            )
        }
    }
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import WebKit

// Removal on a reachable teardown path: the lifecycle is managed.
final class ManagedBridge: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(self, name: "bridge")
    }

    func close() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// A weak proxy is registered instead of self: the controller keeps the proxy,
// and the proxy does not keep self.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

final class ProxiedBridge: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(WeakScriptHandler(self), name: "bridge")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
````

### New file `Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift`

Create it with exactly this content (ending with one newline):

````swift
// swift-format-ignore-file
import WebKit

// The user content controller keeps the handler until it is removed, and the
// web view keeps the controller: web view → configuration → controller → self.
// Public fixes register a weak proxy instead (firefox-ios@4d83f60171,
// element-x-ios@f8d094516d).

// Removal only in deinit, which never runs while the controller holds self.
// Definite leak (error).
final class BridgeController: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(self, name: "bridge") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }
}

// No removal anywhere, through the content-world overload (warning).
final class PageController: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        let contentController = webView.configuration.userContentController
        contentController.add(self, contentWorld: .page, name: "page") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// The reply-handler registration keeps its handler the same way (warning).
final class ReplyController: NSObject, WKScriptMessageHandlerWithReply {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "reply") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {}
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 190 tests in 40 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 80 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Fixture probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift --no-cache; echo EXIT=$?'`. Expected: the output contains the summary line `arcleak: 3 finding(s) (1 error(s), 2 warning(s)) in 2 file(s)`: an `error: [webview-script-handler-cycle]` at line 15 and two `warning: [webview-script-handler-cycle]` at lines 31 and 42 of `WebViewScriptHandler.swift`; then `EXIT=1` (expected: an error-severity finding fails a run).
7. `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak rules webview-script-handler-cycle'` prints first `webview-script-handler-cycle  [default: warning]`.
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Facts/APICallFact.swift Sources/ArcLeakCore/Facts/ReleaseSite.swift Sources/ArcLeakCore/Rules/Rule.swift Sources/ArcLeakCore/Rules/UnstoredLifetimeTokenRule.swift Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: add webview-script-handler-cycle

userContentController.add(self, name:), add(_:contentWorld:name:) and
addScriptMessageHandler(_:contentWorld:name:) register self as a script
message handler that the controller keeps until it is removed, while the
configuration of the web view keeps the controller. The Apple documentation
does not state that retention, so the rule rests on observed behaviour:
public fixes replace self with a weak proxy (firefox-ios@4d83f60171,
element-x-ios@f8d094516d).

The rule follows notification-observer-leak: silent when a removal is
reachable outside deinit, error when the only removal sits in deinit,
warning otherwise. Leaks/WebViewScriptHandler (3 findings) and
Clean/WebViewScriptHandlerRemoved pin it; 190 tests pass."'
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
