# CHECKLIST — Pre-dispatch checklist and after-each-merge steps

## Pre-dispatch checklist (sonnet applies it to each card before dispatch)

1. `git -C ~/Developer/g-cqd/VMRunner log -1 --format=%h main` gives `a80f096`, or every anchor of the card is re-checked with `sed -n` on the current `main` (and on WT after the previous card).
2. No file of the card appears in `git diff --name-only main...<branch>` for any locked worktree (`git worktree list`). Otherwise mark the card CONFLICT-RISK and hold it.
3. Every type, function, suite and helper the card names exists (`grep -rn`). Every `--filter` value is the name of a test suite (`grep -rn "struct <Name>" Tests`). Every step name appears in `swift run vmr check --list`. A3 adds `workflows`.
4. Every expected result is observable and concrete: an exit code, a line prefix, exact text.
5. Every new production symbol has a production caller in the same card, or an `@dw:accept -- reason` that a later card removes (B5 and B9).
6. dolly: no new code duplicates an existing block token for token (B1's reference is written with `reduce`; the A4 and B3 loops differ in shape).
7. The card is at most about 150 changed lines and about 3 source files, or states why it may not be split (A2, B9: the change would not compile split).
8. The must-not-touch list covers the avoided areas, and the card writes nothing outside its file list.
9. The commit message is one imperative sentence in the repository's style. The model is haiku with effort `low`.
10. Every stop condition says what to report, and no step asks the agent to choose.

## After each merge (integrator)

Gate on the merged tree, then the CONTRIBUTING cleanup: `git merge-base --is-ancestor`, `git worktree remove --force`, `git branch -D`, `git worktree prune`. A chain's worktree stays until the chain's last card has merged.
