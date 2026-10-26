# ARC18 — tidy the script handler doc comments and the summary order

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 8 of 8 (after ARC17; last card of this lane)

Review nits (I): reflow the doc comment on `APICallFact.Kind.scriptMessageHandlerAdd` (one line ran to 120 columns) and the matching sentence of the `webview-script-handler-cycle` explanation; move the `.kvoObservationSelfCycle` case of `RuleID.summary` next to `.webviewScriptHandlerCycle`, so `summary` follows the declaration order of `RuleID` like `explanation` already does. No behaviour change.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Facts/APICallFact.swift`: doc comment of `case scriptMessageHandlerAdd`
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `summary` (case order) and `explanation` of `.webviewScriptHandlerCycle` (line breaks)

## Change

### Edit 1: `Sources/ArcLeakCore/Facts/APICallFact.swift`

Find this exact text (it occurs once in the file):

````swift
        /// `<…>.userContentController.add(_:name:)` / `add(_:contentWorld:name:)`
        /// / `addScriptMessageHandler(_:contentWorld:name:)` — the controller keeps the script message handler until
        /// `removeScriptMessageHandler(forName:)` or
        /// `removeAllScriptMessageHandlers()` (observed behaviour; Apple's
        /// documentation does not state the retention).
````

Replace it with:

````swift
        /// `<…>.userContentController.add(_:name:)`, `add(_:contentWorld:name:)`
        /// or `addScriptMessageHandler(_:contentWorld:name:)` — the controller
        /// keeps the script message handler until
        /// `removeScriptMessageHandler(forName:)` or
        /// `removeAllScriptMessageHandlers()` (observed behaviour; Apple's
        /// documentation does not state the retention).
````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            "Tags cycle findings on a type holding a WKWebView, LAContext, ASWebAuthenticationSession or delegate URLSession (opt-in)"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
        }
````

Replace it with:

````swift
            "Tags cycle findings on a type holding a WKWebView, LAContext, ASWebAuthenticationSession or delegate URLSession (opt-in)"
        }
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .secCleanupInUnreachableDeinit:
````

Replace it with:

````swift
            "userContentController.add(self, name:) with no reachable removeScriptMessageHandler — the controller keeps self"
        case .kvoObservationSelfCycle:
            "observe(\\.keyPath) change handler captures `self` strongly and the NSKeyValueObservation is stored on `self`"
        case .secCleanupInUnreachableDeinit:
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            script message handler. The user content controller
            keeps the handler until `removeScriptMessageHandler(forName:)` or
            `removeAllScriptMessageHandlers()` runs, and the web view's configuration
````

Replace it with:

````swift
            script message handler. The user content controller keeps the handler
            until `removeScriptMessageHandler(forName:)` or
            `removeAllScriptMessageHandlers()` runs, and the web view's configuration
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 199 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 35 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M`, `D` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Facts/APICallFact.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "refactor: reflow the script handler docs and order the rule summaries

The doc comment of APICallFact.Kind.scriptMessageHandlerAdd and the
webview-script-handler-cycle explanation had lines broken at odd places, and
the kvo-observation-self-cycle summary sat after the security rules while
every other switch follows the declaration order of RuleID. Text and order
only; the arcleak rules output changes in line breaks of one explanation.
199 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `refactor: reflow the script handler docs and order the rule summaries`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

