# REVIEW-C — Review card for chain C (app UI)

Model: sonnet · Effort: medium · Worktree: no (read the chain C worktree `~/Developer/g-cqd/VMRunner-chains/c-app` at each card's commit) · Chain: C, run on each card's commit before it merges

- **Rerun:** each card's commands.
- **Make it fail:** revert C4's `viewDidMoveToWindow` (the test must fail), C5's fallback, and C6's plist value.
- **Check:**
  - C1 and C2 leave no `@AppStorage` without `store:` and no `UserDefaults.standard` outside `PreferencesDomain`.
  - The suite name can never equal the bundle identifier.
  - C6 removes the local monitor completely (no double count) and touches the `Info.plist` key only.
- **Red flags:**
  - `UserDefaults(suiteName:)` taking a path;
  - `NSApp` as an implicitly unwrapped access in new code;
  - `makeFirstResponder` on every `updateNSView`;
  - `restorationBehavior(.disabled)` applied unconditionally;
  - a `@dw:accept` without a reason.

Common rules: read ~/Developer/g-cqd/vmrunner-board/cards/COMMON.md first.
