# REVIEW-B — Review card for chain B (engine hashing and start)

Model: sonnet · Effort: medium · Worktree: no (read the chain B worktree `~/Developer/g-cqd/VMRunner-chains/b-engine` at each card's commit) · Chain: B, run on each card's commit before it merges

- **Rerun:** each card's commands. For B3 and B4, rerun `swift run vmr check bench` and compare `checksum.sha256.instructionsPerMiB` with the base. It must not be worse by more than 3%, and allocation counts must be equal.
- **Make it fail:**
  - B2: revert the table and confirm `CRC24Tests` stays green, then corrupt one table entry and confirm it fails.
  - B7: revert `init(from:)` and confirm the `md5` case fails.
  - B9: drop the `guard token == run` and confirm the new test fails.
- **Check:**
  - The `unsafe` sites carry a justification comment.
  - `read` handles `EINTR`. No `Data` is allocated per read.
  - `forEachChunk` checks cancellation.
  - `.vmr-bench.json` changes only by deleted sha1 keys (B6), or by a re-record taken after a passing bench (B3, B4).
- **Red flags:**
  - a bench re-record after a regression;
  - `ImageStore`'s `!= .sha256` guard changed;
  - SHA-1 removed from `PGP+Key.swift`;
  - `Algorithm` gaining a case that `verify` would accept;
  - B8 or B9 changing any `MachineState` transition;
  - `@unchecked Sendable` or `nonisolated(unsafe)` added to carry the configuration.

Common rules: read ~/Developer/g-cqd/vmrunner-board/cards/COMMON.md first.
