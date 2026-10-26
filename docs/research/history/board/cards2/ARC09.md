# ARC09 — delegate-strong-property: pin present behaviour on the evidence's delegate shapes

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 9 of 10 (after ARC08; next ARC10)

Item 7. The rule stays opt-in and unchanged; this adds one inline-source test (no production code). Pinned today: `var delegate: (any LoginFlowDelegate)?`, `let flowDelegate: AppCoordinator`, `var tableDataSource: ListDataSource?`, `var handler: SheetDelegate?` are reported (lines 7-10); `var parentCoordinator: AppCoordinator?` (the strong-coordinator back-reference of the evidence), `weak`/`unowned` delegates, `var delegates: [AppCoordinator]` and a computed delegate are not; default configuration reports nothing.

- **Model:** haiku, low. **Size:** about 40 lines. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Tests/ArcLeakCoreTests/OptInRulesTests.swift`: new `delegateShapes` and test before `vaultSource`

## Change

### Edit 1: `Tests/ArcLeakCoreTests/OptInRulesTests.swift` (near `import Testing`)

Find this exact text (it occurs once in the file):

````swift
        #expect(findings.first?.message.contains("'delegate'") == true)
    }

    private let vaultSource = """
        import Foundation

````

Replace it with:

````swift
        #expect(findings.first?.message.contains("'delegate'") == true)
    }

    /// The back-reference shapes of public delegate leak fixes, pinned as the
    /// rule sees them today: name or declared type ending in delegate or data
    /// source, strong and stored. A strong back-reference named otherwise (a
    /// parent coordinator) is outside the heuristic.
    private let delegateShapes = """
        protocol LoginFlowDelegate: AnyObject {}
        final class AppCoordinator {}
        final class ListDataSource {}
        final class SheetDelegate {}

        final class LoginViewController {
            var delegate: (any LoginFlowDelegate)?
            let flowDelegate: AppCoordinator
            var tableDataSource: ListDataSource?
            var handler: SheetDelegate?
            var parentCoordinator: AppCoordinator?
            weak var weakDelegate: (any LoginFlowDelegate)?
            unowned let dataSource: ListDataSource
            var delegates: [AppCoordinator] = []
            var computedDelegate: SheetDelegate? { nil }

            init(flowDelegate: AppCoordinator, dataSource: ListDataSource) {
                self.flowDelegate = flowDelegate
                self.dataSource = dataSource
            }
        }
        """

    @Test("delegate-strong-property: the delegate shapes of public fixes")
    func delegateShapesWhenEnabled() {
        #expect(Analyzer().analyze(source: delegateShapes, path: "Login.swift").findings.isEmpty)
        let configuration = Configuration(
            rules: ["delegate-strong-property": .init(enabled: true)]
        )
        let findings = Analyzer(configuration: configuration)
            .analyze(source: delegateShapes, path: "Login.swift").findings
        #expect(findings.map(\.rule).allSatisfy { $0 == .delegateStrongProperty })
        #expect(findings.map(\.line) == [7, 8, 9, 10])
    }

    private let vaultSource = """
        import Foundation

````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 197 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel --filter OptInRulesTests 2>&1 | tail -3'` contains `Test run with 7 tests in 1 suite passed`.
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add Tests/ArcLeakCoreTests/OptInRulesTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "test: pin delegate-strong-property on the delegate shapes of public fixes

delegate-strong-property stays opt-in and unchanged. The new case pins
what it reports today on the back-reference shapes of public delegate leak
fixes: protocol-typed and class-typed delegates, data sources, and a
property whose declared type ends in Delegate are reported; a strong
parent-coordinator reference, weak and unowned delegates, a delegate
collection and a computed delegate are not. 197 tests pass."'
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
