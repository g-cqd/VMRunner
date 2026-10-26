# CHECKLIST-E — What the sonnet reviewer verifies before dispatching each chain-E card

Apply `../cards/CHECKLIST.md` items 1 to 10, with base `73bceb0`, plus the items below. Read the card against the tree it
will run on: `main` for E01, and `WT` after the previous card's commit for every later card.

## Anchors and symbols

1. Every quoted anchor line exists exactly once in its file (`grep -nF '<line>' <file>`), with the indentation the card
   shows. For cards after E01, check the anchors the earlier cards create (for example E06 relies on `    var isConstrained = false`
   from E02, E15 on the `clamp` doc comment from E14, E16 on `aControlIsLockedOnlyWhereThePolicyRestricts` from E15).
2. Every `--filter` value names a suite that exists when the command runs (new suites are created by the card itself or an
   earlier one: `NetworkCutoffSettingsTests`, `NetworkCutoffRuleTests`, `NetworkCutoffWatchTests`, `NetworkCutoffIndicatorTests`,
   `HostInfoSharingTests`, `HostInfoShareTests`, `HostFactsTests`, `HostPowerTests`, `HostInfoPublisherTests`, `MACVendorTests`,
   `MACVendorStartTests`, `GuestIdentityTests`, `GuestIdentityStartTests`, `GuestIdentityHelpTests`, `AppSettingTests`,
   `ManagedPreferencesTests`, `ManagedLibraryTests`).
3. Every API the card calls exists with that spelling in the SDK headers (`/Applications/Xcode.app/.../MacOSX.sdk`):
   `VZNetworkDevice.attachment` (settable), `VZVirtualMachine.networkDevices`, `VZNVMExpressControllerDeviceConfiguration(attachment:)`,
   `VZVirtioBlockDeviceConfiguration.validateBlockDeviceIdentifier(_:)` and `.blockDeviceIdentifier`,
   `VZVirtioFileSystemDeviceConfiguration.validateTag(_:)` and `.tag`, `VZSingleDirectoryShare(directory:)`,
   `VZSharedDirectory(url:readOnly:)` / `.url` / `.isReadOnly`, `VZMACAddress.isUnicastAddress` /
   `.isLocallyAdministeredAddress` / `.isUniversallyAdministeredAddress`, IOKit `IOPSCopyPowerSourcesInfo`,
   `IOPSCopyPowerSourcesList`, `IOPSGetPowerSourceDescription`, `IOPSGetProvidingPowerSourceType` and the `kIOPS…` keys,
   `NWPath.isExpensive` / `.isConstrained` / `.usesInterfaceType(_:)`, `ProcessInfo.isLowPowerModeEnabled` / `.thermalState`.

## Compiler settings this package uses (Package.swift `commonSettings`)

4. **MemberImportVisibility:** every file that uses a member of a type from another module imports that module. In
   particular: any file reading `networkPolicy.vpn` or naming `VPNState` / `VPNRequirement` cases imports `NetPolicy`
   (`NetworkSection.swift` gets it in E01, `HostInfoTests.swift` in E06); a file that calls `Log.<category>.error` imports
   `os` (`HostInfoPublisher.swift`); a test that names VZ types imports `Virtualization`.
5. **Strict memory safety:** `unsafe` only on the IOKit expressions of E07; no `String(format:)` anywhere (tests included).
6. **Warnings are errors:** no unused variable, no `var` that is never mutated, no unreachable code in the new lines.
7. **ExistentialAny:** every protocol used as a type is written `any` (the `Source` / `Paths` typealiases already are).

## Gates the cards must pass

8. **deadwood (production mode):** every new declaration is reachable from production code in the same card. Check each new
   symbol's production caller: E01 `VPNRequirement.label` (NetworkSection), `networkCutoffExposures` (exposures); E02
   `NetworkCutoff`, `HostNetworkPath.systemPaths`, `networkCutoffReason`, `hasNetworkCutoff` (factory); E03 `text`,
   `MachineModel.networkCutoff` (toolbar); E04 `names`, `isEmpty` (exposures); E05 `hostInfoShare`, `freshHostInfoFolder`
   (build); E06 `HostFacts`, `files(for:)`, `current(network:)` (editor preview); E08 `HostInfoPublisher` (factory),
   `HostNetworkPath.Interface.init(_:)` (`systemPaths`); E09 `makeAddress()` (controller, Randomize); E10 `mainDisk`
   (storage); E11 `needsNewMACAddress`, `makeFreshMachineIdentity`, `activeMachineIdentifier`; E12 `id`, `label` (pickers);
   E14 `ManagedPreferences` (library default argument); E15 `isLocked`, `current`, `lockedHelp` (modifier); E16
   `forcedSettings`, `isLocked(_: AppSetting)`. No protocol-extension default that only a test double uses (E03 puts
   `networkCutoff` on `FakeGuest` explicitly for that reason).
9. **SwiftLint:** no line over 140 columns in new code (string literals cannot be wrapped by swift-format: the cards
   pre-wrap them); `type_body_length` of `VMController` (no new counted line in E09, E11, none elsewhere) and of `VMLibrary`
   (E14 adds about 6); no `swiftlint:disable` added.
10. **arcleak:** every `Task` in `NetworkCutoff` and `HostInfoPublisher` captures `self` weakly; the `connect` closure in
    `VZGuestMachine.startNetworkCutoff()` captures `self` weakly.
11. **dolly:** no new block is an exact copy of an existing one. Near clones (the `systemPaths` mapping beside
    `VPNMonitor.systemSource`, the test scaffolding beside `SerialConsoleTests`) are advisory.
12. **docs:** E17's roadmap files keep valid front matter (`status` one of `pending`, `in-progress`, `done`; `blocked-by`
    list; `decision: ADR-0013` kept on 0013), the H1 `# NNNN — Title` unchanged, and the diary's name and H1 match.

## Content rules

13. Help: each new topic's summary is at most 110 characters and ends with `.` (`killSwitch` 94, `hostInformation` 104,
    `guestIdentity` 102, `managedSettings` 91); titles are unique; `related` never names the topic itself.
14. No outside project is named in prose, docs, comments or help (dependency URLs excepted). Names follow ADR-0042: no
    planning words, no `Manager`/`Helper`/`Util`/`Kit` suffix in new names.
15. The switch pattern is complete where the card claims it: field with tolerant decode (a legacy JSON test), profile
    behaviour (E04 Isolated/Hardened clear; E01 and E09 to E12 deliberately outside the profiles), posture (E04),
    exposure (E01, E04), editor control with `.settingHelp`, help entry, tests.
16. Nothing in a card asks haiku to choose: each step names the file, the anchor and the exact text. The only computed
    value is E17's diary file name, from `date` and `ls`.
17. No card starts a virtual machine or needs the network; the owner runs R1 to R7 in INDEX-E are not dispatched.
18. Commit messages: one imperative sentence in the repository's style; model haiku, effort `low`.

## After review

Mark each card READY or HOLD with the reason. A card that fails item 1 because an earlier card of the chain changed its
anchor is re-anchored by the orchestrator, not by the executor.
