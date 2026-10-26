# COMMON — Common rules (part of every implementation card)

Base: `main` at `73bceb0` (after chains A, B and C). Line anchors move: locate by text with `grep -n`, never by line number (checklist item 1).

- **Model and effort:** haiku at effort `low` for implementation and probes; sonnet at effort `medium` for reviews (CONTRIBUTING, "Agents and models").
- **Worktrees.** One long-lived worktree per chain. The integrator creates them, never the card:
  ```
  git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/a-devtools -b chain/a-devtools main
  git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/b-engine -b chain/b-engine main
  git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/c-app -b chain/c-app main
  ```
  Below, `WT` is the chain's worktree path. Every shell command runs as `cd WT && <command>`, because the working directory resets between calls.
- **Start of every card.** `git -C WT status --short` must print nothing. If it prints anything, stop and report.
- **Edits.** Edit only the files listed. Before running anything, format them with `cd WT && swift-format format -i <each .swift file touched>`.
- **Commands.** Run them in order. If any result differs from the expected one, stop: do not commit, and report the command and the first 40 lines of its output. Never weaken a test, a baseline or a configuration to get green.
- **Gate.** `cd WT && swift run vmr check` must exit 0 with every step line starting `PASS`. It has 8 steps: format, swiftlint, docs, workflows, policy, build, test and analyzers. Chain A is merged, so `workflows` is part of the gate.
- **Commit.** `git -C WT add <files> && git -C WT commit -S -m "<message>"`. One commit per card; no push, amend or rebase.
- **Report.** The commit SHA, `git -C WT show --stat HEAD`, and the last 5 lines of each command's output.
- **Never touch:**
  - `Sources/VMRunner/Network`, `Sources/VMRunner/Policy`, `Sources/NetPolicy`, `Sources/NetStack`
  - `Package.swift`, `Package.resolved`
  - `Sources/TestKit`, `Tests/TestKitTests`
  - `Sources/VMHelper*`, `Sources/DevTools/Guest*`, `Sources/GuestConsole`
  - `Sources/VMRunner/Model/Security.swift` and the console fields of `VMConfig`
  - analyzer baselines (`.*-baseline.json`)
  - `.vmr.json`, `.swiftlint.yml`

## Worktree paths

- Chain A: `WT = ~/Developer/g-cqd/VMRunner-chains/a-devtools` (branch `chain/a-devtools`)
- Chain B: `WT = ~/Developer/g-cqd/VMRunner-chains/b-engine` (branch `chain/b-engine`)
- Chain C: `WT = ~/Developer/g-cqd/VMRunner-chains/c-app` (branch `chain/c-app`)

## Lessons from chains A, B and C (every executor must follow them)

- **Gate time.** `swift run vmr check` takes 3 to 10 minutes, longer when the machine is loaded: run it in the background writing to a log, wait for its exit status, never commit before it exits 0 with all 8 steps `PASS`. A time-limit failure in an unrelated test is rerun once; report both runs.
- **Strict memory safety.** `String(format:)` and other unsafe-marked initializers do not compile in tests or sources: build strings another way (`String(_:radix:)`, interpolation). Use `unsafe` only where unavoidable and place it on the expression.
- **SwiftLint.** A false positive is silenced with a line-level `// swiftlint:disable:this <rule>` comment, as already done in the repo (`Sources/NetPolicy/NetworkHost.swift`, `Sources/GuestConsole/LossyText.swift`); never edit `.swiftlint.yml`. `type_body_length` limits a class body to 300 counted lines (non-blank, non-comment): the `VMController` body is near 293; a card that adds lines to it moves code into a same-file `extension`, never disables the rule. Lines stay under 140 columns.
- **Deadwood.** A declaration used only by tests is accepted with a TRAILING comment on the reported declaration line: `// @dw:accept:this <rule> -- <short reason>` (a standalone comment above a doc comment does not apply; one between a doc comment and its declaration orphans the doc comment). Prefer wiring the use in the same card.
- **Dolly.** Advisory near-clones are allowed; an exact clone in the new lines is not.
- **Bench.** A figure marked `ok` within tolerance is not a regression; `swift run vmr bench record` only if the card says so.
- **Concurrency.** Use TestKit `AsyncGate`, `AsyncEventProbe`, `TestClock`; never real sleeps; no `nonisolated(unsafe)`.
- **Stop rule.** If the card's own code fails to compile, lint or analyze, or a stop condition fires, STOP and report the first 40 lines of the error and the exact line. Do not improvise a design change.
- **Shell.** The login shell is fish: wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths; never use `~/.agent-harness/bin/work`.
