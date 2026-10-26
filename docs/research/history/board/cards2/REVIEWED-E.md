# REVIEWED-E — Pre-dispatch review of cards E01 to E17 (2026-10-22, base `73bceb0`)

Method. Every anchor and `old` text was matched against the tree; then all 16 code cards were applied by script to scratch
copies of `Sources` and `Tests` (outside the repository, nothing built in it) and, after each card, the tree was
type-checked (`swiftc`, same upcoming-feature flags as `commonSettings`, `-strict-memory-safety`, warnings as errors, the
module and every test file), linted (SwiftLint with the repository configuration, `swift-format lint --strict`, format
stability on every changed file) and analysed (deadwood in production mode with the baseline, arcleak, dolly). E17's files
went through the real `DocsChecker`. The result is stated per card below; a patch line says what the review changed.

| Card | Verdict |
|---|---|
| E01 | PASS. Compiles, lints, formats; anchors exact; the 94-character help summary is within 110. |
| E02 | PATCHED. The new `Model/NetworkCutoff.swift` and `Engine/NetworkCutoff.swift` have one file name in one module, which swiftc refuses (`filename "NetworkCutoff.swift" used twice`): the model file is now `Model/NetworkCutoffRule.swift` (also in E03 and E06), with a note in the card. |
| E03 | PATCHED (path of the renamed model file). Otherwise PASS. |
| E04 | PASS. Posture, summary, exposure, Isolated and Hardened clearing, `ModelTests` and a legacy-decode test are all present. |
| E05 | PATCHED. `return devices` occurs twice in `ConfigurationBuilder.swift` (in `storage(for:bundle:)` and in `directoryShares`); the anchor now says which one. |
| E06 | PATCHED (path of the renamed model file). Otherwise PASS. |
| E07 | PASS. The IOKit function was compiled alone with strict memory safety and warnings as errors (clean; every one of the four `unsafe` markers is needed: without them it warns), linked and run (percentage and `ac` printed). `IOPSCopyPowerSourcesInfo` returns `Unmanaged<CFTypeRef>?`; `kIOPS…` constants import as `String`. |
| E08 | PATCHED. `HostInfoPublisher.interval` inside the class is a SwiftLint error (`prefer_self_in_static_references`, strict): it is `Self.interval`. Loop shutdown reviewed (cancelled sleeps throw on both clocks; weak capture; `isolated deinit`). |
| E09 | PASS. The three prefixes were checked against the IEEE MA-L registry (`oui.csv`, GET): `000393` Apple, Inc.; `001B21` Intel Corporate; `00E04C` REALTEK SEMICONDUCTOR CORP. |
| E10 | PATCHED. Added a legacy-decode test for `diskInterface` and `diskSerial` (the tolerant-decode rule). |
| E11 | PATCHED. Added a legacy-decode test for `freshIdentityPerStart`. |
| E12 | PASS. Summary 102 characters, titles unique, `related` never names the topic itself. |
| E13 | PASS. The four raw values are exactly the strings stored today; the card's grep step prints nothing after the edit. |
| E14 | PATCHED (a misleading comment on the `MaxRuntimeMinutes` parse; the code was right). Parse reviewed: a forced Boolean, a string, 0, or a number outside 15 to 1440 all become 15. |
| E15 | PATCHED. `static var current: ManagedPreferences { ManagedPreferences() }` is a SwiftLint error (`prefer_self_in_static_references`, twice): it is `static var current: Self { Self() }`. |
| E16 | PASS. |
| E17 | PATCHED. The prose said the owner still has to check the three prefixes; they are checked, so roadmap 0012 and the diary now say so (and that no address was tried on a guest). `vmr check docs` logic run over the result: 0 violations; the diary name for today is `2026-10-22-04.md`. |

Other changes. INDEX-E: how to read indented code blocks (strip the opening fence's indentation), the reviewed facts of the
"cards to read twice", decision 6 (prefixes verified), new decision 11 (forced `MaxRuntimeMinutes` of 0 restricts to 15).

Not found wrong (checked): ordering and dependencies (every card compiles and passes lint, deadwood, arcleak and dolly on
its own, in order); each new symbol has a production use in its card (deadwood reports nothing at any stage, and does
report a test-only symbol when one is planted); `VMController` and `VMLibrary` stay under `type_body_length`; no outside
project is named; no `String(format:)`; no `swiftlint:disable` added; the NetPolicy exceptions are spelled out in E01 and E02
("Override of COMMON") and in INDEX-E, and are one keyword each (`package var vpn`, `package func allowsNetwork`).

## Cards that are still risky

- **E02** (kill switch swap): `VZNetworkDevice.attachment` is settable and nullable, but nothing in the SDK says the same
  attachment object can be put back, or that the change works on a machine just restored and still paused. Unit tests use fakes.
- **E05, E08** (host-information share): a custom virtio-fs tag on a macOS guest (`mount_virtiofs vmrunner-host`) is unverified, and
  the effect of this extra device on `validateSaveRestoreSupport` (suspend) is unknown.
- **E11** (fresh machine identifier): a macOS guest installed under one identifier and started with another may not boot or may
  lose its identity; the duplicate path does the same, which is encouraging, but no run exists.
- **E14 to E16** (managed preferences): ADR-0013 stays `proposed`; the library reads the policy at launch only; the locks wrap
  controls in an `HStack`, which can change the layout of the form rows (the Settings `TextField` and the menu toggle most).
- **E07**: needs a laptop to compare with the menu bar; the unit test is a smoke test (a Mac without a battery has no percentage).

## Owner decisions

1. ADR-0013: accept it with the key set of E14 (or change it). E17 lists it as owed.
2. A forced `MaxRuntimeMinutes` of 0 restricts to 15 minutes (fail closed). Say so if 0 should mean "no limit".
3. The kill switch applies to NAT and to the filtered network, and cuts at start while the VPN state is unknown.
4. Host information goes over a read-only virtio-fs share (no guest agent); Isolated and Hardened clear it.
5. The in-guest VPN probe is not carded: it needs an ADR for the new guest-to-host channel.
6. Realism knobs and the kill switch stay outside the security profiles and the posture.

## Owner-only real-guest runs (never dispatched)

R1 after E03 (and E02): NAT and filtered, link goes down and comes back, the same attachment object really carries traffic,
also after a restore of a suspended machine; metered switch on a hotspot. R2 after E08: mount `vmrunner-host` in a Linux and a
macOS guest, files readable and updating, and Suspend with host information on. R3 after E10: Linux on NVMe, serial in
`/dev/disk/by-id`. R4 after E11: a disposable macOS guest with a fresh identifier boots. R5 after E09: DHCP on NAT with each vendor
prefix. R6 after E16: a real configuration profile (locks shown, clamp applied, `defaults write` not policy). R7 after E07: the
`battery` file against the menu bar on a laptop.
