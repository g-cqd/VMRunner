# REVIEWED-B — sonnet pre-dispatch review of chain B (main at 46bdd5f)

Verdicts: B1 FIXED, B2 PASS, B3 FIXED, B4 FIXED, B5-B9 FIXED and UN-HELD (the network extraction merged).
Apply the patches below to the card files BEFORE dispatching the card. Status of application is tracked in APPLIED-B.txt.

## Blocking
1. B7: `Algorithm` becomes an enum with an associated value, so `rawValue` disappears: `Sources/VMRunner/Engine/ImageStore.swift:22` (`"\($0.algorithm.rawValue):..."`) will not compile. Add that file to B7 with this one edit (cache key stays byte-identical since `name` of `.refused("sha1")` is "sha1"):
   `let claim = checksum.map { "\($0.algorithm.name):\($0.value.lowercased())" } ?? remote.absoluteString`
   The `!= .sha256` guard at line 102 stays. Fix B7's anchor `ImageSourceTests.swift:35` to `:34`. Stored shape today is a bare string ("algorithm":"sha1" pinned at ImageSourceTests.swift:37); a single-value container decodes it and writes "sha256" byte-identically. Add: `ImageSourceCodingTests.writingKeepsTheStoredShape` must pass unchanged. Add step: `grep -rn 'rawValue' Sources/VMRunner/Engine/ImageStore.swift` shows no `algorithm.rawValue`. B7 must-not-touch becomes: `ImageStore.swift` except line 22 (guard at 102 stays); `VMConfig*.swift`; `Security.swift`.
2. B8 step 4: `return token == run ? await prepare(run: token) : nil` will not compile ('await' to the right of a non-assignment operator). Use:
   case .prepare:
       guard token == run else { return nil }
       return await prepare(run: token)
   (the fallBackToColdBoot case keeps: guard token == run else { return nil }; the notice line; launch?.useColdStartDisplay(); letGoOfAttempt(); return await prepare(run: token)).
3. B3 step 4 and B4 step 4 name file names, not suites (vacuous pass). B3 step 4 -> `swift test --filter SharedCacheTests`. B4 step 4 -> `swift test --filter PGPPinnedKeyTests` then `swift test --filter SignedProviderResolveTests`.
4. B4 anchors go stale after B3: anchor by symbol: "the body of `digest(of:algorithm:)` (replace the whole body including the openRegularFile and defer lines)", "the `extension Sequence<UInt8>` with `hexString`", "directly after the test `hexStringPadsEveryByteToTwoDigits`, inside `DownloadMechanicsTests`".

## Suggestions
5. B1: reuse `SplitMix64(seed:)` from Tests/VMRunnerTests/PGPTestSupport.swift:210 (no local SeededGenerator); add a test that pins the reference to 0x21CF02 for "123456789"; command 1 expects 3 tests; stop condition: if `theReferenceGivesTheStandardCheckValue` fails, stop and report the printed value; add PGPTestSupport.swift to must-not-touch.
6. B6 requires B4 landed (the arm currently reads `case .sha1: try streamedDigest(of: url, using: Insecure.SHA1.self)`); locate the bench keys with `grep -n '"checksum.sha1' .vmr-bench.json` (two member openers), delete each member from its opener through its closing `},` (7 lines each; today lines 94-107). Drop "(held, CONFLICT-RISK)" and the dispatch-after-merge sentence.
7. B5 placement: insert `buildInBackground` directly after the closing brace of `memoryRangeMiB` (line 19), blank line, before the doc comment of `Built` (clear of the console branch's hunks; do not move it). Drop "(held, CONFLICT-RISK)".
8. B5 test fixture: `try Data(count: 1 << 20).write(to: bundle.disk)` (not "disk" bytes); stop conditions add "a failing #expect".
9. B9: FakeFactory uses TestKit's AsyncGate (like FakeGuest.hold), replacing the hand-rolled CheckedContinuation:
   /// `held#n` when the n-th preparation starts waiting at the gate `holdPreparation()` set.
   let held = AsyncEventProbe<String>()
   private var preparationGate: AsyncGate?
   /// The next `prepare` waits at the returned gate until the test opens it.
   @discardableResult func holdPreparation() -> AsyncGate { let gate = AsyncGate(); preparationGate = gate; return gate }
   and in `prepare` (async throws), directly after `displays.append(...)`:
   if let gate = preparationGate { preparationGate = nil; held.record("held#\(preparations)"); try await gate.waitUntilOpen() }
   Test: `let gate = rig.factory.holdPreparation()`; `let start = rig.starting()`; `_ = try await rig.factory.held.wait(forAtLeast: 1)`; state #expect stays; `await rig.controller.forceStop()`; `gate.open()` replaces releasePreparation(); `await start.value`; final #expects stay; drop `holdsPreparation`.
10. B9 must reword the doc comment at MachineState.swift:13-14 ("Preparation ... is synchronous, so `preparing` is only ever seen between two events of the same turn") to: "Preparation (the configuration, the network stack, the disposable copy) builds the configuration away from the main actor, so `preparing` can be seen while that runs, and the controller drops the result if the run ended meanwhile." Add `Sources/VMRunner/Model/MachineState.swift` (doc comment only) to B9's files. B9 commands explicit: filters MachineStateTests, MachineStartTests, MachineSuspendTests, MachineStopTests, LaunchStartLibraryTests, ConfigurationBuildTests, StorageDevicesTests, then the gate; stop condition "deadwood flags buildInBackground".
11. B3: read errno once: `if count < 0 { let code = errno; if code == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }` (after `if count == 0 { return }`); replace "using unsafe only where the compiler asks" with "exactly as written: the one `unsafe` is before `read` (same shape as Sources/NetStack/ByteView.swift:57); if the compiler warns, stop and report"; step 6 trigger: a line starting `bench:` containing `improved beyond their tolerance`; `import CryptoKit` goes ABOVE `import Foundation` (swift-format ordering).
12. Re-anchors for B8/B9 (main 46bdd5f): MachineState.swift:339-373 unchanged; VMController.swift sync `perform` 176-204, prepare/fallback arms 178-184, `prepare(run:)` 207-231, `perform(waiting:run:)` 292-311; GuestMachine.swift:45-50 (@MainActor); VZGuestMachine.swift:53-56; ControllerRig.swift: FakeFactory 11-65, prepare 38-53. Drop B8's "A sonnet pre-dispatch re-anchor is mandatory" and the "held, CONFLICT-RISK" titles on B5-B9 and INDEX's held wording.

## Risks a haiku executor could still hit
B3: `unsafe` only on the `read` call; a warning is an error (stop and report). B5/B9: `// @dw:accept` placement untested against deadwood (stop condition is the net). B6 only after B4. B7: `grep -rn '\.sha1\b' Sources Tests` must print nothing; sha256 must still be written as "sha256". B9: building a VZ configuration off the main thread is only provable by the owner starting one real machine.

## Dispatch order
B1 -> B2 -> B3 -> B4 -> B5 -> B6 -> B7 -> B8 -> B9 strictly serial in one worktree. The console branch (agent-addfed63f2ef4ab91, locked) edits ConfigurationBuilder.swift and VZGuestMachine.swift in other hunks; if it merges first, rebase the chain worktree.
