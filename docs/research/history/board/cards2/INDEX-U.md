# INDEX-U — Chain U: Windows on ARM in the app (supersedes ADR-0010), the private-interface module, and the macOS display answers

Base: written on `main` at `fdebe0c`, then re-based onto `main` at `8fdeccf` (5 more commits: the container activity and output file, the control service's `log` capability with its MCP tool and `vmr control log`, a control-listener descriptor test, a diary entry, ADR-0056 and ADR-0057 updates, README and CONTRIBUTING lines). Every card was re-applied in order from its text and gated 8/8 on a scratch clone of `8fdeccf`; final chain tip tree
`ba8e93cb19c0c40c8c50345c5bd517cf8d9e1a4b` (11 commits, 105 files changed, 4134 insertions, 193 deletions). Test counts at the tip:
VMRunnerTests 1334 in 206 suites; ControlProtocolTests 86 in 14, AgentBridgeTests 22 in 2, DevToolsTests 308 in 38, PrivateInterfacesTests 20 in 4 (the other bundles: see the cards' test steps). Two more full `swift test --skip-build` runs on the tip passed (1334 tests in 206 suites each), with no variable-store error. Files: this index, U01.md to U11.md (one card
each, one commit each), and W-RUN.md (the authorised real-guest run, after the chain is merged).

Per-card trees on `8fdeccf` (`git rev-parse HEAD^{tree}` after each card's commit; the scratch clone's commit ids are not the owner's), with the card's shortstat and the whole `VMRunnerTests` bundle's count at that card:

| Card | Tree | Shortstat | VMRunnerTests |
|---|---|---|---|
| U01 | `3171b91e0f7090d8f10b90b8b7a33a096f27297e` | 5 files, +125 −6 | 1240 in 198 |
| U02 | `ca3b0c1ec74abfd8ac239e154abcdcc30bde640f` | 16 files, +644 −4 | 1240 in 198 |
| U03 | `f07284e22e0a1798b15ab242dd96ce4598d1f2f7` | 11 files, +266 −5 | 1248 in 199 |
| U04 | `554407916f66bc775a9c27a875c0cc4d1b0e3c2a` | 21 files, +408 −33 | 1272 in 201 |
| U05 | `ca2eb4a3b8ab142a71d255955cc328f985de7bc5` | 19 files, +630 −74 | 1293 in 203 |
| U06 | `ef779e115c077ec1e508d4f14147d76038d316c2` | 9 files, +530 −18 | 1309 in 204 |
| U07 | `3005287ff68c42399fa46050e47b637940e793f6` | 25 files, +398 −54 | 1325 in 205 |
| U08 | `ac0e6a5fd9cc8c4f87e26e4bb951e179eb132482` | 8 files, +333 | 1325 in 205 |
| U09 | `fd4fb91bed652d9ac2de7f37e82f18886869250c` | 1 file, +124 | 1325 in 205 |
| U10 | `c89b60c4c4835c90ea1ef492ab497e3bebe412d3` | 2 files, +74 | 1325 in 205 |
| U11 | `ba8e93cb19c0c40c8c50345c5bd517cf8d9e1a4b` | 25 files, +652 −49 | 1334 in 206 |

Only U11's shortstat differs from the one it had on `fdebe0c` (−49 where it was −40); no other card's shortstat or tree-shape changed, and every `old` text of U01 to U10 matched once on `8fdeccf` unchanged. U11 needed re-anchoring (below).

What the re-base changed in the cards: U01 to U09 only the base statement, the docs-file count (124) and the expected test counts; U10 takes the diary number `05` (`2026-10-25-04.md` is a different entry on `8fdeccf`); U11 was merged with the `log` capability: `screen` is appended after `log` in the capability enum, the method enum and the tool list (six tools), the README, help, MCP instructions and `vmr control mcp` texts say six tools or both capabilities, the conformers `FakeMachines`, `MemoryMachines`, `StaticMachines`, `TwoMachines` and `LibraryControlMachines` have both `log` and `screenshot`, `LibraryControlMachines` uses the `closedMessage` constant of the `log` method, and the ADR-0056 paragraph follows the `log` paragraph. U04's audit was re-run: the same search gives the same 74 lines on `8fdeccf` as on `fdebe0c`, so no `GuestOS` site is new and the table is unchanged. W-RUN: its Base note and the three facts that list control methods or log categories (F4, F28, F29).

Independent replay: on `8fdeccf` a verifier applied U01 to U11 from their text alone with its own applier to a fresh clone: every `old` matched exactly once, every card's tree and shortstat equalled the table above, and `swift run vmr check` was 8/8 PASS at U05, U07 and U11; two more full test runs on the tip passed with no variable-store error. (An earlier verifier did the same on `fdebe0c` before the re-base, with a gate at every card.)

Why the per-card shortstats do not sum to the chain total: later cards rewrite lines earlier cards added.

## What the chain builds

ADR-0010 said Windows guests are not supported. The owner decided to support Windows on ARM as an experimental guest. It needs
one switch the virtualization framework does not document (performance-monitoring emulation on the generic platform
configuration), so the chain first records the decision (ADR 0059, which supersedes ADR-0010) and builds a typed, fail-closed
module that is the only place the app calls a private interface (ADR-0019). It then adds a policy for that module (closed by the
Isolated and Hardened profiles, switchable off by an organisation or a developer, listed in the exposure summary), makes Windows a
guest of its own (with an audit of every place that told guests apart by "macOS or else Linux"), builds the machine (generic
platform, EFI, NVMe, USB input and media, the emulation or a typed start error), and gives it a New Machine preset, editor rows,
help and a driver-disc check command. Three cards are not Windows work: a design-only note on a boot display, a diary entry with
two research findings about macOS guests, and a control-service "screen" capability for machines on the custom GPU. The chain adds
no download, no network code, no answer file and no way around Windows Setup's checks (see the hard scope limit below).

| Card | Scope | Size | Risk |
|---|---|---|---|
| U01 | ADR 0059 superseding ADR-0010; dated update in ADR-0019; roadmaps 0015 and 0029 (docs only) | 295 lines; 5 files, +125 −6 | low |
| U02 | `PrivateInterfaces` target, capability registry, PMU capability, contract test | 1009 lines; 16 files, +644 −4 | **high**: the only code that calls a method found through the Objective-C runtime |
| U03 | Policy: Isolated and Hardened force it off, managed key `AllowPrivateInterfaces`, kill switch `DisablePrivateInterfaces`, exposure line, help topic | 540 lines; 11 files, +266 −5 | medium |
| U04 | `GuestOS.windows`, decode, defaults, validation, audit of 56 guest-distinguishing sites | 1115 lines; 21 files, +408 −33 | medium: wide, and a missed site silently treats Windows as Linux |
| U05 | `configureWindows` in an extension file, a generic-platform extension shared with Linux, Provisioner ISO-install path, driver disc field and approval, PMU applied or a start error, developer default `WindowsStartsWithoutPMU`, real EFI variable stores in test fixtures | 1394 lines; 19 files, +630 −74 | **high**: moves Linux code; changes the start path |
| U06 | New Machine Windows preset with installer ISO and optional SHA-256, read-only driver disc, requirements panel | 1010 lines; 9 files, +530 −18 | medium |
| U07 | Editor rows per guest (`GuestEditorRows`), Windows help topic, help rewrites, Secure Boot exposure for the generic platform, roadmaps | 1482 lines; 25 files, +398 −54 | medium: many views |
| U08 | `vmr windows drivers verify` with an empty pinned list in `Resources/WindowsDriverPins.json` | 427 lines; 8 files, +333 | low |
| U09 | Design-only note: framebuffer shim through the EFI ROM-image selector (`docs/research`) | 191 lines; 1 file, +124 | low |
| U10 | Diary 2026-10-25-05: macOS custom virtio device refusal (verbatim `validate()` output), frame-capture decision, pixel density finding; owner step 8 in roadmap 0039 | 216 lines; 2 files, +74 | low |
| U11 | Control-service "screen" capability for custom-GPU machines (PNG at most 1280 px and 700 000 bytes, MCP tool, `vmr control screenshot`, ADR-0056 update, tolerant token decoding) | 1873 lines; 25 files, +652 −49 | medium: every control answer's slash escaping changes |
| W-RUN | The authorised first boot of a Windows guest in the app | 822 lines | **owner-authorised only**: starts a real virtual machine |

Sizes are the card file's line count and the diff statistic the card states. The per-card statistics do not sum to the chain
totals above; the totals are those of the whole chain's tree. U08 to U11 do not depend on U04 to U07; they are applied in
number order all the same, so each card's `old` texts are the files the previous cards leave.

## How the cards were checked

- Every card was written and gated 8/8 (`swift run vmr check`: format, swiftlint, docs, workflows, policy, build, test,
  analyzers; the 8 lines read) on scratch clones. U04 was written on `fdebe0c`, then re-anchored after U03. U08, U09 and U10 were
  written on `fdebe0c` and U11 on U03's tip; each was then re-applied from its text after U07 (U11 after U10) and re-gated. All eleven were then re-applied from their text, in order, onto `8fdeccf` and re-gated (see the per-card trees above).
- U05 was amended after a test-order failure with a known root cause. Older tests wrote made-up "nvram" bytes as the EFI variable
  store. Once the framework is asked for the Secure Boot state of such an invalid store, every later variable-store operation in
  the same process fails with "Failed to initialize the variable store. EFI error: 0x8000000000000014". 10 of 15 full runs failed
  before the fix. The fixtures now create real stores; 5 of 5 and then 3 of 3 full runs passed after.
- **Probe facts**, on macOS 27.0.1 (build 26A434), from a throwaway program that lists selectors with the Objective-C runtime
  (nothing called) and then sets and reads back the switch on a fresh configuration (U02 has the program):

```
os: Version 27.0.1 (Build 26A434)
kern.osversion: 26A434
selectors on VZGenericPlatformConfiguration:
  VZGenericPlatformConfiguration _setPerformanceMonitoringUnitEmulationEnabled: -> v20@0:8B16 (args 3)
  VZGenericPlatformConfiguration _performanceMonitoringUnitEmulationEnabled -> B16@0:8 (args 2)
  VZGenericPlatformConfiguration _setFineGrainedTrapsEmulationEnabled: -> v20@0:8B16 (args 3)
  VZGenericPlatformConfiguration _fineGrainTrapsEmulationEnabled -> B16@0:8 (args 2)
  VZGenericPlatformConfiguration _setVirtualizationHostExtensionEnabled: -> v20@0:8B16 (args 3)
  VZGenericPlatformConfiguration _virtualizationHostExtensionEnabled -> B16@0:8 (args 2)
  VZGenericPlatformConfiguration _setGuestType: -> v24@0:8@16 (args 3)
  VZGenericPlatformConfiguration _guestType -> @16@0:8 (args 2)
selectors on VZEFIBootLoader:
  VZEFIBootLoader _setROMImageURL: -> v24@0:8@16 (args 3)
  VZEFIBootLoader _ROMImageURL -> @16@0:8 (args 2)
PMU before set: false
PMU after set(true): true
PMU after set(false): false
```

- `_setROMImageURL:` has the encoding `v24@0:8@16` (U09, U10); nothing was called. On a macOS platform with one custom virtio
  device, `validate()` fails with `VZErrorDomain` code 2, "Custom Virtio devices must be configured with a generic platform."
  (U10 has the full output and what it took to reach that check).
- **No agent started a virtual machine.** The probes read metadata, set one switch on a configuration object, or call `validate()`.

## Numbers: the ADR and the diary are free on `8fdeccf`; confirm at execution time

The chain adds ADR 0059 (U01) and diary entry 2026-10-25-05 (U10). The cards write the concrete numbers, with no placeholder.

- **ADR (U01).** `ls docs/adr | tail -n 3` must show a highest four-digit prefix of `0058` and no file starting `0059-`. If the
  free number differs, the executor replaces `0059` by the free number in every file name, text and commit message of U01 and of
  the cards after it, and says so in the report. Later cards find the ADR with
  `ls docs/adr | grep -- '-windows-on-arm-is-supported-with-its-one-private-interface'`.
- **Diary (U10).** `ls docs/diary | grep '^2026-10-25-' | tail -n 1` gives the last entry of the day (on `8fdeccf`,
  `2026-10-25-04.md`; on `fdebe0c` it was `-03`); the new entry is that number plus one, or the day's `-01` if the date differs. If it is not `05`, the
  executor replaces `2026-10-25-05` and the heading's `(5)` in the file and the commit, and says so in the report.

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/u-windows -b chain/u-windows main
```
`WT = ~/Developer/g-cqd/VMRunner-chains/u-windows`, branch `chain/u-windows`. One chain, cards strictly in
order, one build at a time (the gate takes 3 to 10 minutes). haiku (effort low) executes each card; sonnet (effort medium)
reviews every card before dispatch and the chain before merge.

## Rules for chain U (they override COMMON where they differ)

The rules are stated at the top of every card; in full:

- **No outside project named** in code, docs, comments or commit messages: say "the virtualization framework". "Windows" is fine
  as the guest OS name. No names of other VM apps or tools. **No board or card id** (`U01` and so on) anywhere in the
  repository. **No planning or stage word** in an identifier, file, target or flag (ADR-0042).
- **One atomic signed commit (`-S`) per card**, made only after `swift run vmr check` printed 8 `PASS` lines and the 8 lines were
  READ (format, swiftlint, docs, workflows, policy, build, test, analyzers), not inferred from an exit status. No push, amend
  or rebase. If signing cannot work non-interactively in a scratch clone, commit unsigned there and say so.
- **Swift 6.4 strict memory safety:** `unsafe` on each unsafe expression; Objective-C runtime code fails closed. Warnings are
  errors. SwiftLint strict: `type_body_length` 300, `function_body_length` 60, `cyclomatic_complexity` 12, lines under 140
  columns; a false positive only through a line-level `// swiftlint:disable:this <rule>`. Swift Testing only (TestKit
  `AsyncGate`, `AsyncEventProbe` and `TestClock`; no real sleeps; no `nonisolated(unsafe)`). `package` access, never `public`
  (ADR-0047).
- **Agents executing cards never start a virtual machine.** Calling `validate()` on a configuration is not starting one, but only
  the cards that say so do it.
- **A test that fails: STOP and report;** never edit a test to pass. **A compile or lint error in the card's own code:** fix it
  minimally without changing behaviour or what a test checks, and list each fix with the compiler line.
- **Disk space.** Check `df -h /tmp` before a build; stop and report if under 25 GiB is free. If a build or test stops on "No
  space left on device", free space and rerun; that is not the card's failure.
- **Two known flaky tests.** The network stack's `pingToLoopbackThroughTheStack` needs a host that answers loopback ICMP and can
  fail once under load. TestKitTests "atLeast resumes when a later sleeper reaches the target"
  (`TestClockRendezvousTests.swift:46`) exceeded its 60 s limit once under load. For either, rerun the gate once and report both
  results; a second failure is a stop.
- **Shell:** fish is the login shell; wrap commands in `/bin/bash --noprofile --norc -c '...'`; absolute paths.
- **HARD SCOPE LIMIT (owner decision, non-negotiable).** Nothing in any card, code, doc, help text or comment may implement,
  generate, describe or point to a way of bypassing or disabling Windows Setup's hardware-requirement checks (TPM, Secure Boot,
  RAM, CPU), including registry keys, answer files, unattended-setup files or preinstall-environment scripts. No answer-file
  generation at all in this chain. The app provides the machine, the media slots, honest requirements text and verification
  helpers only. The fixed requirements wording is: "Windows 11 Setup checks for a TPM 2.0 device. This machine has none: the app
  does not provide one and does not work around the check. Meeting Windows Setup's requirements and the licence terms is up to
  you." No downloads in app code; no networking added.
- **Never touch** (COMMON): `Package.swift`, `Package.resolved`, `Sources/VMRunner/Network`, `Sources/VMRunner/Policy`,
  `Sources/NetPolicy`, `Sources/NetStack`, `Sources/TestKit`, `Tests/TestKitTests`, `Sources/VMHelper*`, `Sources/DevTools/Guest*`,
  `Sources/GuestConsole`, `Sources/VMRunner/Model/Security.swift` and the console fields of `VMConfig`, analyzer baselines,
  `.vmr.json`, `.swiftlint.yml`. **The chain's exceptions, each stated in the card that uses it:**
  - `Package.swift`: U02 (the new target, its tests, the app's dependency) and U03 (the app's tests link the module).
  - `.vmr.json`: U02 (the new test bundle in the coverage list).
  - `Sources/VMRunner/Model/Security.swift`: U03 (one line in `exposures`), U04 (one line, the guest-dependent audit), U05
    (posture and exposure for the driver disc and nested virtualization), U07 (the audit of its guest comparisons; the Secure Boot
    exposure) and U11 (the agent-access exposure text).
  - U01, U06, U08, U09 and U10 touch none of these. Nothing else on the list is edited by any card.
- **How to read a fenced block:** its text is its lines joined by newlines; an empty last line inside the fence stands for the newline that ends the text (it does not add a blank line). Copy an `old` text exactly; if it matches zero times only because of a trailing blank line, match it without that line and say so in the report (this is the one case where U11's `Tests/ControlProtocolTests/FakeMachines.swift` edit 1 matters).

## Order and dependencies

Dispatch strictly in number order, U01 to U11. U02 needs U01 (the ADR it cites); U03 needs U02; U04 to U07 need the card before
them (U05 uses U02 and U03 through the builder, U06 and U07 use the names U04 and U05 fix). U08 to U10 depend on no Windows
code. U11 is independent of U04 to U10 and was written on U03's tip; it was re-based onto the `log` capability of `8fdeccf`. W-RUN runs only after the chain is merged.

## The interface between the cards (names are fixed; a change is reported, not made)

- **U02, module `PrivateInterfaces`** (all `package`): `PrivateCapabilityID` (`performanceMonitoringEmulation`, `title`),
  `PrivateCapabilityStatus` (`available`, `unavailable(PrivateCapabilityReason)`, `isAvailable`), `PrivateCapabilityReason`
  (`killSwitch`, `notRegistered`, `osBuildUnreadable`, `osBuildOutsideRange`, `classMissing`, `receiverMismatch`,
  `selectorMissing`, `encodingMismatch`, `readBackMismatch`; `description` is the words a start error shows),
  `PrivateCapabilityContext` (`osBuild`, `killed`, `resolver`, `.current(killed:)`), `PMUEmulation.status(in:registry:)` and
  `PMUEmulation.apply(to:in:registry:)`, `CapabilityEntry`, `CapabilityRegistry.standard`, `OSBuild`, `MethodContract`,
  `MethodLookup`, `MethodResolver`, `RuntimeMethodResolver`. Registered builds `26A0` to `26Z99999`.
- **U03, in `Model/PrivateCapabilityPolicy.swift`:** `PrivateCapabilityPolicy.decide(posture:managed:killSwitch:)` returning
  `Decision` (`allowed` or `denied(Reason)`; reasons `managedKey`, `profile(SecurityProfile)`, `killSwitch`, in that order of
  precedence), `closingProfiles` (`[.isolated, .hardened]`), `exposure(for:)`, managed key `AllowPrivateInterfaces`,
  `PrivateInterfacesKillSwitch.defaultsKey` (`DisablePrivateInterfaces`) and `isOn(in:)`, and `VMConfig.privateCapabilities`.
- **U04:** `GuestOS.windows` (raw value `windows`), `GuestOS.newMachineChoices` (`[.macOS, .linux]` until U06 adds `.windows`),
  `GuestOS.usesGenericPlatform`, `VMConfig.new(name:guest:hostCPUs:hostMemoryGiB:)`, `EditorLimits.newWindowsDiskGiB` (`64...2048`)
  and `EditorLimits.newDiskGiB(for:)`, `VMConfig.usesNVMeMainDisk`, `VMConfig.guestSuspendReason` (non-nil for Windows),
  `VMConfig.attachedInstallerPath`, and `validate()` refusals for features a Windows machine cannot use.
- **U05:** `VMConfig.driverDiscPath` and `attachedDriverDiscPath`, `HostPathGrant.Kind.driverDisc`,
  `SetupError.requiredCapabilityUnavailable(guest:capability:reason:)`, `WindowsStartsWithoutPMU.defaultsKey`
  (`WindowsStartsWithoutPMU`) and `isOn(in:)`, `WindowsStartSettings` (`decision`, `applyPerformanceMonitoring`,
  `startsWithoutPerformanceMonitoring`, `current(for:managed:defaults:context:registry:)`), `ConfigurationBuilder.build(..., windows:)`
  and `assemble(...)`, `genericPlatform(for:bundle:)` and `efiBootLoader(for:bundle:secureBoot:)`, the test helper
  `writeEFIVariableStore(at:)`. `SetupError.unsupportedGuest` is removed.
- **U06:** `NewMachineModel.createAfterVerifying(in:)` (the Create button's path) and `create(in:)` (refuses a Windows machine that
  has a digest), `InstallerDigest` (calls `Checksums.hexDigest`), `WindowsRequirements.lines` (six statements, the fixed TPM
  wording verbatim), and the `validate()` rule that a Windows machine's source is a local file.
- **U07:** `GuestEditorRows` (the rows a guest gets), `WindowsRequirements.sharingNote` and `profileNote(for:)`, the help topic
  `windowsMachines`.
- **U08:** `vmr windows drivers verify FILE [--root DIR]`; exit 0 match, 1 not in the list, 64 usage, 65 list missing or malformed,
  66 file missing or not a regular file; list at `Resources/WindowsDriverPins.json` (schema 1, shipped empty).
- **U11:** capability `screen` (label "Read screen"), method `machines.screenshot`, `ControlMachines.screenshot(_:)`,
  `ControlScreenshot.maximumBytes` (700 000), `ScreenshotPNG`, MCP tool `machines_screenshot`, `vmr control screenshot <machine>
  --output FILE` (`--json` prints the answer; exit 64 for neither or both options, 73 for a write failure).

## Owner decisions (each card implements the default)

1. **App Store eligibility.** The chain uses private interfaces, so the app is distributed with Developer ID only while they are
   in (ADR 0059). Alternative: drop Windows PMU support to stay eligible.
2. **The driver pin list.** `Resources/WindowsDriverPins.json` ships empty; which discs to trust is the owner's decision, made by
   adding entries.
3. **`WindowsStartsWithoutPMU`** exists as a developer-only default in the app's defaults domain, default false. Alternative: no
   such default, so a Windows machine never starts without the emulation.
4. **PMU capability OS-build range.** `26A0` to `26Z99999` (Darwin 26 is macOS 27). The probe ran on build 26A434 only. Default
   as built: a build outside the range is reported unavailable, naming the build. Widen the range only after a probe.
5. **Shared folders and host information for Windows:** shown, with a note that the guest needs a driver of its own. Alternative:
   hidden.
6. **Snapshots kept for Windows** (disk and variables only, no memory); suspend is unavailable.
7. **Windows disk minimum 64 GiB**, default 64 GiB.
8. **Nested virtualization** is allowed for Windows when the host supports it; default off.
9. **Screen capability limits:** longest side 1280 px, PNG at most 700 000 bytes, scaled down in steps. Alternative: other caps.
10. **Display work not in the chain:** a framebuffer-shim spike (design note U09; the spike is the owner's to start) and
    ScreenCaptureKit capture of the framework's view (deferred, reasons in the diary entry).
11. **The real-guest run, W-RUN.** It needs the owner's written authorisation and an exception to CONTRIBUTING's 2 CPU / 2 GiB
    cap: 4 CPUs, 8 GiB and a 64 GiB sparse disk.

## Follow-ups found, not in the chain

- **Possible production issue (unverified in the app).** A damaged `EFIVariables.fd` of one machine, read by `applySecureBoot`
  through `try? store.isSecureBootEnabled`, may make every later variable-store operation in the app's process fail until the app
  is relaunched. Seen in tests only (U05). Candidate fix: check the store before the Secure Boot calls. Also a Feedback report
  with the minimal probe.
- A container with agent access on lists the agent-access exposure, which since U11 also carries the Read screen sentence (conditional on a machine that uses the custom GPU, so it does not apply to a container), next to the container output exposure of the `log` capability.
- `configureLinuxScreen` still has a Linux name, and Windows calls it. Rename it in a later change.
- Roadmap 0005 still says "window capture".
- The Settings sheet gives no warning when "screen" is ticked.
- The installer SHA-256 is checked only at creation; the file can change afterwards.
- `Checksums` reads in 4 MiB chunks (U06 reuses it instead of writing a second loop); U08 hashes in 1 MiB chunks.
- The guard tests list the forbidden words verbatim, which is intended.
- W-RUN's facts were read at an intermediate commit (`7145332`); its Base note says the executor re-locates each by text.

## What a pre-dispatch reviewer should read hardest

- **U02:** the Objective-C runtime code that fails closed (the `unsafeBitCast` of the implementation, the encoding check with
  digits stripped, the read-back, the restore on mismatch) and the OS-build range constant.
- **U03:** the order of the policy's reasons, and the kill switch's meaning (absent or false leaves private interfaces on; any
  other type turns them off).
- **U04:** the audit table against the real grep (is any `GuestOS` site missing?), and how an unknown stored guest value decodes.
- **U05:** the start-error path; the developer default's reading (only an explicit Bool `true` counts); the moved generic-platform
  code, which must not change Linux behaviour; the test-fixture change.
- **U06:** that the SHA-256 gate cannot be skipped and runs off the main actor.
- **U07:** that the hidden rows match what the builder honours.
- **U11:** the widened exposure text, the slash-escaping change in every control answer, and the tolerant token decoding.
- **W-RUN:** the watchdog and time limits, and the hand-made bundle.

## Owner-run list (never dispatched to an agent: it starts a real virtual machine)

`W-RUN.md`, after the merge, by a session the owner has authorised. It writes
`~/Developer/g-cqd/vmrunner-board/realguest-windows-report.md`.
