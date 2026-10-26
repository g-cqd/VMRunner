# INDEX-Q — Chain Q: a host-implemented virtio GPU device on macOS 27, as a feasibility study (roadmap 0014, ADR-0014)

Base: `main` at `a0c87bc` (or later). Files: COMMON.md (in `../cards/`), this index, Q01.md to Q08.md (one card each, one
commit each), and Q-RUN.md (the authorised real-guest run, after the merge). Evidence: `../macos27-sdk-survey.md`
(secondhand: every API name in the cards was re-checked by compiling, see below), `docs/research/gpu-acceleration-2026-10.md`,
ADR-0014, roadmap 0014. Windows guests are out of scope: the board's `gpu-linux-windows-assessment.md` covers them. This
chain is Linux only and 2D only.

## What the chain builds

A runner of its own, `VirtioGPURunner`, in a package of its own (`Packages/VirtioGPU`), never linked or bundled by the app:
it boots one headless Linux guest whose only display is a **custom virtio device the runner implements** (device 16,
virtio-gpu, 2D), answers the guest's control commands from a pure, host-tested library (`VirtioGPURunnerCore`), and shows
the scanout in a window of its own (`--window`) or writes it to `scanout.png` (`--headless-dump`). It exists to answer
whether the macOS 27 custom device API can carry a GPU device at all, and above all **how the guest is notified** (no
header has an interrupt call).

## How the cards were checked (read this before trusting them)

- Every card's text was applied, formatted with `swift-format`, built and gated with `swift run vmr check` (8/8 PASS, the
  lines read) **in order** on a scratch clone of `main` at `a0c87bc`, on a macOS 27.0 host with Xcode's Swift 6.4 and the
  27.0 SDK; the code blocks were generated from those commits (`git show`), so they are byte-identical, except the review edits listed in `REVIEWED-Q.md` (the failure counter and the one-shot probe
  in `GPUDevice` of Q06 and Q07, re-compiled, re-formatted and re-linted after the edit). Q03 to Q05 were
  written in parallel on top of Q01 and then cherry-picked after Q02 unchanged; the chain in card order was gated again at
  Q05 and at each later card. The scratch clone was deleted afterwards.
- Package test runs per card: Q01 3, Q02 10, Q03 25, Q04 40, Q05 54, Q06 58, Q07 63 (the cards' expected lines).
- **Every Virtualization call was compiled against `MacOSX27.0.sdk`** with `-target arm64-apple-macos26.0
  -strict-memory-safety -warnings-as-errors`. The Swift spellings differ from the survey: `customVirtioConfiguration(_:didCreateDevice:)`,
  `device.update(_:completionHandler:)` (not `updateDeviceSpecificConfiguration`), `device.requestReset()`,
  `readBytes(withExactLength:)`, `write(_:)`, `queue(at:)`, `nextElement()`, `returnToQueue()`, `pciClassID`, `pciSubclassID`,
  `mandatoryFeatures.subset1`. Everything else the cards say about the framework's *behaviour* is **not verified: no
  virtual machine was started**.
- Run without a VM: `--describe`, `--help`, and `--dry-run` (configuration validation only). Unsigned, `--dry-run` fails
  with `VZErrorDomain` code 2 (missing virtualization entitlement); signed ad hoc with the hardened runtime and only that
  entitlement, it prints `configuration valid`: **the framework accepts the custom device configuration** (id 16, class 3
  subclass 0x80, 2 queues, VERSION_1, a 16-byte configuration space, the delegate provider on the main queue). Found on
  the way: `FileHandle.nullDevice` as a serial port's output raises an Objective-C exception; the runner opens `/dev/null`.
- The PNG writer was exercised outside a guest (an 8 × 4 picture, written twice, mode 0600, no partial file left). The
  window was never opened.
- Grepping every header and the framework's `.tbd` for interrupt, irq and msi finds **no interrupt-raising API**; the
  `.tbd` lists private underscored classes (a plug-in bridge, custom MMIO devices), which ADR-0019 forbids and no card uses.

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/q-virtio-gpu -b chain/q-virtio-gpu main
```
`WT = ~/Developer/g-cqd/VMRunner-chains/q-virtio-gpu`, branch `chain/q-virtio-gpu`. One chain, cards
strictly in order, one build at a time. haiku (effort low) executes each card; sonnet (effort medium) reviews every card
before dispatch and the chain before merge; opus merges after the gate on the merged tree.

## Rules for chain Q (they override COMMON where they differ)

- **No outside project named** in code, comments, docs or commit messages (the survey names third-party projects: never
  copy them; "a third-party implementation" if needed). No distribution plans. **No board or card ids** anywhere in the
  repository. **No planning word in an identifier** (ADR-0042: no "spike", "prototype", "poc"); prose may say
  "feasibility study".
- **Every commit atomic, signed (`-S`), builds, and `swift run vmr check` is 8/8 PASS before it, the 8 lines READ.** No
  push, amend or rebase.
- Swift 6.4 strict memory safety (`unsafe` on the expression; guest memory is read through one bounds-checked `unsafe`
  copy in Q06's `MappedGuestMemory` only; Core has no `unsafe`); warnings are errors; SwiftLint strict (`type_body_length`
  300, `function_body_length` 60, `cyclomatic_complexity` 12, lines under 140 columns; the text `DispatchQueue` is banned,
  which is why the device queue is `.main`); Swift Testing only; deadwood and dolly as in COMMON (Core's API is `public`, as
  the container runner's core is, so the dead-code gate roots it; no `@dw` directive in this chain).
- **Every use of a macOS 27 API sits behind `#available(macOS 27.0, *)` / `@available(macOS 27.0, *)`**, and the package
  builds on the macOS 26 deployment floor (`platforms: [.macOS(.v26)]`).
- **Agents never start a virtual machine** (`VZVirtualMachine.start` is never called by an executor), never open the
  runner's window, and never run the runner except `--help`, `--describe` and, where a card says so, `--dry-run` against
  a scratch file under `/tmp`. Real runs are Q-RUN's, authorised by the owner.
- **Compile errors in a card's code:** fix minimally without changing behaviour or a test's expectation, and list every
  fix with the compiler line. **A test that fails: STOP and report**; never edit a test, a limit or a baseline to get green.
- Shell: fish is the login shell; wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.

**Exceptions to COMMON's never-touch list (only the lines the cards name):** Q01 adds the package to **`.vmr.json`**
(`packages`, `lintPaths`) and to **`.swiftlint.yml`** (`included`, next to the container package's lines), and extends
`Tests/DevToolsTests/ModuleBoundaryTests.swift`. Nothing else outside `Packages/VirtioGPU` changes, except Q08's three
docs files. `Package.swift` and `Package.resolved` of the root are **not** touched (a test checks the root never names the
package).

## Order, dependencies and files

| Card | What | Needs | Files (all under `Packages/VirtioGPU` unless named) | Size | Risk |
|---|---|---|---|---|---|
| Q01 | The package (manifest, empty `Package.resolved`, `GPUWire`, `GPUConfigSpace`, `main.swift` with `--describe`) and the layering tests (root never names it, no root source imports it, Core imports no UI or Virtualization framework, no package dependency) | — | `Package.swift`, `Package.resolved`, `GPUWire.swift`, `main.swift`, `GPUWireTests.swift`; `.vmr.json`, `.swiftlint.yml`, `Tests/DevToolsTests/ModuleBoundaryTests.swift` | ~190 | low |
| Q02 | `RunnerArguments` and `MachineBuilder`: EFI, the disk plus a read-only seed disk, entropy, console to a file, no network, one custom virtio device; `GPUDevice` as a lifecycle logger; `RunnerMain` with the time limit and `--dry-run` | Q01 | `RunnerArguments.swift`, `Output.swift`, `GPUDevice.swift`, `MachineBuilder.swift`, `RunnerMain.swift`, `main.swift`, tests | ~420 | **high** |
| Q03 | Request decoder and answer encoder (all 2D commands, cursor, fence echo), every guest length, count and offset bounded; table and seeded random tests | Q01 | `GPULimits.swift`, `ByteReader.swift`, `GPUWireTypes.swift`, `GPURequest.swift`, `GPUResponse.swift`, tests | ~680 | **high** |
| Q04 | Resource store under limits, backing layout over guest memory, transfers into host pixels that never write partially | Q03 | `GuestMemory.swift`, `ResourceStore.swift`, tests (`GPUTestSupport.swift` replaced) | ~640 | **high** |
| Q05 | Device state: one `handle` entry point, scanout and cursor, `ScanoutUpdate` on flush; bounded `CommandLog` with a summary | Q04 | `CommandLog.swift`, `GPUDeviceState.swift`, tests | ~480 | medium |
| Q06 | Device wiring: one copy per request (`readBytes(withExactLength: min(available, limit))`), the answer only when it fits, `returnToQueue()` once; guest memory through `guestMemoryMapping` with a copy; `--probe-config-change N`; the notification timings; `commands.log` at the end | Q02, Q05 | `CommandRecorder.swift`, `RunnerArguments.swift`, `MappedGuestMemory.swift`, `GPUDevice.swift`, `RunnerMain.swift`, tests | ~330 | **high** |
| Q07 | The scanout: `--headless-dump` writes `scanout.png` at most once a second and at the end; `--window` shows it in a window of the runner's own; pixel conversion of the 8 formats with tests | Q06 | 5 new, 5 replaced (listed in the card) | ~330 | **high** |
| Q08 | Docs: roadmap 0014 "Built so far (2026-10-24)" and "Remaining", ADR-0014 dated note (status unchanged), diary entry; no help topic | Q01-Q07 | `docs/roadmap/0014-gpu-acceleration.md`, `docs/adr/0014-…md`, `docs/diary/2026-10-24-02.md` (new) | ~120 doc | low |

Dispatch order: Q01 → Q08 in number order. Q03 needs only Q01 and touches no file Q02 touches, so it could be dispatched
before Q02, but then the package's test counts in Q03 to Q05 are 7 lower than the cards say (the 7 of Q02's
`RunnerArgumentsTests`) and Q06 must follow Q02 in any case: dispatch in number order unless the reviewer takes that on.

## Owner decisions (each card implements the default)

1. **Name and place.** `Packages/VirtioGPU` (package "VirtioGPU"), targets `VirtioGPURunnerCore`, `VirtioGPURunnerTests`,
   `VirtioGPURunner`, not `GPUSpike`: ADR-0042 forbids planning words in identifiers, and the container runner already
   set the pattern of a package of its own (no root target, so `vmr build-app` cannot bundle it, and a test says so).
   Alternative: a target in the root package, excluded by test.
2. **One queue for everything.** The device queue is the main queue: the framework, the delegate, the time limit and the
   window all run there (`MainActor.assumeIsolated` in the delegate), and the banned `DispatchQueue` text is avoided.
   Alternative: a dedicated serial queue with a line-level lint exception, if the run shows the main queue is a bottleneck.
3. **2D only.** Mandatory features: VIRTIO_F_VERSION_1 only; no VIRGL, EDID, RESOURCE_BLOB or CONTEXT_INIT; no shared
   memory region; `supportsSaveRestore = false`. PCI class 3, subclass 0x80 (display, other; no VGA). GET_EDID is parsed
   and answered ERR_UNSPEC; unknown or short requests ERR_UNSPEC, bad values ERR_INVALID_PARAMETER, limits
   ERR_OUT_OF_MEMORY. Alternative: offer EDID (needs a generated EDID block).
4. **Limits.** 256 resources, 64 MiB per resource, 256 MiB in all, 16 384 backing entries per resource (so a request is at
   most 32 + 16 × 16 384 bytes), one scanout of **1280 × 800**. Alternative: 1920 × 1080, to measure the 1080p case the
   survey asks for (the per-resource limit already allows it).
5. **No network in the guest.** It needs nothing from a network. Risk: the guest's network-online wait may delay
   cloud-init by up to about 2 minutes (Q-RUN's timings allow it). Alternative: NAT.
6. **Signing by hand.** No repository tool signs this runner (no `Resources/*.entitlements`, no DevTools change): Q-RUN
   signs the built binary ad hoc with the hardened runtime and a scratch entitlements file granting only
   `com.apple.security.virtualization`. Alternative: a signing command like the container runner's.
7. **The `.vmr.json` and `.swiftlint.yml` exception** above (two lines each, Q01 only), so the gate builds, tests, lints and
   analyzes the package. Alternative: leave the package out of the gate (then nothing checks it; not recommended).
8. **Scratch-directory checks compare names only** (absolute, no `.` or `..`, not `/`, the home folder or `~/Library`), not
   resolved links, unlike `vmr guest`'s check. An existing directory is reused. Reviewed with `--dry-run` (writes nothing):
   a link to the home folder or to `~/Library`, `~/library/x` and `~/LIBRARY` (the volume is case-insensitive) and `/private/etc/x` are
   all accepted; nothing confines the directory to `/tmp`. The owner's runs pass a fresh `/tmp` path (Q-RUN checks it). Alternative:
   share `vmr guest`'s check (it lives in DevTools, which the package cannot link).
9. **Dates.** Q08 dates its texts 2026-10-24 (the day the chain was written) and takes the diary file `2026-10-24-02.md`,
   or the next free number of that day. Alternative: the day the card is executed.
10. **No help topic**, no app change: nothing is user-visible. ADR-0014 keeps `status: accepted`, with a dated note.

## Risks the reviewer and the owner should weigh

- **macOS 27 only.** The device exists only behind `#available(macOS 27.0, *)`; on a 26 host the runner exits 69. CI runs
  on whatever host the lanes have; the package must still compile on the 26 floor (it does, against the 27 SDK).
- **No interrupt API.** If `returnToQueue()` does not notify the guest, the guest's driver waits about 5 s for its first
  display info and then stalls when its ring fills: the device is then unusable, whatever the decoder's quality. Q06 logs
  the timings and Q-RUN reads the guest's `/proc/interrupts`; `update(_:completionHandler:)` is the only other host-to-guest
  signal and is probed by `--probe-config-change`. No guest write to the configuration space reaches the host (no callback),
  so `events_clear` is never seen.
- **Guest memory is untrusted and mapped live.** One copy per request and one bounds-checked copy per backing piece;
  anything else is TOCTOU.
- **SIGTERM skips the report files** (no signal handler): Q-RUN ends runs by the runner's own limit or a guest power-off.
- **Runtime facts not verified:** that the guest enumerates the device, binds `virtio_gpu`, and what 27.0.x does that the
  third-party reports (27.2, a newer Mac, a patched guest kernel) did not need.

## Owner-run list (never dispatched to an agent)

1. After the merge, on a macOS 27 host: build `VirtioGPURunner` in release, sign it ad hoc as Q-RUN step 2 does, then run
   `--describe` and `--dry-run` with a scratch sparse file as the disk (`configuration valid`).
2. Q-RUN itself (authorised agent or owner; headless; the PNG is the evidence).
3. Optional, by the owner's hands only, after Q-RUN: the same run with `--window` instead of `--headless-dump`, to watch
   the scanout live (only the runner's own window; nothing else captured). Note whether the window keeps up with the
   console's scrolling, and the runner's CPU.

## After the chain

Q-RUN, then the owner decides from its report: the diary and roadmap lines for what the run showed, whether the notify
answer allows a usable 2D device, and the next step (resize, comparison with the framework's own graphics device, or
stopping the study). 3D (virgl, Venus) is not in scope of anything here.

## What a sonnet pre-dispatch review should read hardest

- **Q03** (`GPUDecoder.decode`): the order of checks; `attachBacking` bounds `nr_entries` against the limit **and** the bytes
  present before `reserveCapacity`; every length is compared, never subtracted unchecked; trailing bytes ignored only where
  the card says.
- **Q04** (`transferToHost2D`, `BackingLayout.pieces`): the overflow-checked span `offset + (h − 1) × stride + w × 4` and
  the convention that the driver's offset already includes `y × stride + x × 4`; rows read into a temporary before any write
  (no partial write); the binary search and its `Int(...)` conversions; the total-bytes accounting on create and unref.
- **Q06** (`GPUDevice`, `MappedGuestMemory`): exactly one read per element and exactly one `returnToQueue()` on every path
  (including errors and oversize requests); the answer written only when `writeBuffersAvailableByteCount` is large enough;
  the single `unsafe` read bounded by `mapping.length`; nothing logged per command to unbounded output; the
  config-change probe's timer and its log of the next display-info request.
- **Q02 and Q07**: main-actor isolation of the delegate conformances and the time limit; the strong reference to the
  device object (the provider's is weak); the weakly captured picture tick (the leak analyzer caught a strong one); the PNG's
  temporary-then-rename write and the at-most-once-a-second throttle with a final write; `--window` switching to an
  `NSApplication` loop only then.
- **Q05**: whether the random tests reach deep states (they use small values and limits), and the `CommandLog` cap on
  distinct types.
- **Q-RUN**: the cloud-init user-data quoting (single-quoted YAML around `printf` escapes), the 660 s backstop, and that the
  agent reads the PNG as a file and takes no screenshot.
