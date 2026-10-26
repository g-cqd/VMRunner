# INDEX-T — Chain T (part 1): the Linux custom GPU in the app: foundations, the setting, builder and display (roadmap 0014, ADR-0014, ADR-NNNN)

Base: the cards were written on `main` at `2974518`. The second review replayed them, as edited, on `main` at `6bab9e9` and on `main` at `c737289` (the container chain had merged: ADR `0057` and the diary `2026-10-25-02` were taken, so the chain's ADR is `0058` and its diary `2026-10-25-03` there); at both tips `swift run vmr check` was 8/8 PASS and every card's statistics line matched. Files: this index, T01.md to T14.md (one card each, one
commit each), and T-RUN.md (the authorised real-guest run, after the chain is applied). The chain brings the host-implemented
virtio GPU that chain Q proved in a runner into the app, with a virtio input path beside the framework's. 2D and Linux only;
3D stays gated.

## What the chain builds

Chain Q's authorised run (2026-10-25) showed that a stock Debian guest binds `virtio_gpu` to a device the host implements.
This chain makes that device a setting of a Linux machine in the app. A Linux machine can choose the custom GPU (a picker with
a help topic, "Custom (experimental)"); the app builds the machine with the device, serves the guest's commands through a pure
library, shows the picture and cursor in the machine's window, and asks the guest to follow the window's size. Keyboard and
pointer reach the guest by one of two paths, both built so that a real run decides: the framework's own input view below the
custom view (events forwarded), or two virtio input devices the app implements. The core moves out of the nested runner
package into the root package, so the app and the runner share one library.

## How the cards were checked (read this before trusting them)

- Every card was applied, formatted with `swift-format`, built and gated with `swift run vmr check` (8/8 PASS) on scratch
  clones. T01 to T05 went in order on one clone. T06 to T08 were written on `2974518` in parallel, then replayed after T05
  with no conflict and gated at the T08 tip only: **the T06 and T07 trees were not gated on their own**. T09 to T11 followed.
  T12 was written on T05's tip and re-applied after T11, with one docs conflict resolved in roadmap 0014, item 3 of
  "Remaining". T13 and T14 came after. The scratch clones were deleted afterwards.
- An independent verifier applied all 14 cards **from their text only** to a fresh `2974518`: every stated tree hash
  reproduced (the T14 tree is `78030571a0274a7b2db250e8674ad349db4b718f`) and the gate passed 8/8 (format, swiftlint, docs,
  workflows, policy, build, test, analyzers including arcleak, dolly and deadwood). Applied to `main` at `6bab9e9`, every anchor
  was found exactly once, nothing conflicted, and the gate passed 8/8; the only difference was one context line, `Stepper(`
  against `ValueStepper(`, near T08's edit of `DisplaySection`.
- Test counts at the tip: VMRunnerTests 1048 in 171 suites, VirtioGPUTests 94 in 16, VirtioInputTests 46 in 6,
  VirtioGPURunnerTests 13 in 3, DevToolsTests 274 in 35.
- **Virtualization API checks.** Compiled against `MacOSX27.0.sdk` on macOS 27.0.1. A signed program that only calls
  `validate()` (entitlement `com.apple.security.virtualization` alone) reported VALID for: GPU id 16 with no framework graphics
  device plus a USB keyboard and a USB screen-coordinate pointer; GPU 16 plus one or two id 18 input devices (class 9, subclass
  0x80, 2 queues, a 136-byte configuration); GPU 16 plus `VZVirtioGraphicsDeviceConfiguration`; GPU 16 with no input devices.
  Unsigned, it fails with `VZErrorDomain` code 2. A device without a provider fails validation ("The device was missing a
  provider"), which is why the device session is made on the main actor in `prepare`. The framework's default
  `optionalFeatures.subset0` is `0x30000000`, which explains the negotiated features of the 2026-10-25 run. **No agent started
  a virtual machine.**
- **The finding that shaped input.** The 27.0 headers have no callback for guest writes to the device-specific configuration
  space. Virtio-input discovery (the guest selects a subsel, then reads) cannot be answered per query. Path (a) therefore uses
  two static configurations (keyboard, tablet), designed against a model of the Linux probe built from the driver source.
  Their side effects are documented in T12: a tablet range of 259..16384, no horizontal wheel, an accelerometer property bit,
  phantom axes on the keyboard. Path (b) keeps a `VZVirtualMachineView` below the custom view and forwards events.

## Numbers: the ADR and the diary are chosen at execution time

The chain adds one ADR (T01) and one diary entry (T14), and the container chain adds an ADR and a diary entry too. The cards therefore write the ADR number as the placeholder `NNNN` and the diary suffix as `DD` (and its title number as `D`). At T01 the executor lists `docs/adr` (`ls docs/adr | tail -n 3`), takes the highest four-digit prefix plus one as N, says it in the report and writes it in place of `NNNN` in every file, comment and commit message of T01 to T14; the ADR file keeps it in its name, so later cards find it with `ls docs/adr | grep -- '-the-virtio-gpus-pure-core-is-a-library-target'`. At T14 the executor does the same for the diary (`ls docs/diary | grep '^2026-10-25-' | tail -n 1`, plus one). On `main` before the container chain N is `0057` and DD is `02`; after it N is `0058` and DD is `03`. A leftover `NNNN` in a commit is caught by the check every card asks for (on the staged diff and on the message, not on the whole tree: the documentation checker's own comments contain the letters).

The cards no longer ask for the tree hash of the gated commit: it holds the whole base and could not match on any other base. Each card asks for its `git diff --cached --shortstat` line instead (and T12 also for the `git hash-object` of the files it creates, which is base-independent). Whole-bundle test totals are likewise the gated base's.

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/t-custom-gpu -b chain/t-custom-gpu main
```
`WT = ~/Developer/g-cqd/VMRunner-chains/t-custom-gpu`, branch `chain/t-custom-gpu`. One chain, cards
strictly in order, one build at a time. haiku (effort low) executes each card; sonnet (effort medium) reviews every card
before dispatch and the chain before merge; opus merges after the gate on the merged tree.

## Rules for chain T (they override COMMON where they differ)

The rules are stated in full at the top of every card; in short:

- No outside project named in code, comments, docs or commit messages. No board or card id and no chain name anywhere in the
  repository. No planning word in an identifier, file, target or flag (ADR-0042).
- Every commit atomic, signed (`-S`), builds, and `swift run vmr check` is 8/8 PASS before it, the 8 lines READ.
- Swift 6.4 strict memory safety (`unsafe` on the expression; guest memory through one bounds-checked copy), warnings are
  errors, SwiftLint strict, Swift Testing only, `package` access and never `public` (ADR-0047). The leak analyzer stays clean.
- Agents never start a virtual machine and run the runner only with `--help`, `--describe` or `--dry-run` against a scratch
  directory under `/tmp`. Real runs are T-RUN's.
- A compile, format or lint error in a card's code: fix minimally and list each fix with the compiler line. A test that
  fails: STOP and report; never edit a test to get green. After a card's edits, `git write-tree` must print the card's tree
  hash; a different hash means a text differs from the one that was gated: stop.
- Shell: fish is the login shell; wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.

## Order, dependencies and files

Sizes are the cards' own diff statistics (insertions and deletions where the card gives both). Risk is the index author's
reading of how much a card can hurt if wrong.

| Card | What | Needs | Files (main ones) | Size | Risk |
|---|---|---|---|---|---|
| T01 | ADR-NNNN (the layout decision), roadmap 0014 with the real-run facts, dated note in ADR-0014; docs only | — | `docs/adr/NNNN-…md`, `docs/roadmap/0014-gpu-acceleration.md`, `docs/adr/0014-…md` | 3 files, +137 −14 | low |
| T02 | The core moves to root targets `VirtioGPU`, `VirtioGPURunnerCore`, `VirtioGPURunner`; the nested package is removed; `package` access; three layering tests rewritten; `build-app` gets `--product VMRunner` | T01 | `Package.swift`, the moved sources and tests, `Tests/DevToolsTests/ModuleBoundaryTests.swift` | 45 files, +259 −242 | medium |
| T03 | Queue serving in the library; transfer cost bounded (full-width transfer is one span, rows at most 8192) | T02 | `VirtioGPU` sources and tests | 8 files, +555 −62 | **high** |
| T04 | Runner shuts down on SIGTERM and SIGINT in a signal-safe way; the PNG is mode 0600 from creation | T03 | `VirtioGPURunnerCore` sources and tests | 8 files, +212 −32 | medium |
| T05 | App adapter in `Engine/CustomGPU`; the app links `VirtioGPU` | T04 | `Engine/CustomGPU`, `Package.swift` | 14 files, +462 −20 | **high** |
| T06 | `GPUChoice` model, tolerant decode, saved state and suspend | T05 | model, storage | 5 files, +163 | low |
| T07 | Posture, exposure summary, `AllowCustomGPU` policy key | T06 | security and policy sources | 6 files, +106 | low |
| T08 | The picker for Linux guests and its help topic. **Must not ship without T09 and T10** | T07 | editor (`DisplaySection`), help | 7 files, +140 | low |
| T09 | The builder: a machine set to the custom GPU is configured with the device, made on the main actor, held by the machine | T08 | machine builder | 17 files, +547 −30 | **high** |
| T10 | Display view and running descriptor: one image per refresh at most | T09 | display view sources | 18 files, +872 −75 | **high** |
| T11 | Resize adapter: the resize request and the display event bit | T10 | display adapter | 14 files, +400 −30 | medium |
| T12 | `VirtioInput`, a pure library: two fixed configuration layouts, key table, event encoder, bounded event queue | T11 | `Sources/VirtioInput`, tests | 20 files, +1345 −4 | **high** |
| T13 | One input protocol, the developer default `CustomGPUInput`, the framework input path | T12 | input sources, developer settings | 17 files, +579 −15 | medium |
| T14 | The virtio input path; the app links `VirtioInput`; docs and diary | T13 | input sources, `docs/` | 38 files, +1399 −74 | **high** |

Dispatch strictly in number order. T08 must not ship without T09 and T10, because the picker would offer a choice the
machine cannot yet honour. T12 was written on T05's tip and re-applied after T11; its text is gated in the final order.

## Owner decisions (each card implements the default)

1. **Root-only layout; the nested package is removed.** A path dependency from the nested package on the root fails in any
   checkout not named `VMRunner` (measured; every agent worktree is one) and forces `public`. The brief asked for the nested
   runner package to keep building; this is the deviation. Alternative: keep the nested package with `.package(path: "../..")`.
2. **Library names `VirtioGPU` and `VirtioInput`, `package` access.** Alternative: `public`, only with the nested package.
3. **Display limits in the app.** Sides 1..8192 within one 64 MiB resource: 4K and 5K work, 8K is refused, and a resize to a
   larger window is refused rather than fitted. Alternative: fit the picture to the limit.
4. **Notification turn budget of 32 elements.** Alternative: another budget, or none.
5. **Resize writes the display event cleared, then set.** The second resize is untested. Alternative: set only.
6. **Isolation levels.** Contained keeps the custom GPU; Isolated and Hardened force Apple's device; the exposure rating is
   medium. Alternative: allow it in Isolated.
7. **Input: both paths built, developer default `framework`.** `CustomGPUInput` is `framework` or `virtio`, read once per
   start; `virtio` drops the USB keyboard and pointer. The run decides which path stays. Alternative: choose one now.
8. **"Custom (experimental)" in the picker.** Alternative: a plainer name once the run has passed.
9. **Outside names.** Debian is named in docs and in T01's commit message, and the guest kernel's driver file path
   `drivers/virtio/virtio_input.c` in two code comments. The verifier flagged them under "no outside project names"; the
   orchestrator judged them allowed: Debian is a guest distribution the app already names across its catalog and help, and the
   path cites the guest driver, not a third-party project. Alternative: reword them.
10. **T-RUN reads input with a small standard-library Python reader on the guest** instead of `evtest` or `showkey`: no
    apt or network dependency. Alternative: install `evtest` over NAT.

## Risks the reviewer and the owner should weigh

- **No guest has run the app's device.** Everything about the guest's behaviour is the Q run's, on the runner.
- **The static virtio-input configuration is unverified.** The classification by the guest of the two devices rests on a model
  of the driver's probe.
- **`@preconcurrency` delegate conformance traps** if the framework ever calls off the main queue.
- **Per-flush copy cost.** Measured 0.135 ms per 1280x800 flush in a scratch `-O` run; not measured in the app.
- **Forwarded events:** that the framework's view accepts them while it is not first responder is unverified.
- **Command chords on the virtio input path.** A Mac window may not get the key-up of a key pressed while Command is held, and the guest repeats a held key by itself; the surface releases only on focus loss and when a modifier flag clears (its own kind). T-RUN's script now has the owner press Command+U once and say whether the guest keeps printing `u`. If it does, releasing every non-modifier key held when the Command flag clears is the follow-up.
- **The two configuration writes of a resize are not unit-tested.** `GPUConfigSpace.displayChange` is, but no test observes `CustomGPUDevice.announceDisplayChange` write both spaces (it needs the framework's device). Two resizes close together run two tasks that may interleave their writes.
- **Dropped frames can be releases.** When the guest holds no buffer for 128 frames the newest frame is dropped, which can be a key-up; the guest then repeats the key until it is pressed again.
- **GET_DISPLAY_INFO is not logged by the app.** That a resize makes the guest ask again is only inferred from the Q run; a
  follow-up should log it.

## Owner-run list (never dispatched to an agent)

1. T-RUN (authorised). Sub-run A: framework input. Sub-run B: virtio input. Optional C: a baseline with Apple's device.
   Optional D: a desktop session, to see the cursor.
2. The owner types for about two minutes in each sub-run; the agent never types.

## After the chain

Read `realguest-customgpu-report.md`, choose the input path and remove the other. T4 (3D) stays gated.

## What a sonnet pre-dispatch review should read hardest

- **T02**: the move script and the three rewritten layering tests.
- **T03** (`serve`, `transferToHost2D`): a single read per element and the element given back exactly once, via `defer`;
  no partial write; overflow checks.
- **T05** (`GuestMemoryMapping`): the one unsafe read.
- **T09**: the `@preconcurrency` conformance, `makeConfiguration` called off the main actor, and the session's lifetime.
- **T10**: `CustomScreen` pacing (weak presenter, a single timer task, detach and attach order under full screen) and the
  `ScreenPicture` bitmap descriptions.
- **T11**: the clear-then-set event.
- **T12**: the probe model against the real driver (pair symmetry, the accelerometer bit) and the drop logic of
  `InputEventQueue`.
- **T13**: attach and detach identity in `FrameworkInputSurface`.
- **T14**: `VirtioInputEndpoint.forgetHeld` (never give back after reset or stop) and `KeyboardState.modifiersChanged`.
- **T-RUN**: the seed (unindented blocks, quoted heredocs), the cleanup of the literal `/tmp` paths, and that the agent never
  types.

## Next chain

Findings from the post-chain code review that this chain does not fix. Each is a follow-up, not part of chain T.

- **Finding 3 (turn budget counts elements, not cost).** The per-turn budget of 32 elements bounds the number of elements, not the
  bytes or time. A guest can make a turn expensive with a few large transfers. A byte-cost budget, and a direct copy into the
  staged buffer, would bound a hostile transfer's main-queue stall.
- **Findings 8, 10 and 11.** Recorded by number only; their text was not included in the review message that this chain was
  given. Add their text here before scheduling them.

## Next chain (review leftovers, in addition to the turn-cost note above)

- Stale modifier edge in `KeyboardState.modifiersChanged`: if Left Shift is held across a focus loss and regained, then Right Shift is pressed and Left Shift released while Right still holds the flag, a spurious Left Shift press is sent; it self-heals at the next flag clear or focus loss. Track "physically down" separately, or document.
- `ModuleBoundaryTests.theAppDoesNotLinkTheVirtioGPURunnerAndBuildAppDoesNotBuildIt` pins the source text `"--product", Self.productName`, which swift-format could break; parse instead.
- `commands.log` and the pid file are created and then given mode 0600; create them through the same exclusive private-file helper as the PNG.
- `CustomGPUFocusTests`: no test detects a leaked window observer after `detach()`; it needs an observable (a counter in the observer or an injected notification centre).
