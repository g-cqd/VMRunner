# ARC08 — security pack 3/3: SARIF properties.tags for the sec- rules

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 8 of 10 (after ARC07; next ARC09)

Task item 6, output. The SARIF formatter change is small (an optional `properties` on the rule descriptor), so it is included: `RuleID.securityTags` gives `["security", "CWE-401", "CWE-226"]` for `sec-cleanup-in-unreachable-deinit` and `["security", "CWE-401"]` for `sec-session-in-cycle`; other descriptors are byte-identical (nil optionals are omitted).

- **Model:** haiku, low. **Size:** about 40 lines. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: new `securityTags` before `summary`
  - `Sources/ArcLeakCore/Diagnostics/ReportFormatter.swift`: `SarifRuleDescriptor` (+ new `SarifRuleProperties`), the `rules: RuleID.allCases.map` call in `sarif(_:root:)`
  - `Tests/ArcLeakCoreTests/BaselineAndSarifTests.swift`: `sarifOutputIsValidAndComplete`
  - `README.md`: one sentence in the Security pack paragraph

## Change

### Edit 1: `README.md`

Find this exact text (it occurs once in the file):

````markdown
{"sec-cleanup-in-unreachable-deinit": {"enabled": true},
"sec-session-in-cycle": {"enabled": true}}}`). There is no
separate switch. A configuration that names them is rejected by arcleak
0.10.2 and earlier as an unknown rule id.

Bound method references (`handler = self.method`, `sink(receiveValue:
handle)`) and self-referencing local functions passed as values feed the same
````

Replace it with:

````markdown
{"sec-cleanup-in-unreachable-deinit": {"enabled": true},
"sec-session-in-cycle": {"enabled": true}}}`). There is no
separate switch. A configuration that names them is rejected by arcleak
0.10.2 and earlier as an unknown rule id. In SARIF output their rule
descriptors carry `properties.tags` (`security` and the CWE ids).

Bound method references (`handler = self.method`, `sink(receiveValue:
handle)`) and self-referencing local functions passed as values feed the same
````

### Edit 2: `Sources/ArcLeakCore/Diagnostics/ReportFormatter.swift` (near `public enum ReportFormatter {`)

Find this exact text (it occurs once in the file):

````swift
        let id: String
        let shortDescription: SarifText
        let help: SarifText
    }

    private struct SarifText: Encodable {
````

Replace it with:

````swift
        let id: String
        let shortDescription: SarifText
        let help: SarifText
        /// `tags` for the security pack's rules (nil, so omitted, otherwise).
        let properties: SarifRuleProperties?
    }

    private struct SarifRuleProperties: Encodable {
        let tags: [String]
    }

    private struct SarifText: Encodable {
````

### Edit 3: `Sources/ArcLeakCore/Diagnostics/ReportFormatter.swift` (near `public enum ReportFormatter {`)

Find this exact text (it occurs once in the file):

````swift
                            SarifRuleDescriptor(
                                id: $0.rawValue,
                                shortDescription: SarifText(text: $0.summary),
                                help: SarifText(text: $0.explanation)
                            )
                        }
                    )),
````

Replace it with:

````swift
                            SarifRuleDescriptor(
                                id: $0.rawValue,
                                shortDescription: SarifText(text: $0.summary),
                                help: SarifText(text: $0.explanation),
                                properties: $0.securityTags.map(SarifRuleProperties.init(tags:))
                            )
                        }
                    )),
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift` (near `public enum RuleID: String, CaseIterable, Sendable, Codable {`)

Find this exact text (it occurs once in the file):

````swift
        }
    }

    /// One-line human description used by `arcleak rules`.
    public var summary: String {
        switch self {
````

Replace it with:

````swift
        }
    }

    /// SARIF `properties.tags` of the security pack's rules; nil for the
    /// others.
    public var securityTags: [String]? {
        switch self {
        case .secCleanupInUnreachableDeinit: ["security", "CWE-401", "CWE-226"]
        case .secSessionInCycle: ["security", "CWE-401"]
        default: nil
        }
    }

    /// One-line human description used by `arcleak rules`.
    public var summary: String {
        switch self {
````

### Edit 5: `Tests/ArcLeakCoreTests/BaselineAndSarifTests.swift` (near `import Testing`)

Find this exact text (it occurs once in the file):

````swift
        #expect(driver["name"] as? String == "arcleak")
        let rules = try #require(driver["rules"] as? [[String: Any]])
        #expect(rules.count == RuleID.allCases.count)

        let results = try #require(run["results"] as? [[String: Any]])
        #expect(results.count == 1)
````

Replace it with:

````swift
        #expect(driver["name"] as? String == "arcleak")
        let rules = try #require(driver["rules"] as? [[String: Any]])
        #expect(rules.count == RuleID.allCases.count)
        func tags(_ id: String) -> [String]? {
            (rules.first { $0["id"] as? String == id }?["properties"] as? [String: Any])?["tags"] as? [String]
        }
        #expect(tags("sec-cleanup-in-unreachable-deinit") == ["security", "CWE-401", "CWE-226"])
        #expect(tags("sec-session-in-cycle") == ["security", "CWE-401"])
        #expect(rules.first { $0["id"] as? String == "stored-closure-strong-self" }?["properties"] == nil)

        let results = try #require(run["results"] as? [[String: Any]])
        #expect(results.count == 1)
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 196 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/SecCleanupInUnreachableDeinit.swift --format sarif --no-cache 2>/dev/null | grep -c CWE-401'` prints `4` (two in the new `tags` arrays, two in the explanation texts).
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/ReportFormatter.swift Sources/ArcLeakCore/Diagnostics/RuleID.swift Tests/ArcLeakCoreTests/BaselineAndSarifTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "feat: tag the security rules in SARIF output

The SARIF descriptors of sec-cleanup-in-unreachable-deinit and
sec-session-in-cycle now carry properties.tags (security and their CWE
ids), so code-scanning consumers can group and filter them. Other rule
descriptors are unchanged. BaselineAndSarifTests pins the tags; 196 tests
pass."'
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
