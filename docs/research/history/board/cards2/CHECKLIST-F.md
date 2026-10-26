# CHECKLIST-F — What the sonnet reviewer verifies before dispatching each chain-F card

Apply `../cards/CHECKLIST.md` items 1 to 10, with base `a98fd14`, plus the items below. Read each card against the tree it
will run on: `main` for F01, and `WT` after the previous card's commit for every later card.

## Anchors and symbols

1. Every quoted anchor or `old` text exists exactly once in its file (`grep -nF '<line>' <file>`), with the indentation the
   card shows. Cards that rely on an earlier card: F06 states what F04 built; F11 inserts in `HostInfoTests.swift` after F07
   inserted in another suite of it; F12 relies on F01 (0013 "Built") and F08 (0010 "Owed") having written their parts.
2. Every `--filter` value names a suite that exists when the command runs: `ManagedPreferencesTests`, `ManagedLibraryTests`,
   `ResolverWorkersTests`, `ResolverQueueTests`, `UserNetDNSProxyTests`, `UserNetSystemResolverTests`,
   `UserNetDomainPolicyTests`, `UserNetPolicyRuleTests`, `UserNetPolicyChangeTests`, `UserNetDNSQuestionPolicyTests`,
   `UserNetDNSAnswerPolicyTests`, `AddressJudgementTests`, `MachineInstallerTests`, `SharedCacheTests`, `SymbolicLinkTests`,
   `LibraryLoadTests`, `GateLockTests`, `LinuxCatalogContentTests`, `DebianHostPolicyTests`, `DNSWireMutationTests`,
   `PGPKeyExpiryTests`, `UserNetDNSOverTCPTests`, `HostInfoShareTests`, `GuestIdentityStartTests`, `APFSTests`,
   `MachineSuspendTests`, `MachineSuspendImageTests`, `LibraryTests`, `HostInfoPublisherTests`, `NetworkCardCableTests` (new in
   F08), `NetworkCutoffWatchTests`, `NetworkCutoffIndicatorTests`, `NetworkCutoffSettingsTests`, `HelpCatalogTests`,
   `StorageDevicesTests`, `HostInfoSharingTests`, `HostFactsTests`, `SecurityTests`.
3. The test counts the cards state: `ManagedPreferencesTests` 10 after F01; `ResolverWorkersTests` 2 after F02; `GateLockTests`
   5; `DNSWireMutationTests` 2; `PGPKeyExpiryTests` 3; `HostInfoShareTests` 6 after F07; `NetworkCardCableTests` 3.
4. APIs used exist with that spelling: `CFGetTypeID`, `CFBooleanGetTypeID` (CoreFoundation, through Foundation);
   `ContinuousClock.Instant.advanced(by:)`; `Duration.seconds(_:)` with a `TimeInterval`; `TestClock.now.offset`,
   `TestClock.advance(by:)`, `AsyncEventProbe.wait(forAtLeast:)`; `DispatchSemaphore`; `VZNetworkDevice.attachment` (settable,
   nullable); `VZNATNetworkDeviceAttachment()`; `VZVirtualMachine.stop()` (async); `Character.asciiValue`;
   `FileManager.attributesOfItem(atPath:)` (does not follow a final link); `FileManager.destinationOfSymbolicLink(atPath:)`.

## Compiler settings (Package.swift `commonSettings`, Swift 6 mode, strict memory safety on hardened targets)

5. **MemberImportVisibility:** `VZGuestMachine.swift` gains `import os` (F08, for `Log.machine.error`);
   `NetworkCutoff.swift` gains `import Virtualization` (F08); `NetworkCutoffTests.swift` gains `import Virtualization` (F08);
   `ImageStore.swift` already imports `os`; `ResolverWorkersTests.swift` already imports `Foundation` and `TestKit`.
6. **Strict memory safety:** the only `unsafe` in new lines is the `open` of F05's test, written like the lines it replaces;
   no `String(format:)`.
7. **Warnings are errors:** no unused value (F05's `CatalogTests` test keeps `throws` with no `try`: allowed, no warning); no
   `var` never mutated (F08's `var cable` is mutated through `set`).
8. **Concurrency:** no `nonisolated(unsafe)`, `@unchecked Sendable` or `@preconcurrency` added; F10's
   `nonisolated static func serialNumber(typed:)` touches no state.

## Gates

9. **deadwood (production mode):** each new declaration has a production caller in its own card: F01 `runtimeLimit(forced:)`
   (init); F02 `maximumWait`, the new `submit(_:late:)` (the resolver); F03 `derivedBlockLifetime` (`remember`); F04
   `sweepInstallClones(in:)` (`AppDelegate`); F05 `GateLock.release(_:)` (`hold`); F08 `NetworkCard`, `NetworkCardCable`,
   `cutFailedMessage`, `stopBecauseTheCutFailed` (`VZGuestMachine`); F09 `restoresSavedState(of:)` (`VMLibrary.update`); F10
   `serialNumber(typed:)` (the binding).
10. **SwiftLint:** no new line over 140 columns (the orchestrator measured every new code line: the longest is 139, F02's
    `workers` line); `type_body_length` of `VMLibrary` unchanged by F09 (counted lines replaced one for one); no
    `VMController` edit; no `swiftlint:disable` added; `prefer_self_in_static_references` (`Self.` used inside types);
    `empty_count` (no `count == 0` in new tests).
11. **arcleak:** F08's `Task` captures `self` weakly and `machine` by value; F02's `Thread.detachNewThread { [self] in` is
    unchanged code moved with its class.
12. **dolly:** no exact clone in new lines (F07's two tests and F09's four steps are near clones of their neighbours at most).
13. **docs:** F01's ADR-0013 note keeps the front matter (`status: proposed`); F12's diary name and H1 match
    (`# Diary — YYYY-MM-DD (N)`, N without a leading zero), at most 256 lines; roadmap front matter untouched.

## Compile traps found in review

- `#expect(x.submit({...}, late: {...}))` (two closure arguments) and `#expect(cable.set(...))` (a `mutating` call) do not
  compile inside `#expect`: take the result into a `let` first (F02, F08 do).

## Content rules

14. No board or card identifier in the repository (F12 command 1 greps the documents it writes); no outside project named.
15. Names follow ADR-0042 (`NetworkCard`, `NetworkCardCable`, `sweepInstallClones`, `restoresSavedState`: no planning word, no
    `Manager`/`Helper`/`Util`/`Kit`).
16. Each card says why, the exact edits, the test, commands with expected results, stop conditions, what not to touch and a
    commit message with no apostrophe and no double quote. Nothing asks haiku to choose; the only computed values are F12's
    diary path and first line (from `date` and `ls`) and its commit-count check.
17. No card starts a virtual machine or needs the network; O1 to O5 of INDEX-F are owner runs.
18. Model haiku, effort `low` for every card.

## After review

Mark each card READY or HOLD with the reason. A card whose anchor an earlier card of this chain changed is re-anchored by the
orchestrator, not by the executor.
