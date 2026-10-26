# ARC17 — SARIF: tag CWEs in the external/cwe form too; securityTags is internal

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 7 of 8 (after ARC16; next ARC18)

Review nit (I): SARIF tags for the two security rules gain the `external/cwe/cwe-N` form. GitHub's SARIF documentation (docs.github.com, 'SARIF support for code scanning', fetched by the orchestrator) describes `properties.tags` as strings used to filter results and gives `security` as an example, but does not mention a CWE form; CodeQL query metadata uses `external/cwe/cwe-N`. Since the GitHub page could not confirm the form, both forms are kept: `["security", "external/cwe/cwe-401", "external/cwe/cwe-226", "CWE-401", "CWE-226"]` and `["security", "external/cwe/cwe-401", "CWE-401"]`. `RuleID.securityTags` becomes internal (`grep -rn securityTags Sources Tests` finds only `RuleID.swift` and `ReportFormatter.swift`, both in ArcLeakCore).

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `securityTags` (access level, doc comment, values)
  - `Tests/ArcLeakCoreTests/BaselineAndSarifTests.swift`: the two `tags(...)` expectations
  - `README.md`: the last sentence of the Security pack paragraph after the Rules table

## Change

### Edit 1: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
    /// SARIF `properties.tags` of the security pack's rules; nil for the
    /// others.
    public var securityTags: [String]? {
        switch self {
        case .secCleanupInUnreachableDeinit: ["security", "CWE-401", "CWE-226"]
        case .secSessionInCycle: ["security", "CWE-401"]
        default: nil
        }
    }
````

Replace it with:

````swift
    /// SARIF `properties.tags` of the security pack's rules; nil for the
    /// others. Each CWE is tagged in two forms: `external/cwe/cwe-N`, the tag
    /// CodeQL queries carry, and the plain `CWE-N`.
    var securityTags: [String]? {
        switch self {
        case .secCleanupInUnreachableDeinit:
            ["security", "external/cwe/cwe-401", "external/cwe/cwe-226", "CWE-401", "CWE-226"]
        case .secSessionInCycle:
            ["security", "external/cwe/cwe-401", "CWE-401"]
        default: nil
        }
    }
````

### Edit 2: `Tests/ArcLeakCoreTests/BaselineAndSarifTests.swift`

Find this exact text (it occurs once in the file):

````swift
        #expect(tags("sec-cleanup-in-unreachable-deinit") == ["security", "CWE-401", "CWE-226"])
        #expect(tags("sec-session-in-cycle") == ["security", "CWE-401"])
````

Replace it with:

````swift
        #expect(
            tags("sec-cleanup-in-unreachable-deinit")
                == ["security", "external/cwe/cwe-401", "external/cwe/cwe-226", "CWE-401", "CWE-226"]
        )
        #expect(tags("sec-session-in-cycle") == ["security", "external/cwe/cwe-401", "CWE-401"])
````

### Edit 3: `README.md`

Find this exact text (it occurs once in the file):

````markdown
descriptors carry `properties.tags` (`security` and the CWE ids).
````

Replace it with:

````markdown
descriptors carry `properties.tags`: `security`, and each CWE id in two forms,
`external/cwe/cwe-401` (the form CodeQL queries use) and `CWE-401`.
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
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Tests/ArcLeakCoreTests/BaselineAndSarifTests.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "fix: add the external/cwe tag form to the SARIF security tags

The SARIF descriptors of the security pack carried CWE-401 and CWE-226 as
plain tags. CodeQL queries tag CWEs as external/cwe/cwe-N, so both rules now
carry that form next to the plain one (the GitHub SARIF documentation
describes tags as free filter strings and names no CWE form, so the plain
form stays). RuleID.securityTags becomes internal: only ReportFormatter
reads it. BaselineAndSarifTests pins the new tags; 199 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `fix: add the external/cwe tag form to the SARIF security tags`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

