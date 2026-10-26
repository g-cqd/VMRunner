# REVIEWED-T: independent pre-dispatch review of chain T (the Linux custom GPU in the app)

Reviewer: second pass, adversarial. Method: detached scratch worktrees of the repository (read-only use), the cards applied in order
exactly as written (files and edits extracted mechanically from the cards' code blocks by small scripts, the non-file edits of T01, T02
and T06 by hand), `swift-format`, build and targeted tests per card, `swift run vmr check` after cards T02, T03, T05 to T14 on the
first worktree and again at the final tip on two bases. No virtual machine was started, no window or app opened, no runner started
except the card's own `--dry-run` (T03 step 14, run once, `configuration valid`, `exit=0`, nothing left). T-RUN was only read.
Everything created in `/tmp` and every scratch worktree was removed at the end.

Bases used: `main` at `6bab9e9` (the base named in the brief), and `main` at `c737289`, which appeared while I worked: **the
container chain (S) has merged**, so its ADR (`0057`) and its diary (`2026-10-25-02`) are taken, and its edits to `MachineModel`,
`MachineView`, `GuestMachine`, `Security`, `AppBundler`, `README` and `CONTRIBUTING` are in the tree. I replayed the edited cards on
both. Final result at both tips: `swift run vmr check` **8/8 PASS** (format, swiftlint, docs, workflows, policy, build, test,
analyzers with arcleak, dolly and deadwood), every card's statistics line matched the card's, and every commit of the chain builds
on `c737289` (checked at T02, T05, T09, T10, T11, T13, T14).

## Verdict

| Card | Verdict | One line |
|---|---|---|
| T01 | ready after edits | docs only; ADR number is now chosen at execution time (collision with the container chain's ADR 0057); tree hash cannot match on another base |
| T02 | ready after edits | move script and anchors fine, `build-app --product VMRunner` compatible with the merged container chain; layering tests catch 6 of 6 mutations; hash note only |
| T03 | ready after edits | `serve` and the transfer rewrite survived my hostile corpus; no trap, hang or partial write; mutation checks catch each rule; hash note only |
| T04 | ready after edits | signal path compiled and linted only (as the card says); tests meaningful; hash note only; not gated alone (covered by T05's gate) |
| T05 | ready after edits | one hardening edit of the single unsafe read (`withExtendedLifetime`); numbering and statistics |
| T06 | ready after edits | gated alone 8/8; anchors survive the container chain; hash note only |
| T07 | ready after edits | gated alone 8/8; **anchor broken by the container chain** (it moved the agent-access exposure text): re-anchored |
| T08 | ready after edits | gated alone 8/8; hash note only |
| T09 | ready after edits | **anchor broken by the container chain** (`canStop` moved into `Workload`): re-anchored; `@preconcurrency` and turn budget reasoned through |
| T10 | ready after edits | **conflicts with the container chain** (`Phase.running` was reshaped): redesigned so it does not depend on `Phase`; mutation checks catch pixel formats, replacement and detach |
| T11 | ready after edits | MachineView anchors follow T10's redesign; claim about "tests of the sequence of writes" corrected (nothing observes the writes) |
| T12 | ready | probe model checked against the driver's logic; key map checked entry by entry; queue survived my hostile operations; only numbering/hash prose edits |
| T13 | ready | hash prose only; framework-view forwarding is the unverifiable part |
| T14 | ready after edits | numbering of ADR and diary; 5 of 5 mutations of endpoint, translation, builder and focus loss caught; one design risk (Command chords) added to T-RUN |
| T-RUN | ready after edits | conditions meet CONTRIBUTING except the window capture, which the brief's "no screenshots" forbids: removed; Command-chord probe added |
| INDEX-T | ready after edits | base, numbering, counts and three new risks |

## Card edits: 64 edit operations in 16 files (INDEX-T, T01 to T14 and T-RUN; list below)

Numbered by purpose; "all" means T01 to T14 that carry the text.

1. **ADR number (conflict with the container chain).** `0057` is the container chain's. Every `0057` in T01 to T05, T09 to T12, T14 and
   INDEX-T became the placeholder `NNNN`; each of those cards got a **Numbers** paragraph (what `NNNN` is, how later cards find the
   ADR file, a check on the staged diff and on the commit message that no `NNNN` is left; not a whole-tree grep, because the
   repository's documentation checker has `NNNN` in its own comments). T01 step 4 now says how to choose N
   (`ls docs/adr | tail -n 3`, highest prefix plus one: `0057` on `6bab9e9`, `0058` on `c737289`) and its stop condition was reworded.
   (10 cards + INDEX: 12 operations)
2. **Diary number.** `docs/diary/2026-10-25-02.md` is the container chain's. T14 now uses `2026-10-25-DD.md` and the title `(D)`, with a
   paragraph telling the executor how to pick DD (`ls docs/diary | grep '^2026-10-25-' | tail -n 1`, plus one: `02` before, `03` after
   the container chain) and the file list names the placeholder. (T14: 3 operations)
3. **Tree hashes.** A tree hash holds the whole base, so it could not match on `6bab9e9` or later and every card said "different hash:
   stop". In all 14 cards the header sentence, the Commands step, the "different hash" sentences, the report line and the gate
   evidence line now ask for the `git diff --cached --shortstat` line instead; T12 keeps its 13 per-file `git hash-object` hashes
   (base-independent; they matched exactly on both bases). (14 operations)
4. **Whole-bundle test totals** (908, 937, 947, 975, 985, 999, 1048 tests) are the gated base's. The header of T02 to T05 and T09 to T14
   and T01's step 7 now say so and ask for "nothing fails and the stated increment"; counts for named suites stay exact. (11 operations)
5. **T07** (container chain): the exposure insertion was anchored on the lines `+ "while the control service is on in Settings."))`
   and `}`, which the container chain moved into a property. Now anchored before the line
   `if memoryBalloon { items.append(Exposure(level: .low, text: "Memory balloon device present.")) }`, same place on both bases. (1)
6. **T09** (container chain): item 15 edit 1 anchored on four lines including `var canStop: Bool { get }`, now in `Workload`. Now two
   lines (`virtualMachine`), the insertion keeps its place. (1)
7. **T10 and T11** (container chain): `MachineModel.Phase.running` and the `MachineView` switch were rewritten there, so five anchors
   failed. T10 no longer touches the phase: `MachineModel.customDisplay` (a cast through `Any` so it compiles whether the controller's
   guest is typed as `GuestMachine` or `Workload`), a generic `RunningScreen` view in `MachineView` that takes the framework display
   as a closure and shows `CustomGPUDisplay` when there is a custom source, a one-line anchor on the `VMDisplay(...)` call (the same
   text on both bases), and `MachineScreenTests` rewritten to read `customDisplay` (still two tests). T11's `MachineView` edit
   follows (two edits on text T10 creates). The Why paragraph, judgement call 1 and the statistics of T10 (872/75) and T11 (400/30)
   were updated. (T10: 5 operations, T11: 2)
8. **T05**: `GuestMemoryMapping` ends with `withExtendedLifetime(mapping) { unsafe Array(...) }` so the mapping object is alive while its
   pointer is read (the framework says the mapping object is what holds the host memory); still one `unsafe` expression. Statistics
   462/20. (2) Also INDEX-T statistics for T05, T10, T11. (1)
9. **T11** Risky paragraph: it claimed "the host tests check the sequence of writes"; they check the constant
   (`GPUConfigSpace.displayChange`), not the device writing it. Corrected. (1)
10. **T-RUN**: (a) the gate item, the standing rules and the stop condition allowed one capture of the app's window per sub-run; the brief
    says no screenshots, so X5 now takes no picture (the owner describes the window) and S11/S12 lost their `window.png`/capture
    wording; the `windowid` command of the `ax` tool and its `CoreGraphics` import were removed. (b) The owner's script has the owner
    press Command+U once and say whether the guest keeps printing `u`, and S8 reads the U key's presses, releases and repeats (see
    risk 1 below). (8 operations)
11. **INDEX-T**: base line (now two replayed bases), a **Numbers** section (items 1 to 3), and three new risks (Command chords, the two
    unobserved configuration writes, dropped frames that can be releases). (3 operations)

Nothing in a test was edited except T10's `MachineScreenTests`, which is a test of the card being changed.

## Bugs found in decoder, store or serve

**None.** Evidence:

- `transferToHost2D`: a differential test of the new code against the old per-row algorithm (copied into a scratch test) over 60 000
  random cases (resources 1..12 per side, backings split at random with gaps, shortfalls, an entry at the top of the address space,
  rectangles including `UInt32.max` and 8193 sides, offsets including `UInt64.max` and `1 << 63`): same response in every case
  except nine where the card documents the changed order of two error answers (both were `errInvalidParameter` versus `errUnspec`);
  pixels identical in 7 611 successes; resource unchanged in 52 389 failures (no partial write); no trap. Time: 1 x 16 777 216 full
  column 5 s in debug including building the 64 MiB fake (the transfer itself is milliseconds); 4096 x 4096 in 16 384 pieces 66 ms; the
  worst allowed narrow transfer (4095 x 4096 rows, 16 384 pieces) 74 ms; 8192 rows of a 2 x 8 388 608 resource refused before any read.
  `BackingLayout.pieces` is a binary search, so rows do not multiply the piece count.
- `serve`: read once (header only for an oversized request), answer only when it fits, `giveBack` exactly once on every path, as
  `defer` first; the card's own table of lengths 0 to `1 << 40` on both queues, plus my mutations: removing the `defer` (65 issues),
  removing the row cap (4), reading the whole oversized request (the fake crashed on a `1 << 40` allocation), writing regardless of
  room (1), serving past the budget (5): all caught. `serveTurn` checks the budget before it takes an element, so no element is
  taken without being served.
- `InputEventQueue` and `InputStatus`: 3 000 rounds of random operations with capacities 1 to 256, held limits 1 to 1024, buffers of
  capacity 0 to 64 that fail to write, and frames with no report: a buffer is given back at most once and never written after, the
  held count matches the buffers not given back, what the guest saw is an ordered subsequence of what was sent, no trap; the
  encoder survives 150 000 random `Double` bit patterns; statuses of length `Int.min`, -1, 0..9, `Int.max` are not read and given
  back once.

## Findings and risks (what I did not change, and why)

1. **Command chords on the virtio input path (design risk, not fixed).** AppKit commonly does not deliver the key-up of a key pressed
   while Command is held. `KeyboardState` releases a key on its key-up, on focus loss, or (for a modifier's own kind) when its flag
   clears; the layouts advertise key repeat, so the guest would repeat a chord's key until it is pressed again. T-RUN now probes it
   (Command+U); the follow-up if it shows is to release every non-modifier key held when the Command flag clears. I could not
   confirm AppKit's behaviour without a window.
2. **Dropped frames can be key releases.** With no buffer held by the guest the newest frame is dropped (the library's documented policy)
   and `EV_REP` makes a lost release a repeating key. The cap is 128 frames; the guest posts 64 buffers, so it takes a stalled guest.
3. **`CustomGPUDevice.announceDisplayChange` is unobserved by any test** (it needs a framework device); two resizes close together run two
   tasks whose clear and set writes may interleave. Harmless for the guest (a repeated write), but the "every write differs from the
   one before it" argument then holds only per task.
4. **Stale continuation after a reset.** A resumed turn holds its queue; the header says `nextElement` returns `nil` when the device is
   no longer live, so it should end at once. Not exercised.
5. **`forgetHeld` drops framework elements without returning them.** The card's whole rule rests on the framework tolerating a
   released, unreturned element after a reset or stop; the headers say only that an element should be returned when finished.
   Only a run shows it.
6. **Callback queues.** The configuration delegate's `didCreateDevice` is called on the machine's own queue (the header says "the serial
   queue of the guest's VZVirtualMachine instance"), which is the main queue for a machine made with `VZVirtualMachine(configuration:)`,
   so the `@preconcurrency` main-actor conformance should hold; a machine made on another queue would trap. The device callbacks are on
   the provider's `deviceQueue: .main`.
7. **Re-entrancy.** Everything a sink or observer does inside `serve` (screen, pacing, the resize follower's `guestResponded`) avoids
   `GPUDeviceState`; `requestDisplaySize` is not called from inside a flush. A future observer that did would trap on exclusive access.
8. **T04 test claim.** "The bundle runs in a process of its own" (for `umask(0)`) holds only if SwiftPM runs each test target in its own
   process; the observed output prints one summary per target. If it were one process, a test creating files while `umask(0)` is in force would get wider modes than the default; no test of the repository
   asserts a default mode, so the risk is theoretical.
9. **Unverified by anyone until the run:** the guest's classification of the two static input layouts (I checked the probe model
   against the driver's logic as I know it: size gating of every bitmap, the `EV_REP` bit, the five-word absinfo, the slot count
   `max + 1` as unsigned with the 1024 limit, bits cleared at registration; and I checked all 115 key map entries against
   `kVK_*` and `KEY_*`, and the tablet's bit arithmetic: no discrepancy), the cursor's premultiplied alpha, the pixel formats'
   colours beyond white-on-black (the tests do check every format against the library's channel offsets), the scroll step and sign,
   the framework view accepting forwarded events while not first responder, the second resize.
10. **Minor.** `serve` trusts `readableByteCount >= 0` (an `NSUInteger` converted to `Int` cannot be negative in practice). T-RUN drives
    three buttons of the app through Accessibility (`Start`, `Shut Down`, `Force Stop`), which the rules call "driven", consistent
    with CONTRIBUTING even though the card says "no click".

## Per-card notes

- **T01.** Docs gate passes. Contents consistent with the T02 code (a doc says "the nested package's runner" until T02). "Debian" in
  docs and the commit message is allowed (the app names Debian in its catalog and help already).
- **T02.** Move script: 34 renames, 2 deletes, `Packages` holds `Containers` only, no `public` left in the library or parser; stats
  45 files, +259 -242 on both bases. Layering mutations I applied, all caught: `import Foundation` in the library; the app target linking
  the parser; `--product` removed from `AppBundler`; AppKit imported in the parser; the library depending on `NetPolicy`; the root manifest
  naming `Packages/Containers`. After the container chain: `AppBundler.compile()` anchor unique, the runner build the container chain
  adds is separate and unaffected, `README`/`CONTRIBUTING` anchors found once each, full gate green.
- **T03.** As above. Step 14 (the runner's dry run) works as written.
- **T04.** `PrivateFile` creates with `O_EXCL|O_NOFOLLOW` and mode 0600; the creation-mode test would fail if `create` took any other mode.
  `RunnerMain.stop` is compiled and linted only. SIGTERM before the machine exists is ignored once `ShutdownSignals` is installed at the
  end of `start`; before that the default action applies, as before.
- **T05.** `GuestMemoryMapping` still the only guest-memory `unsafe`; the pattern equals the runner's `MappedGuestMemory`, which read real pixels
  in the earlier run. `docs` and the three availability-guarded tests ran (host macOS 27).
- **T06 to T08.** Each applied and gated alone (the brief's request): T06 8/8, T07 8/8, T08 8/8. Tolerant decode: `"metal3d"`, `""`, `7`, `null`,
  `true`, `["custom"]` read as `apple` with every other key kept.
- **T09.** `serveTurn`: budget of 32 per turn, one scheduled continuation per queue (`resuming`), `[weak self]` in the task. `makeConfiguration`
  is `nonisolated` and touches no state. The session is kept alive by `VZGuestMachine.customDisplay`.
- **T10.** `CustomScreen`: weak presenter, one timer task at most, no timer without a presenter or a kept-back picture, `attach` replaces and a
  late `detach` of a replaced view changes nothing. Mutations caught: wrong byte order of one pixel format (15 issues), premultiplied
  alpha dropped (2), unconditional `detach` (1). Removing the single-timer guard is **not** caught, and need not be: `offer` shows a
  picture whenever the interval since the last shown one has passed, so restarting the timer cannot starve the view.
- **T11.** Observers are notified for every flush (before the draw decision) and pruned lazily; the end of a resize fires on the first picture
  of the asked size. See risk 3.
- **T12.** Library has no `unsafe` and no import; the three layouts' bit arithmetic holds (keyboard word 0 and 1 all ones so `ABS_MT_SLOT`
  max is -1 and no slots are made; tablet range 259..16384 from bits 0, 1, 8 and bit 46; names of 16 and 2 bytes). `deadwood`
  directives are the form ADR-0047 allows.
- **T13.** Attach and detach identity in `FrameworkInputSurface` (weak host, `detach` ignores a view it was moved away from) and its tests
  hold. The framework view sits below the picture view, so the worst case is no input, not a hidden picture.
- **T14.** `VirtioInputEndpoint.forgetHeld` replaces the queue and gives nothing back; mutation "keep the held buffers" caught (5 issues).
  `KeyboardState` mutations caught: release without the held check (13), pointer y not flipped (6), focus loss ignored (2), USB input
  kept on the virtio path (1). Delegate selectors (`WillStop`, `WillPause`, `WillResume`, `WillReset`) match the 27.0 header exactly (a
  misspelling would have compiled silently).
- **Standing rules.** No outside project name in the added repository text (I searched the whole chain diff for the usual guest-userland and
  hypervisor names: none). `Debian` appears only in the docs T01 writes; `drivers/virtio/virtio_input.c` appears in two code comments and
  cites the guest kernel's driver file: allowed, in my judgement, for the reason INDEX-T gives. No card or chain id, no planning word
  (the roadmap title still says "spike", unchanged from `main`, as T01 states). `unsafe` appears ten times as an expression in the chain, each on the
  expression and each for an AppKit `unowned(unsafe)` property, a C call, the one `CGImage`/`CGContext` initialiser with a nil pointer,
  or the guest-memory read. No `DispatchQueue`, no `try!`. Warnings are errors and the only compiler warnings are the old `emptyNote`
  ones. `type_body_length` and the other lint limits pass at every gated tip.

## T-RUN against CONTRIBUTING

Meets: scratch data under `/tmp` through `VMRUNNER_DATA_DIR`, never the owner's library; 2 CPUs and 2048 MiB; hard limits (the machine's 15
minutes, 20 per sub-run by `kill` of the recorded pid, 100 for the card); the owner is the only one who types, clicks, scrolls, resizes and
brings the window to the front; the agent reads the scratch app's windows through Accessibility on one verified pid (the tool refuses any
other pid before asking it anything) and signals only pids it recorded (the console reader's children through `pgrep -P` of a recorded
pid); the cleanup is by literal `/tmp` paths (five `rm -rf`, the worktree, the env file) after printing the variables, with a check that
nothing is left, the override defaults domain deleted and the owner's own domain compared by size and time. Did not meet: the window
capture (removed). Unchanged and worth the owner's eye: the card adds a worktree to the owner's repository (removed and pruned in the
cleanup), writes the one defaults domain `<id>.data-directory-override` (deleted at the end), downloads 286 MiB with a published SHA-512
and no signature (the card says so), and launches the app, which will appear and may take focus (the owner brings the window forward).

## The ten decisions in INDEX-T (my view; the owner decides)

1. Root-only layout: right; I confirmed the build, the gate and the layering tests need nothing else, and the container chain's runner
   build is untouched.
2. `VirtioGPU` and `VirtioInput`, `package` access: right; `public` buys nothing here.
3. Limits 1..8192 within 64 MiB: fine; a resize past 16 777 216 pixels is refused, which the follower reports and retries on the next change.
4. Turn budget 32: fine; bounded by the library's per-element limits (the worst transfer measured under 0.1 s).
5. Clear-then-set: reasonable, unverified, and the one thing no host test can show; see risk 3.
6. Contained keeps the custom GPU, Isolated and Hardened force Apple's, medium exposure: consistent with the other profile fields.
7. Both input paths with the developer default `framework`: right for a comparison; add the Command-chord probe (done) to the run.
8. "Custom (experimental)": keep until the run.
9. Debian and the driver path: allowed; INDEX-T's reasoning stands.
10. Python reader on the guest: good (no apt, no network); it only reads event nodes and grabs nothing.

## What only the real-guest run can confirm

Whether a stock guest binds the GPU and both input devices (the static layouts), what it classifies them as, every key and corner, scroll
direction and step, a key stuck after focus loss and after a Command chord, the first and the second resize, the framework view taking
forwarded events while not first responder, `forgetHeld` after a reset or stop, the cursor image and its alpha (sub-run D), and the cost
per flush in the app.
