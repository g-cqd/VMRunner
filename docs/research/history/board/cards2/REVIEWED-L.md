# REVIEWED-L — pre-dispatch review of chain L (L01 to L09, L-RUN)

Method: detached scratch worktree at `b51d258`; the nine cards applied in order exactly as written (anchors by text, code
blocks verbatim, `swift-format` as the cards say), `swift build`/`swift test --filter` per card, `swift run vmr check` (8/8)
after the last card. L-RUN only read. Worktree and scratch files removed. The Virtualization.framework question was checked
in the Apple documentation index.

## Verdicts

| Card | Verdict | Edits to the card |
|---|---|---|
| L01 | ready | 0 |
| L02 | ready | 0 |
| L03 | ready after the edits listed | 5 |
| L04 | ready | 0 |
| L05 | ready | 0 |
| L06 | ready | 0 |
| L07 | ready after the edits listed | 1 |
| L08 | ready after the edits listed | 1 |
| L09 | ready after the edits listed | 1 |
| L-RUN | ready after the edits listed (owner-gated) | 6 |
| INDEX-L | edited | 2 |

Total: 16 textual edits in 6 files (L03 5, L07 1, L08 1, L09 1, L-RUN 6, INDEX-L 2). L01, L02, L04, L05, L06 untouched.

## Edits made (each listed)

1. **L03 (defect, gate would have failed).** The new app link makes `Tests/DevToolsTests/DependencyPolicyTests.swift`
   (`theAppTargetDependsOnExactlyThePackagesTheAdrNames`) fail: it pins the app's library targets to
   `ControlProtocol, GuestConsole, NetPolicy, NetStack`. The first gate run of the full chain failed 7/8 on exactly this.
   Added to L03 (four edits): the file in the Files list, a step replacing the set and its doc comment (adds `GuestSeed`),
   the file in the format command, and `DependencyPolicyTests` in the step-5 test filter. After the fix: gate 8/8.
2. **L03 (fifth edit).** The dead-code procedure now states the measured result (no finding; see "Dead code" below).
3. **INDEX-L (2).** The L03 row's Files and the "Never touch" exception now name `DependencyPolicyTests.swift`.
4. **L07 (1).** The advanced help text said "an edited spec takes effect at the next start". A first-boot step that already ran
   does not run again (cloud-init instance id is the machine's), so the sentence now says so (reflowed under 140 columns).
5. **L08 (1).** `ProvisioningSection.recheck()`: `.task(id:)` cancels the old task, but `Task.detached(...).value` still returns, so
   a slow check of an old path could overwrite the result for the new one; and the old result stayed on screen while the new
   one ran. Now `check = nil` first, and `guard !Task.isCancelled` before storing the result.
6. **L09 (1).** The ADR-0012 note said "item 1 is built ... Items 2 and 3 are not built", using the roadmap's new numbering
   while the ADR's earlier note uses the old one (items 2 and 3 are the editor and posture, now built; 4 and 5 remain). Now
   "items 1 to 3 are built ... Items 4 and 5 are not built (the roadmap now numbers them 2 and 3)".
7. **L-RUN (6).** (a) the download: `--proto-redir =https --max-filesize 1073741824` so the 1 GiB limit is enforced by curl, not
   only by the HEAD request; (b) the agent's own 20-minute cap now kills the app by its recorded pid (it only asked before);
   (c) clean-up also signals direct children of recorded pids (listed first); (d) record row 2 asks the owner whether
   suspend is enabled after Start (see risks); (e) a missing `VMRUNNER` line with a booted guest is NOT SEEN, not NO (the
   probes write to `/dev/hvc0`); (f) new stop condition: the app refuses the replaced `Disk.img`.

## Per card: what was checked

- **L01.** All anchors match once. Compiles; `ProvisioningSpecPathTests` and the listed existing suites pass (60 tests).
  The tolerant decode works through `VMConfig.decode`'s overlay; a relative path and a 1025-byte path are refused at decode.
- **L02.** Anchors match. `Posture.provisioning` does not clash with the macOS `VMConfig.provisioning` struct (different
  types). The matrix test checks both the removal and `detectedProfile`, so it can fail (a kept spec that changes the
  posture would break the equality). 54 tests pass; SwiftLint clean (no `function_body_length`/complexity hit on `exposures`).
- **L03.** All nine files had the directive on line 3 and a blank line 4; deletion is 36 lines. Code compiles verbatim.
  Tests pass; the library's tests and `ModuleBoundaryTests` pass; fixture lines 7 and 11 are right.
  - **Dead code.** `swift run vmr check build analyzers` after the link: `deadwood: 0 finding(s)`, exit 0. No
    `referenced-only-by-tests` finding appears (the card guessed `SecretVariable.secretName`/`name`; they are not reported),
    so the accept procedure is never needed here. It still covers the only plausible case (that rule, in `Sources/GuestSeed`,
    at most 8) and stops on anything else. Dolly: PASS; the new tests carry only advisory test-code clone notes (exact-clone
    notes in `ProvisioningSeedTests`), none in production lines.
  - **Start path.** `VZMachineFactory.prepare` is reached from `VMController.prepare(run:)`, whose `catch` turns any error into
    `.startFailed(error.localizedDescription)`; `ProvisioningSeedError` is a `LocalizedError`, so the window shows
    "The provisioning spec machine.yaml can't be used: line 7: ...". The throw happens before the configuration is built, and
    `release()` runs `discardEphemeral()` on the way out, so a failed start leaves no seed.
  - **Seed file.** Written 0400 inside the bundle (test reads the mode); removed by `discardEphemeral()` at stop (release),
    at launch for stopped machines and before a disposable start. `prepareEphemeral` runs before the factory, so a disposable
    machine gets a fresh seed at every start. The seed is rewritten at each retry of `prepare(run:)`, same bytes.
  - **Spec read.** Bounded (`maxSpecBytes + 1` read, then refused), regular files only. Verified by a probe on this macOS:
    `isRegularFileKey` is false for a symbolic link, so a symlinked spec is refused; scripts are refused through links by the
    library. SHA-256 check: a script is packed only if its bytes hash to the digest the spec gives, so a path below the spec's
    folder cannot put an unknown file's content into the seed; the mismatch message shows the file's digest (host side only).
  - A spec path outside approved places: the start asks for approval first (`VMLibrary` `missing(hostGrants)`), see risk 3 for
    the editor.
- **L04.** Anchors match; 42 tests pass. `VZUSBMassStorageDeviceConfiguration` is macOS 13.0+ (floor is 26), added to
  `storageDevices` exactly as the installer already is; a read-only `VZDiskImageStorageDeviceAttachment` of an ISO is the
  same call the installer uses; no extra `validate()` constraint beyond the existing installer path. A missing seed throws
  `SetupError.missingFile`.
- **L05.** Anchors match (the two-line doc comment, `hostInfo.isEmpty` line, `bytes(for:)`). 79 tests pass.
  **Restore decision against the real flow:** `start()` reads `hasSavedState` first (display source `.savedState`); then
  `prepare(run:)` calls the factory, which runs `ProvisioningSeed.prepare` and drops the saved state when the digest differs;
  `canRestore = suspend == .available && bundle.hasSavedState` is then false, and the existing branch
  (`attempt.display.source == .savedState`) calls `useColdStartDisplay()`, `letGoOfAttempt()` and `prepare(run:)` again; the
  second pass finds the digest it wrote and a cold display, and returns `.prepared(canRestore: false)`: a cold boot, no restore
  error. Added, changed and removed seeds all differ from the stored digest (including nil versus a digest). A refused spec
  throws before the digest code, so the saved state waits. Not covered by any test: this controller interplay (the card's
  tests exercise `ProvisioningSeed.prepare` and `restoresSavedState` only); only L-RUN or a controller test with a fake
  factory would. The framework may also refuse to save a machine with a USB drive (`validateSaveRestoreSupport()` is already
  consulted by the factory and reports a reason), in which case there is no saved state to drop.
- **L06.** Anchors match; `AllowProvisioning` locks and clears; 31 tests pass; docs step passes. The README keys list is
  already stale (no `AllowControlService`), left alone.
- **L07.** Anchors match; summary is 102 characters ending "."; related topics exist; claims checked against the library
  (phases, refused phases, `userData`/`networkData` and Base64 forms, `/var/lib/cloud/vmrunner`, `base64`, limits). No outside
  project is named. 35 tests pass.
- **L08.** Anchors match; compiles with no warnings; 52 tests pass; analyzers pass (no deadwood). Concurrency: `recheck()`
  runs on the main actor and hops to `Task.detached` for the file work (value types only, `ProvisioningCheck` is
  `Sendable`); fixed the stale-result race (edit 5). The `remove:` closure compiled unchanged, so its stop-condition fallback
  is not needed.
- **L09.** Anchors match; `vmr check docs` passes with diary `03` (the heading check); the "nothing links it yet" grep prints
  only the old history line, as the card says.
- **Final gate** after all nine cards plus the L03 fix: `swift run vmr check` 8/8 `PASS` (format, swiftlint, docs, workflows,
  policy, build, test, analyzers). Standing rules: no outside project or board/card id in the diff (greps), no `unsafe`, no
  warnings, no line over 140 columns, `VMController.swift` untouched, help summary rule satisfied.

## L-RUN: judged against CONTRIBUTING's real-guest conditions

- Scratch directory (`VMRUNNER_DATA_DIR` under `/tmp`, new, 0700), caps (owner sets 2 CPUs, 2048 MiB), runtime limit 15 min
  plus the agent's cap (now enforced), own window only with no agent clicks, keys or screenshots (stricter than CONTRIBUTING),
  own pids only, clean-up, 1 GiB download limit (now enforced by curl): satisfied after the edits.
- Difference from the documented path: it drives the app through the owner's hands instead of `vmr guest`, which is justified
  (the thing under test is the app's start path), but the caps then rest on the owner's clicks (step 7); the card lists them.
- Measurements and the open questions: it answers USB discovery (lsblk TRAN/RO/FSTYPE/label, platform/subplatform), Joliet
  names, `Merge-Type` merge (both parts plus `power_state` reboot), `/var/lib/cloud/vmrunner` execution and `noexec`,
  `base64`, every-boot count, and stop clean-up. Line numbers 17/21/24 of the spec verified. It does not answer: the L05
  cold-boot-after-changed-seed path, nor an actual suspend (only whether suspend is offered; edit d).

## Risks and owner decisions

1. **Defaults in INDEX-L** (owner to confirm before dispatch): 1 USB read-only (risk: trimmed cloud kernel; L-RUN says),
   3 no seed while the installer is attached, 5 digest-based drop of the saved state, 6 managed key `AllowProvisioning`.
   All implemented as written; I see no reason to overturn them. Decision 7 (medium exposure) is reasonable.
2. **Seed work runs on the main actor** (the factory is `@MainActor`): up to 64 KiB spec plus 32 files of 64 KiB, hashing, an
   ISO build and a write. A few milliseconds in practice; not worth a card.
3. **The editor's check reads the stored path with no approval.** A `config.json` copied from elsewhere that names a spec makes
   the editor read that file (and its scripts) when the section appears. Nothing reaches the guest (the start asks first), but
   a refusal text can echo the first key name of an arbitrary readable file (observed: "the spec has no field topsecret").
   Left as is (low); a later change could run the check only for approved paths.
4. The managed key is applied when the library loads or changes a machine, not at start, like the other keys.
5. Per-boot behaviour: first-boot steps never rerun on an existing machine; the help now says so.
6. Only the real-guest run can confirm: that cloud-init finds a read-only USB `cidata` volume, reads Joliet names, runs
   `bootcmd`/`runcmd`/the per-boot script and merges the two-part document; that the kernel has USB storage; that
   `/dev/hvc0` exists for the probes; that suspend is still possible (or its stated reason) with the drive attached; that
   a replaced `Disk.img` of 3 GiB is accepted by the app; and that the refusal message is actually shown in the window.
