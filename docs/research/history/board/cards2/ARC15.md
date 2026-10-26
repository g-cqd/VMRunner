# ARC15 — word the README and the security pack as what they prove

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 5 of 8 (after ARC14; next ARC16)

Review fixes (A, blocking; F; G). README: the runtime-proof sentence is scoped to the rules the leak oracle covers (`Sources/leak-oracle/OracleScenarios.swift`: stored closures, lazy closures, Combine sink and assign, mutual strong properties, dispatch sources, timers, notification observers, URLSession delegates, tasks) and names the newer rules that rest on documented or observed behaviour; the not-flagged list excepts the stored Task cancelled only in deinit; the `sec-session-in-cycle` row says `@al:disable` has no effect on it. Security pack: 'that cleanup never runs' becomes 'that cleanup may never run' in the message, summary, explanation and doc comment, because `keepsSelfAlive` includes warnings that are not proven cycles.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `README.md`: the not-flagged paragraph, the runtime-proof paragraph, the two `sec-` rows of the Rules table
  - `Sources/ArcLeakCore/Rules/SecurityPack.swift`: doc comment of `SecurityPack`, message of `unreachableCleanup`
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `summary` of `.secCleanupInUnreachableDeinit`, `explanation` of `.secCleanupInUnreachableDeinit` and `.secSessionInCycle`
  - `Tests/ArcLeakCoreTests/OptInRulesTests.swift`: one `#expect` in `secCleanupWhenEnabled`

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
What arcleak deliberately does **not** flag: transient escapes (completion
handlers, finite `Task`s — deferred deallocation, not leaks), non-escaping
closures, value-type `self` (SwiftUI bodies), the same-lifetime
````

Replace it with:

````markdown
What arcleak deliberately does **not** flag: transient escapes (completion
handlers, finite `Task`s — deferred deallocation, not leaks — except a `Task`
stored on `self` and cancelled only in `deinit`), non-escaping
closures, value-type `self` (SwiftUI bodies), the same-lifetime
````

### Edit 2: `README.md`

Find this exact text (it occurs once in the file):

````markdown
Every retention contract the rules encode is runtime-proven: the leak oracle
(`Scripts/run-leak-oracle.sh`) reconstructs each one and verifies it with
`leaks -atExit` and deinit canaries on every macOS CI run.
````

Replace it with:

````markdown
The retention contracts of the original anchor and cycle rules (stored
closures, Combine `sink` and `assign`, timers, notification observers,
`URLSession` delegates, dispatch sources, tasks, mutual strong properties)
are runtime-proven: the leak oracle (`Scripts/run-leak-oracle.sh`)
reconstructs each one and verifies it with `leaks -atExit` and deinit
canaries on every macOS CI run. The oracle does not cover
`webview-script-handler-cycle`, `kvo-observation-self-cycle`, the RxSwift and
SwiftSignalKit subscriptions of `combine-sink-self-cycle`, or closures stored
on an owned child: those rest on documented or observed behaviour and on
public fixes, cited in each rule's explanation (`arcleak rules <id>`).
````

### Edit 3: `README.md`

Find this exact text (it occurs once in the file):

````markdown
| `sec-session-in-cycle` | opt-in tag | security (CWE-401): adds a note to each cycle finding on a type that keeps a `WKWebView`, `LAContext`, `ASWebAuthenticationSession` or a `URLSession` with a delegate; no finding of its own |
| `sec-cleanup-in-unreachable-deinit` | note, opt-in | security (CWE-401, CWE-226): a `deinit` that wipes bytes, invalidates a session, closes a handle or cancels work, in a type kept alive by a cycle reported on that type |
````

Replace it with:

````markdown
| `sec-session-in-cycle` | opt-in tag | security (CWE-401): adds a note to each cycle finding on a type that keeps a `WKWebView`, `LAContext`, `ASWebAuthenticationSession` or a `URLSession` with a delegate; no finding of its own. `@al:disable` has no effect on it, since it emits no findings to suppress: turn it off in `.arcleak.json` |
| `sec-cleanup-in-unreachable-deinit` | note, opt-in | security (CWE-401, CWE-226): a `deinit` that wipes bytes, invalidates a session, closes a handle or cancels work, in a type that a cycle or anchor finding on that type may keep alive |
````

### Edit 4: `Sources/ArcLeakCore/Rules/SecurityPack.swift`

Find this exact text (it occurs once in the file):

````swift
/// `sec-cleanup-in-unreachable-deinit` (CWE-401, CWE-226): the type's deinit
/// wipes bytes, invalidates, closes, cancels or removes something, and a cycle
/// reported on the same type keeps it alive, so that cleanup never runs.
````

Replace it with:

````swift
/// `sec-cleanup-in-unreachable-deinit` (CWE-401, CWE-226): the type's deinit
/// wipes bytes, invalidates, closes, cancels or removes something, and a
/// finding reported on the same type may keep it alive, so that cleanup may
/// never run. "May": `keepsSelfAlive` includes warnings, which are not all
/// proven cycles (a source may complete, a teardown may run).
````

### Edit 5: `Sources/ArcLeakCore/Rules/SecurityPack.swift`

Find this exact text (it occurs once in the file):

````swift
but the \(cycle.rule.rawValue) finding here keeps '\(type.name)' alive, so that cleanup never runs",
````

Replace it with:

````swift
but the \(cycle.rule.rawValue) finding here may keep '\(type.name)' alive, so that cleanup may never run",
````

### Edit 6: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            "deinit wipes bytes, invalidates a session, closes a handle or cancels work in a type kept alive by a reported cycle (opt-in)"
````

Replace it with:

````swift
            "deinit wipes bytes, invalidates a session, closes a handle or cancels work in a type a reported cycle may keep alive (opt-in)"
````

### Edit 7: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            on. When the same type is kept alive by a cycle arcleak reports
            (stored-closure-strong-self, combine-sink-self-cycle,
            task-nonterminating-self, …), deinit never runs: secrets stay in memory,
            sessions stay valid, handles stay open. The finding is a note anchored
            on the cycle finding it depends on.
````

Replace it with:

````swift
            on. When the same type has a finding arcleak reports as keeping it alive
            (stored-closure-strong-self, combine-sink-self-cycle,
            task-nonterminating-self, …), deinit may never run: secrets can stay in
            memory, sessions valid, handles open. "May": some of those findings are
            warnings, not proven cycles (a source may complete, a teardown may run).
            The finding is a note anchored on the cycle finding it depends on.
````

### Edit 8: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            Types are matched by name; cross-type cycles of mutual-strong-properties
            are not tagged.
````

Replace it with:

````swift
            Types are matched by name; cross-type cycles of mutual-strong-properties
            are not tagged. A `@al:disable sec-session-in-cycle` directive has no
            effect, since there is no finding to suppress; disable the rule in
            `.arcleak.json` instead.
````

### Edit 9: `Tests/ArcLeakCoreTests/OptInRulesTests.swift`

Find this exact text (it occurs once in the file):

````swift
        #expect(cleanup.message.contains("stored-closure-strong-self"))
````

Replace it with:

````swift
        #expect(cleanup.message.contains("stored-closure-strong-self"))
        #expect(cleanup.message.hasSuffix("so that cleanup may never run"))
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 199 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak rules sec-cleanup-in-unreachable-deinit; echo EXIT=$?'`. Expected: the explanation contains the line `task-nonterminating-self, …), deinit may never run: secrets can stay in`; then `EXIT=0`.
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 45 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M`, `D` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Rules/SecurityPack.swift Tests/ArcLeakCoreTests/OptInRulesTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "docs: scope the runtime-proof claim and the security pack wording

The README said every retention contract is runtime-proven, but the leak
oracle covers only the original anchor and cycle rules. The sentence now
names what the oracle covers and says that webview-script-handler-cycle,
kvo-observation-self-cycle, the RxSwift and SwiftSignalKit subscriptions and
owned-child closures rest on documented or observed behaviour and public
fixes. The list of what is not flagged now excepts a Task stored on self and
cancelled only in deinit, and the sec-session-in-cycle row says that
@al:disable has no effect on it, since it emits no findings.

sec-cleanup-in-unreachable-deinit said that the cleanup never runs, but the
findings it builds on include warnings that are not proven cycles: the
message, summary and explanation now say may never run, and
OptInRulesTests pins the message. 199 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `docs: scope the runtime-proof claim and the security pack wording`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

