# REVIEW-A — Review card for chain A (DevTools and CI)

Model: sonnet · Effort: medium · Worktree: no (read the chain A worktree `~/Developer/g-cqd/VMRunner-chains/a-devtools` at each card's commit) · Chain: A, run on each card's commit before it merges

- **Rerun:** each card's commands, in WT at that commit.
- **Check:**
  - The diff equals the card. No file outside the card's list. No change to the avoided areas, the baselines, `.swiftlint.yml` or `.vmr.json`.
  - A2: the digests and commits equal `git ls-remote https://github.com/rhysd/actionlint refs/tags/v1.7.12` → `914e7df…`, and `git ls-remote https://github.com/zizmorcore/zizmor refs/tags/v1.31.1` → `effdb35…`. Both tags are lightweight. The archive digests were verified by downloading on 2026-10-22 (actionlint `aba9ced…`, zizmor `ad5aa63…`).
  - A3: the zizmor arguments include `--strict-collection` and `--offline`. The step throws on a non-zero exit (11-14 included). The test's expectations would fail if a flag were dropped.
- **Make it fail:** revert only the source part of A1 or A2; its new test must fail.
- **Red flags:**
  - a `<TOOL>_BIN` path in CI;
  - a `--min-severity`, `--persona` or `--no-config` flag;
  - `.github/zizmor.yml` or `actionlint.yaml` changed to silence something;
  - `try?` swallowing an install error;
  - a checksum taken from a release's own checksum file.

Common rules: read ~/Developer/g-cqd/vmrunner-board/cards/COMMON.md first.
