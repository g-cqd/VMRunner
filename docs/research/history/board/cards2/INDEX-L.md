# Chain L: provisioning, second step — the seed attached to a Linux machine (9 cards, one branch, sequential; then L-RUN)

Roadmap 0016 ("Remaining" items 1 to 3), ADR-0012 (decision 1). The library `Sources/GuestSeed` is on `main`; nothing
links it. This chain links it from the app, adds the per-machine setting, builds the seed at each start, attaches it,
handles a saved state, closes it in the strict profiles, adds a managed key, the help topic (experimental), the editor
section and the records. A separate card, `L-RUN.md`, is the first real-guest run; it runs after the merge.

Branch `chain/l-seed-attach` from `main` at `b51d258`, one long-lived worktree, created by the integrator (never by a card):

```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/l-seed-attach -b chain/l-seed-attach b51d258
```

`WT = ~/Developer/g-cqd/VMRunner-chains/l-seed-attach`. Haiku (effort low) does each card; sonnet
(effort medium) reviews every card before dispatch and the chain's diff before the merge; opus merges after the gate.
One build at a time: the cards run strictly in order in the one worktree.

## Order, dependencies and files

| Card | Scope | Depends on | Files | Size | Risk |
|---|---|---|---|---|---|
| L01 | `VMConfig.provisioningSpecPath` (tolerant decode, absolute, at most 1024 bytes), `activeProvisioningSpecPath` (Linux, installer not attached), a read-only `HostPathGrant` kind | — | `Model/VMConfig.swift`, `Model/VMConfig+Validation.swift`, `Model/HostPathApprovals.swift`, `Tests/.../ProvisioningSpecPathTests.swift` (new) | ~120 | low |
| L02 | Isolated and Hardened remove the spec; `Posture.provisioning`; the exposure line | L01 | `Model/Security.swift`, `Tests/.../ProvisioningPostureTests.swift` (new), `Tests/.../ModelTests.swift` | ~110 | low |
| L03 | The app links `GuestSeed`; the nine `@dw:disable` directives go; `ProvisioningSeed` reads, checks and compiles the spec at each start and writes `ProvisioningSeed.iso` (0400) into the bundle; refusals carry the spec's line into the start error; the seed is a run leftover | L01 | `Package.swift`, `Tests/DevToolsTests/DependencyPolicyTests.swift` (one set), `Sources/GuestSeed/*.swift` (first lines only), `Model/ProvisioningSeed.swift` (new), `Model/Storage.swift`, `Model/APFS.swift`, `Engine/VZGuestMachine.swift`, `CONTRIBUTING.md`, `README.md`, `Tests/.../ProvisioningSeedTests.swift` (new) | ~260 | **high** (first link, dead-code findings, start path) |
| L04 | `ConfigurationBuilder.storage` attaches the seed as a read-only USB mass storage device after the disks | L03 | `Engine/ConfigurationBuilder.swift`, `Tests/.../StorageDevicesTests.swift`, `Tests/.../ProvisioningSeedTests.swift` | ~90 | medium |
| L05 | Saved state: `restoresSavedState` compares the spec in use; `ProvisioningSeed.prepare` keeps the last seed's digest and drops a saved state whose seed was added, changed or removed; `SeedImage.bytes` becomes `package` | L04 | `Model/VMConfig.swift`, `Model/ProvisioningSeed.swift`, `Model/Storage.swift`, `Sources/GuestSeed/SeedImage.swift`, `Tests/.../StorageDevicesTests.swift`, `Tests/.../ProvisioningSeedTests.swift` | ~120 | **high** (restore path) |
| L06 | Managed key `AllowProvisioning`: clears the spec on every machine, locks the chooser; help, ADR-0013 and roadmap 0013 lines | L01 | `Model/ManagedPreferences.swift`, `Help/HelpContent+AppSnapshots.swift`, `Tests/.../ManagedPreferencesTests.swift`, `docs/adr/0013-*.md`, `docs/roadmap/0013-managed-preferences.md` | ~50 | low |
| L07 | Help topic `provisioning` ("Provisioning (experimental)") | L06 | `Help/HelpTopic.swift`, `Help/HelpContent+Provisioning.swift` (new), `Tests/.../ProvisioningHelpTests.swift` (new) | ~90 | low |
| L08 | Editor: `ProvisioningSection` (choose, check again, remove; one line per step with its line and digest; the refusal inline), `ProvisioningCheck`, the picker target and its approval | L03, L06, L07 | `Model/ProvisioningCheck.swift` (new), `Views/Editor/ProvisioningSection.swift` (new), `Views/Editor/ConfigEditor.swift`, `ViewModels/ConfigEditorModel.swift`, `Tests/.../ProvisioningSeedTests.swift`, `Tests/.../HostPathApprovalsTests.swift` | ~170 | medium |
| L09 | Roadmap 0016 dated section and trimmed "Remaining"; ADR-0012 dated note (stays proposed); diary `2026-10-23-NN` | L08 | `docs/roadmap/0016-provisioning.md`, `docs/adr/0012-*.md`, `docs/diary/2026-10-23-NN.md` (new) | ~90 | low |
| L-RUN | First real-guest run, by an authorised agent after the merge; conditional on a cloud image (none in the catalog) | merge of L01–L09 | nothing in the repository; report at `~/Developer/g-cqd/vmrunner-board/realguest-seed-report.md` | — | owner-gated |

Paths are under `Sources/VMRunner/` unless they start with `Sources/`, `Tests/` (`Tests/VMRunnerTests/`), `docs/` or are at the root.

## Rules for chain L (they override `cards/COMMON.md` where they differ)

- **Base.** `main` at `b51d258`, not COMMON's `73bceb0`.
- **Never touch** stays as in COMMON, except: L03 edits `Package.swift` (the app target's dependency line and the GuestSeed
  comment, nothing else) and the set of library targets in `Tests/DevToolsTests/DependencyPolicyTests.swift` and the first lines of the files under `Sources/GuestSeed`; L05 changes one access level in
  `Sources/GuestSeed/SeedImage.swift`; L02 edits `Sources/VMRunner/Model/Security.swift` (the lines it names). No card edits
  `.swiftlint.yml`, `.deadwood.json`, `.dolly.json`, `.vmr.json`, a baseline, the `platforms` line or
  `Sources/VMRunner/Engine/VMController.swift` (its class body is at exactly 300 counted lines, measured with the pinned
  SwiftLint: one more line fails `type_body_length`; that is why the seed is built in `VZMachineFactory.prepare`).
- **Standing owner rules**, repeated in every card: no outside project named in prose, docs, comments or commit messages
  ("the shared utility library" and the like; the formats and tools the repository already cites, such as cloud-init, NoCloud,
  ISO 9660 and Joliet, are not the owner's projects and may be named as ADR-0012 does); no distribution plans; every commit
  atomic, signed, building, `swift run vmr check` 8/8 with the log READ before committing; Swift 6.4 strict memory safety (no
  card needs `unsafe`; if the compiler asks for one, put it on the expression with a comment, and report it); warnings are
  errors; SwiftLint `type_body_length` 300; Swift Testing; no board or card ids in code, docs, comments or commit messages;
  agents building cards never start a virtual machine (the tests build configurations and write files only); tests use
  scratch directories only (`scratchDirectory()`), never `~/Library` or the app's data folder.
- **Compile errors.** The cards' code was written without a compiler (SwiftLint `--strict` and `swift-format lint` were run
  on every new file and on the edited `Security.swift` and `ConfigurationBuilder.swift`; both clean). A compile, SwiftLint or
  swift-format finding is fixed minimally on the reported line, without changing behaviour, a message, an output byte or a
  test's meaning, and the report says what changed. **A failing test is never edited: the executor stops and reports.**
- **Dead code (L03 only).** Removing the directives exposes the GuestSeed declarations that only the library's tests read.
  L03's procedure accepts each such finding with a trailing `// @dw:accept:this referenced-only-by-tests -- <reason>` on the
  reported line (COMMON's lesson), and stops on any other finding.
- **No help topic before L07, no editor before L08.** Until L08 nothing in the app sets the path, so the intermediate commits
  change nothing a user can see; each still builds and passes the gate.

## Decisions taken in these cards (owner may overturn; defaults in force)

1. **Bus: USB mass storage, read-only** (ADR-0012 decision 1), not a read-only virtio disk. cloud-init's NoCloud source
   finds the seed by its filesystem label (`cidata`, ISO 9660) on any block device the kernel shows, so the bus does not
   matter to cloud-init itself; it matters to the guest's kernel. The app already boots every catalog installer from a
   read-only USB drive, so general distribution kernels have the drivers. USB also keeps the guest's virtio disks exactly the
   user's disks, takes the installer's place (the seed is never attached together with the installer, decision 3), and is the
   device the framework can detach while the machine runs (roadmap 0016: "detach the seed after the first boot", not built).
   Risk: a trimmed cloud kernel without USB storage would not see it; L-RUN records that, and the fallback is a one-block
   change in `ConfigurationBuilder.storage` (a `VZVirtioBlockDeviceConfiguration` with the same read-only attachment, appended
   last). Alternative now: virtio.
2. **Where the seed lives:** `<bundle>/ProvisioningSeed.iso`, 0400 (the library's `SeedImage.write`). The bundle has no run
   folder: a run's leftovers are files of the bundle that `VMBundle.discardEphemeral()` removes at every stop, at launch for
   every machine not running and before a disposable start; the seed joins that list, and is written after the disposable
   copy is made. Alternative: a `Run/` folder (changes the bundle layout and `discardEphemeral`).
3. **Not while the installer is attached.** `activeProvisioningSpecPath` is nil while the installer is attached: an
   installer's live system with cloud-init would find the seed and run its steps in the installer. The editor says so.
   Alternatives: attach both; refuse the start.
4. **Instance identifier:** the machine's `id.uuidString` (36 ASCII characters, which the compiler accepts). First-boot steps
   run once per machine; a disposable machine's disk is discarded, so they run at every start.
5. **Saved state:** `restoresSavedState` compares the spec in use (an edit adds, removes or moves the seed drive, so
   `VMLibrary.update` drops the saved state), and `ProvisioningSeed.prepare` keeps the SHA-256 of the last seed in
   `<bundle>/ProvisioningSeed.sha256` (0600, not a run leftover) and drops a saved state when the new seed's digest differs
   (a spec or script edited outside the app). The controller's existing path then boots cold (`prepare(run:)`: no saved
   state left, display rebuilt). Alternative: forbid suspend while a seed is attached.
6. **Managed key `AllowProvisioning`: added.** ADR-0013's keys lock what reaches a guest from the Mac (shared folders,
   clipboard, microphone, host information); a seed carries the user's files and runs them as root in the guest, which is
   the same kind of channel, so the key is natural. Forced to anything but true it clears the spec on every machine and
   locks the chooser. Alternative: no key.
7. **Exposure level medium**, like the attached installer image and a read-only shared folder (the guest reads host
   content); the text says the steps run as root. Alternative: high.
8. **Where the start builds the seed:** `VZMachineFactory.prepare`, before `ConfigurationBuilder.buildInBackground` (not
   `VMController`, which is at its type-length limit). A refusal is thrown there, so it reaches `errorMessage` through the
   controller's existing `.startFailed(error.localizedDescription)`: "The provisioning spec machine.yaml can't be used:
   line 7: at must be one of …. Fix it, or remove it in the machine's settings to start without it."
9. **Errors:** the library stops at the first problem, so a start shows one refusal, with its line when it has one.
   Collecting every error needs a reader change; not done. Alternative: a later change in the library.
10. **The editor's check is a preview** (`ProvisioningCheck`, read away from the main thread when the path changes and on
    "Check Again"); the start reads and decides again. The scope says "read and compiled at START (not at edit time)": the
    stored setting is only the path, and nothing the editor reads is kept. Alternative: no preview.
11. **Approval:** one read-only grant of kind `provisioningSpec` for the spec path; the scripts it names must sit below the
    spec's folder (the library refuses `..` and links), so the approval of the spec covers them. Alternative: a grant per
    script file.
12. **Access level:** `package` (ADR-0047), as `NetPolicy` and `NetStack`; only `SeedImage.bytes(for:)` changes (L05). The
    test target `VMRunnerTests` does not link `GuestSeed`: the app's API in this chain exposes only app types and strings to
    tests.
13. **Help area** `.machines`, title "Provisioning (experimental)", the word "Experimental" in the summary and the first
    paragraph, until L-RUN says otherwise.

## Owner-run list

- Confirm or overturn decisions 1, 3, 5 and 6 before L03 (1, 3), L05 (5) and L06 (6).
- After the merge, the integrator removes the worktree and the branch (CONTRIBUTING, "Worktrees and cleanup").
- Authorise L-RUN (a real-guest run) for a session, and the download it names (about 0.5 GB, above nothing the catalog
  offers; L-RUN stops before downloading more than 1 GiB). L-RUN needs the owner for the clicks in the app's own window
  (the agent sends no clicks or keys).

## Review focus (sonnet, before dispatch)

Hardest: **L03** (the link: the nine first-line removals, the dead-code procedure, the start path in `VZMachineFactory`,
the bounded spec read, the tests' line numbers 7 and 11 against the fixture) and **L05** (the digest rule: the five steps of
`aSavedStateIsKeptOnlyWhileTheSeedIsTheOneItWasSavedWith`, and that `VMController.prepare(run:)`'s
`canRestore`/`.savedState` branch really boots cold when the factory removed the saved state). Next: **L08** (SwiftUI
`.task(id:)` with `Task.detached`, the binding closure that clears the path) and L02's posture matrix.
