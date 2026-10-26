# INDEX-R — Chain R: fix the machine-settings layout

Base: `main` at `2974518`. Files: COMMON.md (in `../cards/`), this index, R01.md to R03.md (one card each, one commit each). The
code is under `Sources/VMRunner/Views/` (Editor, Help, NewMachine). Evidence: the renders in `../layout-shots/` (`before-*`, then `r1-*`, `r2-*`,
`r3-*`).

## What the chain fixes

In the machine editor, the sections floated in a centred column in the wide detail pane (R01); a few rows lacked the trailing "?" so their
control sat about 30 pt right of the rows around it (R02); and a stepper row showed its value beside the title instead of at the trailing
edge like every other row (R03).

## The cause

A grouped `Form` on macOS never draws a section wider than about 696 pt. When the form is wider than about 742 pt (696 plus a 23 pt margin
on each side), it centres that column. Measured on macOS 27:

| pane width | card x-range | card width |
|---|---|---|
| 560 | 23–536 | 512 |
| 700 | 23–676 | 652 |
| 800 | 51–748 | 696 |
| 1100 | 201–898 | 696 |
| 1400 | 351–1048 | 696 |

The editor fills the `NavigationSplitView` detail pane (800 to 1400 pt), so it showed a centred column.

**Refuted hypotheses.**
- The `settingHelp` `HStack` does not break the row layout: toggles stay switches and labels stay leading.
- Captions and `DisclosureGroup`s align like Settings.
- The New Machine sheet (560) and Settings (520) look right only because they are under 742 pt wide.

**Things tried for R01 that did not help:** `.contentMargins(.horizontal, …)`; `safeAreaPadding`; `frame(maxWidth: .infinity)`;
`containerRelativeFrame` row widths (the cards fill, but the row separators stay at the centred span); a fixed-width column (the scroller
ends mid-pane).

**Secondary cause.** The trailing column of the rows was not uniform: rows with no "?" put their control about 30 pt right of the others
(R02), and a stepper row put its value beside the title with the arrows at the far edge (R03).

## How the cards were checked (read this before trusting them)

- Every card's text was applied, formatted with `swift-format`, built and gated with `swift run vmr check` in order on a scratch clone of
  `main` at `2974518`: 8/8 `PASS` after each card (format, swiftlint, docs, workflows, policy, build, test, analyzers). The code blocks were
  generated from those commits (`git show`), so they are byte-identical to them; each `old` block was checked to occur once in the file as
  the previous card leaves it.
- R03's first gate run had one unrelated flaky failure, `UserNetStackTests` `pingToLoopbackThroughTheStack` (Tests in NetStack); the rerun
  was 8/8 with no change.
- The gate summaries, quoted from the gate logs (times differ from host to host):

R01:

```
PASS  format (4s)
PASS  swiftlint (4s)
PASS  docs (0s)
PASS  workflows (5s)
PASS  policy (0s)
PASS  build (166s)
PASS  test (118s)
PASS  analyzers (5s)
OK: all 8 step(s) passed
```

R02:

```
PASS  format (5s)
PASS  swiftlint (0s)
PASS  docs (0s)
PASS  workflows (0s)
PASS  policy (0s)
PASS  build (32s)
PASS  test (74s)
PASS  analyzers (1s)
OK: all 8 step(s) passed
```

R03, first run:

```
PASS  format (31s)
PASS  swiftlint (1s)
PASS  docs (3s)
PASS  workflows (0s)
PASS  policy (0s)
PASS  build (42s)
FAIL  test (129s)
PASS  analyzers (9s)
FAILED: 1 of 8 step(s)
```

R03, rerun with no change:

```
PASS  format (21s)
PASS  swiftlint (0s)
PASS  docs (0s)
PASS  workflows (0s)
PASS  policy (0s)
PASS  build (18s)
PASS  test (139s)
PASS  analyzers (4s)
OK: all 8 step(s) passed
```

- The focused suites passed 48 tests in 8 suites after each card. The owner said "HelpTests/ModelTests", but those are FILE names. The
  suites inside are `HelpCatalogTests` and `HelpNavigatorTests` (`HelpTests.swift`), and `ConfigTests`, `SecurityTests`, `APFSTests`,
  `DisplayChoiceTests` and `DiskImageTests` (`ModelTests.swift`). `--filter HelpTests` would match nothing.
- The renders came from an offscreen harness: a test file kept outside the repository, `NSHostingView` in a never-shown borderless window,
  `cacheDisplay`. It was never committed and was removed before each gate. The scratch clones are deleted afterwards.
- Nothing was run in the real app: the owner-check list below is the only check of the real window.

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/r-layout -b chain/r-layout 2974518
```
`WT = ~/Developer/g-cqd/VMRunner-chains/r-layout`, branch `chain/r-layout`. One chain, cards strictly in order, one build at a time. haiku (effort low) executes each card;
sonnet (effort medium) reviews every card before dispatch and the chain before merge; opus merges after the gate on the merged tree.

## How to read the code blocks of a card

Blocks start at the left margin; an `old` block is exact, blank lines and indentation included, and occurs once in its file (check its
first line with the `grep -nF` the card gives). Blocks that hold a Markdown code fence use four backticks. "Create" means a new file with
exactly that text; "Replace the whole contents" means the file's text becomes exactly that.

## Rules for chain R (they override COMMON where they differ)

- **No outside project named** in code, docs, comments or commit messages.
- **No board or card ids** (`R01`...) anywhere in the repository: code, docs, comments, commit messages.
- **One atomic, signed (`git commit -S`) commit per card that builds**, made only after `swift run vmr check` printed 8 `PASS` lines
  (format, swiftlint, docs, workflows, policy, build, test, analyzers) and the executor READ them. Run it in the background to a log and
  wait for its exit; it takes 3 to 10 minutes. No push, amend or rebase.
- Swift 6.4 strict memory safety; warnings are errors.
- SwiftLint strict: `type_body_length` 300, `function_body_length` 60, lines under 140 columns. Never edit `.swiftlint.yml` or baselines.
- Run `swift-format format -i` on touched files before the gate.
- Edit only the files listed.
- If a test fails, STOP and report the test and its output; never edit a test, limit or baseline to get green.
- A compile, format or lint error in the card's code: fix it minimally without changing behaviour and list each fix with the compiler
  line; otherwise STOP.
- Agents never start a VM, never launch or open the real app window, never open `~/Library` or `~/Library/Application Support/VMRunner`.
- Shell is fish: wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.
- Known flaky test, unrelated to this chain: `UserNetStackTests` `pingToLoopbackThroughTheStack` (Tests in NetStack) failed once on this
  host during R03's gate and passed on rerun with no change. A failure in it alone may be rerun ONCE; report both runs. Any other failure:
  STOP.

Focused tests after each edit, before the gate:
```
swift build --build-tests
swift test --skip-build --filter "HelpCatalogTests|HelpNavigatorTests|ConfigTests|SecurityTests|APFSTests|DisplayChoiceTests|DiskImageTests"
```
Expect `48 tests in 8 suites passed` (observed after each commit).

Never-touch list: COMMON's list holds. These cards touch only the Swift files each lists under `Sources/VMRunner/Views/`; none touches
`Package.swift`, `.vmr.json` or `.swiftlint.yml`.

## Order, dependencies and files

| Card | What | Needs | Files (N = new; under `Sources/VMRunner/Views/`) | Size | Risk |
|---|---|---|---|---|---|
| R01 | `EditorForm`: the editor's grouped form with a trailing content margin of `width - 742`, so sections start at the leading edge | — | `Editor/ConfigEditor.swift`, `Editor/EditorForm.swift` (N) | 33 | low |
| R02 | `settingHelp(_:tooltip:)`; every setting row ends with its "?"; the Linux display note's "?" moves to the section header | R01 (order only; no shared file) | `Editor/DisplaySection.swift`, `Editor/IdentitySection.swift`, `Editor/NetworkSection.swift`, `Editor/SmallSections.swift`, `Help/HelpButton.swift` | 28 | low |
| R03 | `ValueStepper`: the value just before the arrows, for the editor's steppers and the New Machine sheet | R02 (`DisplaySection.swift`) | `Editor/DisplaySection.swift`, `Editor/ResourceSteppers.swift`, `Editor/SecuritySection.swift`, `Editor/StorageSection.swift`, `NewMachine/NewMachineSheet.swift` | 80 | medium (the shared New Machine sheet; accessibility) |

Sizes are added plus removed lines (`git show --numstat`). Dispatch order: R01, R02, R03.

## Owner decisions (each card implements the default)

1. **A leading column at the form's cap, instead of filling the whole pane.** Filling needs a custom `ScrollView` of card sections, a
   bigger change; at 1400 pt about 680 pt stays empty on the trailing side.
2. **742 is a measured constant, not an API** (none exists). If a later macOS changes the cap, the result is centred within the narrower
   area, not broken.
3. **The Linux display "?" moved to the section header.**
4. **The stepper value is grey**, like `LabeledContent` values.
5. **The New Machine sheet's steppers change too.**

## Risks

- R01's 742 constant is measured on macOS 27 only (decision 2).
- R03 changes a view the New Machine sheet shares, and replaces the stepper's accessibility label with a labels-hidden form.
- Dark appearance was not rendered.
- The extra trailing space at wide windows (decision 1).

## Owner check list (never dispatched to an agent)

After the merge, the owner opens each section in the real app, in a wide window and a narrow one, light and dark, on a macOS machine and a
Linux machine, and looks at:

- **General:** the sections start at the leading edge; the scroller is at the pane's right edge.
- **Compute:** CPU cores and Memory show their value just before the arrows; the "?" column is aligned.
- **Display** (Match window, preset, Custom; Linux 1× and 2×): Width and Height steppers (Custom) and pixel density show the value at the
  trailing edge; on Linux the header's "?" opens the boot-text topic, with no "?" beside the caption.
- **Storage** (add an extra disk row): the disk size stepper; the list rows are unchanged.
- **Network** (NAT, filtered, none) with the policy section: in filtered mode the deny-action picker and the reset toggle end with a "?"
  and show their own tooltips.
- **Sharing** (a folder row, clipboard, Rosetta on Linux): rows align.
- **Security** (the exposures disclosure): the runtime limit stepper.
- **Input and audio:** both toggles end with a "?"; Microphone's tooltip is its own.
- **Provisioning** (Linux: installer and spec): rows align.
- **Console:** there is no separate console section; the Devices section holds "Serial console (local socket)" on Linux, and the console
  switch lives in Devices.
- **Automation:** rows align.
- **Boot / first-boot account** (a macOS 27 guest that has never booted): "Create account automatically" ends with a "?".
- **Snapshots:** the section starts at the leading edge.
- Also: a managed lock if available (it sits before the "?"), VoiceOver on a stepper row (reads, for example, "CPU cores, 4, stepper"),
  and the tooltips on Microphone and the filtered-network rows.

## After the chain

Merge by fast-forward, run the gate on the merged tree, remove the worktree (CONTRIBUTING, "Worktrees and cleanup").

## Follow-ups found while carding (not in this chain)

- The `NetworkPolicySection` "Block my Mac and local networks" toggle has `.help` but no "?".
- The first-boot account fields have no "?".
- The extra-disk and shared-folder list rows and the "Add …" buttons use their own `HStack` layout.
- The flaky `UserNetStackTests.pingToLoopbackThroughTheStack` test.
- Dark appearance was not rendered.

## What a sonnet pre-dispatch review should read hardest

- **R01**: the 742 constant and its `onGeometryChange` feedback. Can a margin change the width it measures? The margin is a content margin
  of the scroll content, so the measured outer width does not change; the reviewer should confirm that no layout loop is possible.
- **R02**: the tooltip order with `managedLock` (the lock `HStack` inside, the help outer), and that `settingHelp(_:)` calls the overload
  (no clone of the body).
- **R03**: the accessibility of a labels-hidden `Stepper`; the Storage resize binding (`resize` is called only on change, as before); and the
  New Machine sheet change.
- **The anchors' uniqueness**, in every card (each `old` block and its `grep -nF` first line).
