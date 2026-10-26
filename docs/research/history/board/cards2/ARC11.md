# ARC11 — webview-script-handler-cycle: the error needs a web view the type keeps

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 1 of 8 (after ARC10 (lane/rules at 005f65f); next ARC12)

Review fix (B, blocking). `webview-script-handler-cycle` reported `error` for a deinit-only removal without proving that `self` keeps the web view: the reviewer's counterexample (a handler that holds the content controller weakly and removes itself in deinit) is not a cycle. The rule now reports `error` only when the type keeps a web view, a `WKWebViewConfiguration` or a `WKUserContentController` in a strong stored property (`storedProperties`, `strength == .strong`, `referencedTypeNames`, as `SecurityPack` does); otherwise a deinit-only removal is silent and a missing removal is capped at `warning`, with a message starting `observed:`.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift`: the whole rule (doc comment, `check`, new `cycleMessage` and `keepsWebView`)
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `explanation` of `.webviewScriptHandlerCycle`
  - `README.md`: the `webview-script-handler-cycle` row of the Rules table
  - `Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift`: two new classes at the end
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift`: one new class at the end (the reviewer's counterexample)
  - `Tests/ArcLeakCoreTests/PrecisionRegressionTests.swift`: one new test at the end of the suite

## Change

### Edit 1: `Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift`

Find this exact text (it occurs once in the file):

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

Replace it with:

````swift
/// `<…>.userContentController.add(self, name:)` — the user content controller
/// keeps its script message handlers until they are removed, and the web
/// view's configuration keeps the controller, so `self` lives as long as the
/// web view. Apple's documentation does not state the retention; public fixes
/// replace `self` with a weak proxy (firefox-ios@4d83f60171,
/// element-x-ios@f8d094516d).
///
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
            return Finding(
                rule: .webviewScriptHandlerCycle,
                severity: severity,
                path: path,
                line: call.position.line,
                column: call.position.column,
                message: message,
                note: note
            )
        }
    }

    private static let cycleMessage =
        "leak: the user content controller keeps its script message handler (self) until it is removed — web view → configuration → controller → self"

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
}
````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            keeps the controller: WKWebView → configuration → userContentController →
            self. When `self` also owns the web view the loop is closed, and a removal
            that only exists in deinit can never run.
````

Replace it with:

````swift
            keeps the controller: WKWebView → configuration → userContentController →
            self. When `self` also keeps the web view, its configuration or its content
            controller in a strong stored property, the loop is closed and a removal
            that only exists in deinit can never run: that is reported as an error.
            A type that keeps none of them is not in a cycle (the controller keeps it
            only while the web view lives): a deinit-only removal is silent there, and
            a missing removal is a warning about the observed retention.
````

### Edit 3: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `webview-script-handler-cycle` | warning† | `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`) with no reachable `removeScriptMessageHandler(forName:)` or `removeAllScriptMessageHandlers()` |
````

Replace it with:

````markdown
| `webview-script-handler-cycle` | warning† | `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`) with no reachable `removeScriptMessageHandler(forName:)` or `removeAllScriptMessageHandlers()`; the deinit-only **error** needs a strong stored web view, configuration or content controller on the type (without one, a deinit-only removal is silent and a missing removal is an "observed" warning) |
````

### Edit 4: `Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift`

Find this exact text (it occurs once in the file):

````swift
// The reply-handler registration keeps its handler the same way (warning).
final class ReplyController: NSObject, WKScriptMessageHandlerWithReply {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "reply") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {}
}
````

Replace it with:

````swift
// The reply-handler registration keeps its handler the same way (warning).
final class ReplyController: NSObject, WKScriptMessageHandlerWithReply {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "reply") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {}
}

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

// A controller the type does not keep, and no removal: no cycle is proven,
// but self lives as long as the web view (observed behaviour; warning).
final class AttachedBridge: NSObject, WKScriptMessageHandler {
    func attach(to contentController: WKUserContentController) {
        contentController.add(self, name: "attached") // #al:expect webview-script-handler-cycle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
````

### Edit 5: `Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift`

Find this exact text (it occurs once in the file):

````swift
final class ProxiedBridge: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(WeakScriptHandler(self), name: "bridge")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
````

Replace it with:

````swift
final class ProxiedBridge: NSObject, WKScriptMessageHandler {
    let webView = WKWebView()

    func load() {
        webView.configuration.userContentController.add(WeakScriptHandler(self), name: "bridge")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

// The controller is held weakly and the handler is removed in deinit: self
// keeps neither the web view nor the controller, so there is no cycle. The
// controller keeps self only while the web view lives, and deinit runs once
// it is gone.
final class WeakControllerBridge: NSObject, WKScriptMessageHandler {
    weak var contentController: WKUserContentController?

    func attach(to contentController: WKUserContentController) {
        self.contentController = contentController
        contentController.add(self, name: "b")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}

    deinit {
        contentController?.removeScriptMessageHandler(forName: "b")
    }
}
````

### Edit 6: `Tests/ArcLeakCoreTests/PrecisionRegressionTests.swift`

Find this exact text (it occurs once in the file):

````swift
        let sinkFindings = findings(source).filter { $0.rule == .combineSinkSelfCycle }
        #expect(sinkFindings.count == 1)
        #expect(sinkFindings.first?.message.contains("nested closure's capture list") == false)
    }
}
````

Replace it with:

````swift
        let sinkFindings = findings(source).filter { $0.rule == .combineSinkSelfCycle }
        #expect(sinkFindings.count == 1)
        #expect(sinkFindings.first?.message.contains("nested closure's capture list") == false)
    }

    // MARK: - Script message handlers

    @Test("webview-script-handler-cycle: the deinit-only error needs a web view or controller self keeps")
    func scriptHandlerErrorNeedsOwnership() {
        let source = """
            import WebKit
            final class Owning: NSObject, WKScriptMessageHandler {
                let webView = WKWebView()
                func load() {
                    webView.configuration.userContentController.add(self, name: "a")
                }
                deinit {
                    webView.configuration.userContentController.removeScriptMessageHandler(forName: "a")
                }
            }
            final class WeakHolder: NSObject, WKScriptMessageHandler {
                weak var contentController: WKUserContentController?
                func attach(to contentController: WKUserContentController) {
                    self.contentController = contentController
                    contentController.add(self, name: "b")
                }
                deinit {
                    contentController?.removeScriptMessageHandler(forName: "b")
                }
            }
            final class Attached: NSObject, WKScriptMessageHandler {
                func attach(to contentController: WKUserContentController) {
                    contentController.add(self, name: "c")
                }
            }
            """
        let handlerFindings = findings(source).filter { $0.rule == .webviewScriptHandlerCycle }
        #expect(handlerFindings.map(\.line) == [5, 23])
        #expect(handlerFindings.map(\.severity) == [.error, .warning])
        #expect(handlerFindings.last?.message.hasPrefix("observed:") == true)
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 198 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift --no-cache; echo EXIT=$?'`. Expected: the summary line `arcleak: 5 finding(s) (2 error(s), 3 warning(s)) in 2 file(s)`, then 5 `[webview-script-handler-cycle]` lines, all in `WebViewScriptHandler.swift`: `error` at lines 15 and 55, `warning` at lines 31, 42 and 69 (the line-69 message starts `observed:`); nothing in `WebViewScriptHandlerRemoved.swift`; then `EXIT=1` (error findings make the exit status 1; that is expected here).
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 130 s on the orchestrator's copy for this first run of the lane; about 35-80 s for the later cards after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M`, `D` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Rules/WebViewScriptHandlerRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/WebViewScriptHandlerRemoved.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/WebViewScriptHandler.swift Tests/ArcLeakCoreTests/PrecisionRegressionTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "fix: require an owned web view for the deinit-only script handler error

webview-script-handler-cycle reported error for any deinit-only removal,
without proving that self closes the loop. A handler that keeps its content
controller weakly and removes itself in deinit is not in a cycle: the
controller keeps it only while the web view lives.

The error now needs a strong stored property typed as a web view (WKWebView
or a subclass named ...WebView), its configuration or its user content
controller. Without one, a deinit-only removal is silent and a missing
removal is capped at warning, with a message that says the retention is
observed. Clean/WebViewScriptHandlerRemoved gains the weak-controller shape,
Leaks/WebViewScriptHandler gains an owned-controller error and a
non-owning warning, and PrecisionRegressionTests pins the severities.
198 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `fix: require an owned web view for the deinit-only script handler error`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

