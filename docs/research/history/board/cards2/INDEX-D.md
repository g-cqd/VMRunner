# INDEX-D — Chain D: the security backlog (board items F3, F4, F5, F6, F7, F8, F10, F11, F13; roadmap 0034)

Base: `main` at `73bceb0`. Every anchor of every card was read on that commit (line numbers are never used; cards name text).
Worktree, created by the integrator, never by a card:

```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/d-security -b chain/d-security main
```

`WT = ~/Developer/g-cqd/VMRunner-chains/d-security`. Files: COMMON.md (in `../cards/`), this index,
CHECKLIST-D.md (pre-dispatch review), D01.md to D22.md, `fixtures/` (Swift fixture files the cards copy, and `fixtures/raw/`, the
vendor files and keys captured on 2026-10-22, for the reviewer).

## Rules for chain D (they override COMMON where they differ)

- **Never-touch list.** COMMON forbids `Sources/NetPolicy`, `Sources/NetStack` and `Sources/VMRunner/Policy`/`Network` (the
  last two no longer exist). In chain D a card may edit exactly the files its "Files" list names, including files under
  `Sources/NetPolicy` (D09) and `Sources/NetStack` (D09 to D15). Everything else on COMMON's list stays forbidden, and so does
  `Sources/VMRunner/Model/Security.swift`: no card changes what a guest can reach in a way the exposure summary would show.
- **Copied files.** D04 to D06 create or replace `Tests/VMRunnerTests/SignedVendorFiles+AlmaRockyFedora.swift` with `cp` from
  `fixtures/`; never retype a fixture. Each card checks the copy with `diff` after `swift-format`.
- **No network, no guest.** No card fetches anything or starts a virtual machine. The vendor data was captured by the
  orchestrator on 2026-10-22 and is in the cards and in `fixtures/`.
- **Held cards.** D07 carries an owner gate with a default of "go"; D19 to D21 are held until the owner decides ADR-0055. The
  integrator fills the `<<...>>` placeholders of D18 and D22 before dispatching them.
- **Build cap and gate time** as in COMMON (one chain, one build at a time; D02 counts as a build).

## Order and dependencies

| Card | Board | What | Depends on | Owner gate | Network or guest |
|---|---|---|---|---|---|
| D01 | F13 | Gate lock unlocks explicitly; test retry removed; mechanism test; 30-run evidence | — | — | no |
| D02 | F13 | Probe, no commit: `vmr check tsan` twice | D01 (tree) | — | no |
| D03 | F5 | `PinnedKey.expires`, `Failure.keyExpired`, 90-day test, help, CONTRIBUTING release step | — | 90 days (default) | no |
| D04 | F3 | AlmaLinux 10 signed (key, provider, fixture, tests), still a candidate | D03 (only for order) | — | no (data captured) |
| D05 | F3 | Rocky Linux 10 signed via shared `CHECKSUM` + `.asc`, still a candidate | D04 | Rocky's second fingerprint source | no |
| D06 | F3 | Fedora 43 key, floor and catalog entry, still a candidate | D05 | Fedora releases offered | no |
| D07 | F3 | Offer the six images; allow three hosts; help | D04, D05, D06 | Offering vendors (default go) | no; live download is an owner follow-up |
| D08 | F3, F5 | ADR-0054 (proposed); roadmap 0022, 0023 | D03, D07 (variant if D07 skipped) | ADR status | no |
| D09 | F6 | Derived blocks for port-scoped name rules; help | — | — | no |
| D10 | F8 | DNS-over-TCP answer that finds the buffer full: reset + `dnsAnswersLost` | — | reset vs count only | no |
| D11 | F8 | `AnswerFolding`: repeated DNS answers folded | D10 (same file) | — | no |
| D12 | F8 | Flow log shows the count of a folded answer; help | D11 | — | no |
| D13 | F7 | Resolver workers (no thread per lookup) | — | — | no |
| D14 | F7 | Guest transmit queue bounded in bytes (8 MiB) | — | — | no |
| D15 | F11 | `DNSWireMutationTests` (seeded mutation, in the gate) | — | coverage-guided job | no |
| D16 | F10 | macOS install reads its own clone of the restore image | — | interpretation (below) | real macOS install is an owner follow-up |
| D17 | F10 | Flat-cache machines get their clone at launch | D16 (same file) | — | no |
| D18 | all | Roadmap 0034, 0008, 0036; update notes on ADR-0028, ADR-0031 | D01 to D17, D02's report | `<<TSAN>>` filled | no |
| D19 | F4 | HELD: cleartext message with several signatures; ADR-0055 (proposed) | D18 | ADR-0055 decision 1 | no |
| D20 | F4 | HELD: Debian archive subkey pin; `DebianReleaseTrust`; netboot provider | D19, D03 | ADR-0055 decisions 2, 3 | no; live `InRelease` is an owner follow-up |
| D21 | F4 | HELD: help and roadmap for the Debian chain | D20 | — | no |
| D22 | all | Diary entry | last card that ran | placeholders filled | no |

Dispatch order: D01, D02, D03 ... D18, then D19 to D21 if the owner accepted ADR-0055, then D22. D09 to D15 and D16 to D17 do
not depend on D03 to D08 and may run before them if the owner holds F3; keep the numbering in the reports.

Sizes: all cards are 20 to 120 changed lines except D07 (about 150, a move of six entries), D11 (about 150, a new type with its
wiring) and D20 (about 170, a trust that has no caller until the provider uses it); each says why it is not split.

## Overlap with the other chains written in this folder

Chain E (`INDEX-E.md`, worktree `e-features`) edits some of the same files, in other places:
`Sources/VMRunner/Help/HelpContent+FilteredNetwork.swift` (E01; D09 and D12 edit other paragraphs),
`Sources/VMRunner/Engine/Provisioner.swift` (E11, E13; D16 edits `provisionMac`, a few lines above `discardCachedRestoreImage`,
whose body E13 may change), `Sources/VMRunner/Model/VMLibrary.swift` (E14 to E16; D17 adds one line to `load()` and an
extension before `LibraryError`) and `docs/roadmap/0036-order-of-remaining-work.md` (E17; D18 and D21 edit the `| F |` row,
next to rows E17 may edit). Mark D09, D12, D16, D17, D18 and D21 CONFLICT-RISK while chain E is unmerged: whichever chain merges
second rebases first, and the card's anchors (text, never line numbers) are re-checked after the rebase (CHECKLIST-D item 1).
Neither chain E nor the ARC chain creates an ADR file, so ADR-0054 and ADR-0055 are free on 2026-10-22; D08 and D19 stop if
the number is taken by then.

## Work that needs a real network or a real guest (never run by haiku; owner or an authorised run)

1. **Before D04 to D06 and D20 are dispatched (reviewer, network, read-only):** re-read the fingerprints on the vendors' pages
   (CHECKLIST-D item 6). Everything else the cards need was captured on 2026-10-22.
2. **After D07:** one real setup per new vendor in a scratch `VMRUNNER_DATA_DIR` (the download only; no machine needs to be
   started): AlmaLinux 10 boot, Rocky Linux 10 boot, Fedora Server 43 netinst. Expected: the setup resolves 10.2, 10.2 and
   43-1.6 (or newer), verifies the signature and the SHA-256, and stores the machine.
3. **After D16:** one macOS install from the catalog (a real guest); afterwards no `.install-*` file is left in the image cache.
4. **After D20:** one real Debian netboot setup (download only); the app must accept today's `InRelease`.
5. **D02** needs neither, but it is long (two ThreadSanitizer runs).

## Owner decisions (each card states the default it implements)

1. **Offer AlmaLinux, Rocky Linux and Fedora (D07).** Roadmap 0022 makes offering a vendor the owner's choice; board item F3
   ("host entries") is read as that choice. Default: offer. If held: skip D07, D08 uses its "if D07 was skipped" text.
2. **Rocky Linux's fingerprint source.** Only one vendor page lists it (`rockylinux.org/keys`); the second source is the key
   file on `download.rockylinux.org`. Default: accept those two.
3. **Which Fedora releases.** Default: every release Fedora serves and supports, 43 and 44 on 2026-10-22. Fedora 45 is pinned
   when it is released (it needs a real signed `CHECKSUM` as a fixture).
4. **Key expiry (D03).** Default: refuse every signature from the second a pinned key expires; the test warns 90 days ahead.
5. **Debian netboot chain (D19 to D21, held).** ADR-0023 refuses files with more than one signature and leaves subkeys
   undecided; Debian's `InRelease` has three signatures, the one we can read made by a subkey. Default proposed: accept ADR-0055
   (up to four signatures, exactly one by a pinned key; a pinned subkey; trixie, 13.7 or later).
6. **Floor opt-in (F7, third part).** ADR-0029 left it out on purpose ("so that this change adds no way to lift the floor").
   Default: not built; D18 records it as open for the owner. No card.
7. **Coverage-guided fuzzing (F11).** The Xcode toolchain that the gate and CI use ships no `libclang_rt.fuzzer_osx.a`; the
   swift.org 6.4 toolchain on this Mac does. A libFuzzer target needs that second toolchain, a new target in `Package.swift`
   and a job outside the gate. Default: not added; D15 adds seeded mutation tests the gate runs.
8. **DNS-over-TCP answer that finds the buffer full (D10).** Default: reset the session and count it. Alternative: count only.
9. **"Clone the restore image" (D16).** Nothing copies the restore image today; the macOS install reads the shared cache file
   itself. Default reading: the install reads its own clone (ADR-0031's rule for Linux installers). If the owner meant something
   else, drop D16.
10. **ADR status.** ADR-0054 and ADR-0055 are written `proposed` (board item O14 decides ADR status).

## Cards to read twice (the orchestrator is not certain)

- D16, the reading of the board's wording: "this is how "clone the restore image instead of copying" is read".
- D15, a threshold estimated, not measured: `#expect(parsed > 500, "enough mutants still parse for the properties to mean something")`.
- D10, a size computed from the code, not run: "60 PTR records of 143 bytes: about 8.6 KB an answer, so one fits the 16 KiB
  buffer and two do not." It also assumes that a guest window of 0 keeps the first answer in the ring.
- D13, compilation of `private let queue: Mutex<ResolverQueue<Job>>` in a `final class ResolverWorkers: Sendable` (relies on
  `Mutex` being `Sendable` whatever its value).
- D04 to D06 and D20, the deadwood baseline: "deadwood or the `policy` step reports anything about `PinnedKeys.all` or
  `fedora(release:)`: stop and report the finding verbatim". `PinnedKeys.all` is used only by tests on `main` and passes today;
  whether it is in `.deadwood-baseline.json` (fingerprinted by position) could not be read without running the analyzer.
- D11, `swift test --filter UserNetBootTests` targets a suite nested in `extension UserNetIntegration`.
- D01, 30 runs as evidence: the flake was about 1 in 40 before the retry; 30 clean runs are consistent with the fix, not proof.
  The deterministic test is the proof of the mechanism.

## Card to board item

D01-D02 F13 · D03 F5 · D04-D08 F3 (D08 also F5) · D09 F6 · D10-D12 F8 · D13-D14 F7 · D15 F11 · D16-D17 F10 · D18 all ·
D19-D21 F4 · D22 diary.

## Evidence captured on 2026-10-22 (`fixtures/raw/`, SHA-256)

```
509c25b9bdc68c1c69b1935d78fd3649542c83b9ef9a6269a76572a8dc7afab7  almalinux-10-aarch64-CHECKSUM
c3faee713f4668df4dae60462b5cdd1da5e8b00eea22424241f7815f0f7feee7  rocky-10-aarch64-CHECKSUM
18cc249815403893df2ebc1e94d456f828249827c2c0348da7b68e435566a908  rocky-10-aarch64-CHECKSUM.asc
6087de5ba3b2252f798ca7ce31231fbedad67f4abbe469c4f3d3c879de313a56  Fedora-Server-43-1.6-aarch64-CHECKSUM
de57c3c0a2dcde88ff5b894e74335f55a0ec074815f36d472270d937c16f077b  RPM-GPG-KEY-AlmaLinux-10
be8c4f070b696e64d8ce40e59a95a57e8b5c776f0015c2fd64e14b896622bdb4  RPM-GPG-KEY-Rocky-10
2b1449a082d3264dda8e18369f04e9ac4163bf3f8cb530b0783dc2ab064a08ec  RPM-GPG-KEY-fedora-43-primary
6f1d277429dd7ffedcc6f8688a7ad9a458859b1139ffa026d1eeaadcbffb0da7  debian-archive-key-13.asc
```

plus `debian-stable-InRelease-2026-10-22`. Each signed file verified with `gpg` against its key on that day; the AlmaLinux,
Rocky Linux and Fedora ISOs answered `HEAD` with 200 and no redirect; Debian's `InRelease` listed the SHA-256 of the served
netboot `SHA256SUMS` (`c73307d6...`). The Swift fixture files in `fixtures/` were checked to decode to exactly these bytes.
