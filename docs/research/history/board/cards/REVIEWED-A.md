# REVIEWED-A — sonnet pre-dispatch review of chain A (main at 46bdd5f)

Pins verified: v1.7.12 -> 914e7df21a07ef503a81201c76d2b11c789d3fca and v1.31.1 -> effdb35fa7868863f11655db256d9008922fa427 (lightweight tags); asset names exist; GitHub's per-asset digests equal the cards' SHA-256s (actionlint aba9ced2...e6953f, zizmor ad5aa633...1d698). Chain A needs NO `@dw:accept` lines (every new production symbol has a production caller; `.deadwood.json` production:true flags test-only symbols). Apply these before dispatching each card (status in APPLIED-A.txt).

## Blocking
1. A3: `ToolLocator.swift` function spans lines 41-51 (not 41-50): Files line and step 1 say `ToolLocator.swift:41-51`; the block replaces the WHOLE `swiftlint` function including its doc comment (else a stray `}` breaks the build).
2. A6: README "fast gate" comment is at `README.md:167` (not 166); the `lint` row is at `CONTRIBUTING.md:199` (not 193); CONTRIBUTING lines 15, 39-41 and 45 are still right. Files: `CONTRIBUTING.md:15, 39-41`, a new bullet before line 45, and line 199; `README.md:167`. Step 5 targets line 199. Mark CONFLICT-RISK low with the console branch (different hunks). Write `.github/workflows/zizmor.yml` (full path) in the new bullet.
3. A8: `CONTRIBUTING.md:160-161` moved to 166-167 (line 166 ends "...for it. The setting", line 167 is "does not move the app's preferences (`UserDefaults`) or the unified log."): fix both mentions. CONFLICT-RISK low. Dispatch only after C3 has merged and WT is rebased.

## Suggestions
4. A7: the key is unchanged, so main would hit the old cache entry holding only `.build` and never save `.build-packages`. On the restore step only, replace `spm-${{ matrix.cache }}-` with `spm-${{ matrix.cache }}${{ matrix.nested }}-` on the `key:` line (~ci.yml:110) and the `restore-keys:` line (~112); drop the sentence "The key lines stay unchanged". State the YAML indentation explicitly: `path: |` at 10 spaces, the two `${{ ... }}` lines at 12 spaces.
5. A3: put one blank line before and after the new `workflows` function in GateSteps ("after line 23"); add "do not add `-config-file`: actionlint reads `.github/actionlint.yaml` itself and runs from the repository root"; before step 4 run `zizmor --help | grep no-progress` (first real use of that flag: if rejected, stop and report).
6. A5: make the doc comment true: "An unreadable `.vmr.json`, or a listed package without a `Package.swift`, leaves the root's roots only; `vmr check` fails on the first and the build and test steps on the second." State test placement: "in `AnalyzersTests`, after `rejectsBadInput`, before the closing brace". Stop on any finding in nested packages (no baseline edit).
7. A4: replace "Add `unsafe` only where the compiler asks" with "The code below already carries the `unsafe` it needs; if the build still reports a strict-memory-safety warning, stop and report it."

## Nits
- A1: the `#expect` to replace is `AnalyzersTests.swift:132-134` (131 is `let versions`); Files `:123-136`.
- A2: place `static let actionlint` and `static let zizmor` between `swiftlint` and `pinnedReleases` (pinnedReleases stays last); fix stale comments `AnalyzerLock.swift:8` ("lists and unpacks both kinds" -> "every kind") and `:88-89` ("for each analyzer and for SwiftLint" -> "for each analyzer, SwiftLint, actionlint and zizmor"); add `AnalyzerLock.swift:8, 88-89` to Files.
- A4: `PureLogicTests.swift` needs `import CryptoKit` ABOVE `import Foundation` (swift-format ordering).
- All cards: add the line "Anchors re-checked on `main` at 46bdd5f."
- COMMON/INDEX base is now 46bdd5f (done).

## Risks for a haiku executor
A2/A3 downloads fail offline (COMMON stop rule). A3 step 4 first real run of `--no-progress`. A5 step 2 nested findings mean stop. The deadwood baseline holds 22 opaque fingerprints: a surprise deadwood failure means stop and report. The dolly baseline is empty: any exact clone fails (WorkflowLintTests resembles SwiftLintPinTests but is not identical).

## Dispatch order
A1 -> A2 -> A3 -> A4 -> A5 -> A6 -> A7 in `a-devtools`, one build at a time; A8 held until C3 merges. Chain C first.
