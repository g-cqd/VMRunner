# ARC16 — matchUserContract: return early unless a contract has the callee name

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 6 of 8 (after ARC15; next ARC17)

Review fix (H, finding 8). Since ARC03, `FactsExtractor.matchUserContract` builds the `labels` array and the `userContracts + Self.builtInContracts` list for every member call. It now returns early unless the callee is a built-in callee name (`subscribe`, `bind`, `drive`, `start`) or the callee of a user contract; with no user contracts that is the old early return plus a set lookup. No behaviour change.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `matchUserContract` (new early return) and new `builtInCallees` after `builtInContracts`

## Change

### Edit 1: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
    private func matchUserContract(_ node: FunctionCallExprSyntax) -> APICallFact? {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let callee = member.declName.baseName.text
        let labels = node.arguments.compactMap { $0.label?.text }
        for contract in userContracts + Self.builtInContracts where contract.callee == callee {
````

Replace it with:

````swift
    private func matchUserContract(_ node: FunctionCallExprSyntax) -> APICallFact? {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let callee = member.declName.baseName.text
        // Every member call passes here: return before allocating anything
        // unless a user or built-in contract has this callee name.
        guard Self.builtInCallees.contains(callee) || userContracts.contains(where: { $0.callee == callee }) else {
            return nil
        }
        let labels = node.arguments.compactMap { $0.label?.text }
        for contract in userContracts + Self.builtInContracts where contract.callee == callee {
````

### Edit 2: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
            tokenName: "the signal's Disposable",
            template: .signalDisposable
        ),
    ]
````

Replace it with:

````swift
            tokenName: "the signal's Disposable",
            template: .signalDisposable
        ),
    ]

    private static let builtInCallees = Set(builtInContracts.map(\.callee))
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add Sources/ArcLeakCore/Extraction/FactsExtraction.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "refactor: skip contract matching for callees no contract names

matchUserContract runs for every member call. Before the built-in reactive
contracts it returned at once when no user contract was configured; since
then it built the labels array and concatenated the contract lists on every
call, whatever the callee. It now returns before allocating anything unless
a built-in or user contract has the callee name, so the common case costs a
set lookup again. Behaviour is unchanged. 199 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `refactor: skip contract matching for callees no contract names`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

