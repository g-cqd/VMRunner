# VMRunner

A small SwiftUI app that creates and runs **macOS** and **Linux** (CentOS Stream, Debian, Alpine, Ubuntu Server or any arm64 UEFI ISO) virtual machines on Apple
silicon with Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization).
The app links the system frameworks and one pinned package, `swift-async-algorithms` (which brings in
`swift-collections`); the developer tooling (`vmr`, below) uses two other pinned Apple/Swift packages and is never
linked into the app.

## Start here

- [White paper](docs/WHITE-PAPER.md): the rules this repository is built under.
- [Architecture decisions](docs/adr/): one decision per file, with context, evidence and consequences.
- [Roadmap](docs/roadmap/): one unit of work per file, with status, blockers and the decision that governs it.
- [Diary](docs/diary/): the working log, one file per session, with claims, probes and verdicts.
- [Research](docs/research/): dated studies that feed the roadmap and the decisions: automation, analysis sandboxes, GPU,
  MDM, Windows on ARM, provisioning, containers and sandboxing.

## Build and run

```sh
swift run vmr build-app         # release build -> build/VMRunner.app (ad-hoc signed, hardened runtime), then verified
swift run vmr build-app debug   # debug build
open build/VMRunner.app
swift test                      # unit tests
```

The app needs the `com.apple.security.virtualization` entitlement, which `vmr build-app` applies when signing.
`swift run VMRunner` won't work for the same reason: use `vmr build-app`.

Requires an Apple silicon Mac on macOS 26+. Built with Xcode 27 / Swift 6.

Start a machine from the command line (handy for scripts):

```sh
open build/VMRunner.app --args --start "My VM"     # by name or UUID
```

## What it does

| | macOS guest | Linux guest |
|---|---|---|
| Media | Latest supported image from Apple, any signed build from [ipsw.me](https://ipsw.me), or a local `.ipsw` | Newest aarch64 ISO of CentOS Stream 9/10, Debian stable, Alpine Linux or Ubuntu Server LTS (resolved from each vendor's own pinned host, SHA-256 verified, and for Ubuntu Server and Alpine Linux the vendor's OpenPGP signature checked against a pinned key), or a local ISO |
| Boot | `VZMacOSBootLoader`, installed with `VZMacOSInstaller` | UEFI (`VZEFIBootLoader`), installer ISO attached over USB |
| First-boot account | Skips Setup Assistant on macOS 27 guests (`VZMacGuestProvisioningOptions`) | – |
| Extras | Recovery boot, trackpad or mouse | Nested virtualization (M3+), Rosetta for x86_64 binaries, SPICE clipboard, Secure Boot (host macOS 27+) |

Common to both: CPU/memory, sparse disk (grow-only), extra disk images, disk cache/flush mode, 1–2 displays,
audio in/out, NAT, filtered (user-mode) or no network, custom MAC, shared folders (virtiofs), suspend/resume, snapshots,
duplicate, memory balloon / entropy / vsock devices, a VPN and metered-network kill switch, opt-in host information over a
read-only share, and guest-identity settings (MAC vendor, NVMe, disk serial, a fresh identity per disposable start).

Downloads are resumable and verified: IPSW against ipsw.me's SHA-256, ISOs against the mirror's `.SHA256SUM`. Downloads are
filed in a shared cache by their checksum, and a Linux machine boots from its own copy-on-write clone of the verified
installer, kept in its bundle, never from the cache.

### Display

The guest starts at the window's **aspect ratio**, at 1 pixel per point. For Linux the start width is capped at
1280 px, because UEFI and GRUB draw fixed-size glyphs and a framebuffer matching a large window pixel for pixel
makes them tiny; the view scales it up. Once Linux is running, the display follows the window at 1× (or 2×,
configurable). macOS follows the configured pixel density. You can instead pick a fixed preset.
In full screen the toolbar and sidebar are hidden (View ▸ Hide Toolbar in Full Screen); the **Machine** menu has
Start, Pause, Suspend, Shut Down and Force Stop with shortcuts.

## Security profiles

Settings ▸ **Security** picks a profile, then every switch stays individually editable. The profile shows
*Custom* once you deviate. A summary lists exactly what the guest can reach on the host.

| | Standard | Contained | Isolated | Hardened |
|---|---|---|---|---|
| Network | NAT | NAT | none | none |
| Clipboard, Rosetta, nested virt, vsock | on/opt-in | **off** | off | off |
| Microphone | off | off | off | off |
| Sound output | on | on | **off** | off |
| Shared folders / extra disks | as set | **read-only** | **removed** | removed |
| Attached installer ISO (Linux) | as set | as set | **detached** | detached |
| Secure Boot (Linux, host macOS 27+, not Alpine) | off | off | **on** | on |
| Disposable disk (changes discarded on stop) | off | off | off | **on** |
| Suspend (writes RAM to disk) | on | on | on | **off** |
| Memory balloon | on | on | on | **off** |
| Auto-login / SSH (macOS first boot) | as set | as set | as set | **off** |
| Host information (battery, power, thermal state, network path, time zone) | opt-in | opt-in | **off** | off |
| Runtime limit | none | none | none | **120 min** |

Contained stays on NAT on purpose: the filtered network below is newer and less proven than Apple's NAT, so no profile
selects it. Choose it yourself (the profile then reads *Custom*).

The entropy device is never removed: the guest needs it for randomness.
A machine's `config.json` is only data, so the shared folders, extra disks and installer image it names are used only
after you approved them in the app (the file pickers, the New Machine sheet, or "Approve and Start"). A machine copied
from elsewhere asks at Start; `VMRunner --start` refuses to start it (ADR-0024).
These settings narrow the host–guest channels. They don't make an untrusted guest safe on their own.

A kill switch cuts a running machine's network card, with NAT or the filtered network, while the Mac breaks the machine's
rule: a VPN required or forbidden on the Mac, or a metered or Low Data Mode connection. It watches the Mac, not the guest
(Help ▸ Kill switch). An organisation can restrict every machine through managed preferences (ADR-0013):
`AllowSharedFolders`, `AllowClipboardSharing`, `AllowMicrophone`, `AllowSuspend`, `AllowHostInformation`,
`RequireDisposableMachines` and `MaxRuntimeMinutes`; the restricted controls show a lock.

## Filtered network (user-mode)

Settings ▸ Network ▸ **Filtered (user-mode)** connects the guest to VMRunner's own network stack
(`Sources/NetStack`) instead of Apple's NAT. Every connection is checked against a per-machine policy before
it is made:

- **Block list** (everything except what you block) or **Allow list** (nothing except what you allow); a block always
  beats an allow. Lists: domains (`example.com`, `*.example.com`), IP addresses and CIDR blocks, ports and ranges,
  connections (`github.com:443`), and plain-`http` URL prefixes. Private, local and host ranges are blocked by default.
- Blocked TCP connections are refused or silently dropped (your choice); open connections are reset when the Mac
  changes network (optional). Rules are read when the machine starts.
- While the machine runs, the toolbar's network button shows the recent connections (allowed or blocked, with the
  reason) and two VPN signals: one for the Mac, one for the guest's own traffic. In-app Help explains all of it.

Limits, also in Help: domain rules are advisory (names that share an address; DoH, DoT and DNS over QUIC are not
intercepted, ordinary port-53 DNS always is), IPv6 is not provided, IPsec and PPTP tunnels cannot pass (but are
detected), VPN detection is a heuristic, and the stack has not been validated against every guest or run in a real
virtual machine yet. Suspend may be unavailable in this mode.

## Disk space (APFS copy-on-write)

Everything that copies a disk uses `clonefile(2)`, so it is instant and shares blocks until one side writes:

- **Duplicate** clones the whole machine bundle.
- **Snapshots** clone the disk and firmware state; restore swaps them back.
- **Disposable** machines boot from clones of the disk and firmware state and delete them on stop.
- Disks are sparse; only blocks the guest writes use space.
- The 20+ GB macOS restore image is deleted after a successful install (Settings ▸ keep it if you want).
  Install once, then duplicate that machine instead of reinstalling.
- A saved memory state is deleted as soon as it has been restored.

"Disk usage" counts blocks shared with clones in full, so the real cost is lower. Cloning needs the machine
library and its copies on the same APFS volume (it is, by default: `~/Library/Application Support/VMRunner`).

## Linux guests and CI

- Apple silicon guests are **arm64 only**: you get `aarch64` images. An x86_64 VM can't run here.
- To run x86_64 *binaries* inside the Linux guest, enable **Rosetta** (Sharing) and follow the mount hint.
- Enable **Nested virtualization** (M3 or newer) for `/dev/kvm` in the guest, e.g. Podman or QEMU inside.
- For repeatable CI-style runs, use the **Disposable** switch (or the Hardened profile) so every boot starts
  from the same disk.

## Not included

- **Bridged networking**: needs the restricted `com.apple.vm.networking` entitlement (so does `vmnet`
  host-only networking). Provisioning-profile signing would be needed.
- **USB passthrough** (new in macOS 27, via AccessoryAccess): not investigated far enough to ship.
- **ASIF disk images**: raw sparse images already clone and snapshot well; ASIF's main benefit would be reclaiming
  space when the guest deletes files, which I haven't verified.
- macOS allows at most two concurrent macOS guests per host.
- **Secure Boot** is implemented for macOS 27+ hosts but couldn't be exercised on the development machine (macOS 26.7).

## Layout

```
Sources/NetPolicy   the network policy: rules, host and IP parsing, the gate that judges a connection (system frameworks only)
Sources/NetStack    the user-mode network stack behind Filtered networking (links NetPolicy; no Virtualization, no app type)
Sources/VMRunner
  Model/    VMConfig (Codable settings), Security (profiles, exposure summary), APFS (clone, snapshots),
            Storage (bundle layout, sparse disks), VMLibrary (machines, setup jobs)
  Engine/   ConfigurationBuilder (VMConfig -> VZVirtualMachineConfiguration), Provisioner (media + install),
            VMController (run/pause/suspend/restore, runtime limit), NetworkActivity (filtered-network log and VPN signals), Downloads, Catalogs (ipsw.me and the Linux vendors)
  Views/    ContentView, MachineView (toolbar, display), ConfigEditor, NewMachineSheet (+ Settings)
Machines live in ~/Library/Application Support/VMRunner/Machines/<uuid>.vm
```

## Quality gates and developer tooling

All tooling is Swift: the `vmr` executable (`Sources/vmr`, logic in `Sources/DevTools`) replaced the former shell and
Python scripts. It depends on [swift-subprocess](https://github.com/swiftlang/swift-subprocess) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser), both pinned with `exact:`; the app and its
tests link neither.

```sh
swift run vmr check                          # fast gate: format, swiftlint, docs, workflows, policy, build, test, analyzers
swift run vmr check --full                   # + ASan, TSan and UBSan test runs, release build, coverage and benchmark gates
swift run vmr check test coverage            # only the named steps; --list shows all of them
swift run vmr analyzers [run|install|baseline|versions] [arcleak|dolly|deadwood...]
swift run vmr bench record                   # re-record the benchmark baseline (.vmr-bench.json)
swift run vmr build-app [debug|release] [--hardened] [--arm64e]
swift run vmr container-sign [debug|release]     # container runner: build it and sign it for virtualization; running it boots a VM, owner only
swift run vmr sandbox run --engine seatbelt|app-sandbox|none --descriptor d.json   # sandbox helper; --boot starts a VM, owner only
swift run vmr guest fetch alpine-netboot --directory /tmp/g   # a signed Alpine netboot image in a scratch directory
swift run vmr guest start|exec|console|stop ...   # a small Linux guest behind a console socket; start boots a VM, owner-authorised runs only
swift run vmr guest start --net filtered --policy p.json; vmr guest policy|flows SOCKET ...   # the filtered network on a real guest
swift run vmr sarif arcleak.sarif ...        # readable findings from SARIF files
swift run vmr hooks install                  # pre-commit hook: format lint and SwiftLint on staged Swift files
```

Every step runs even if one fails; each prints PASS or FAIL and `vmr check` exits non-zero if any failed. Only one gate
runs per checkout: a second `vmr check` exits at once (status 75) naming the pid of the first, because two gates would
fight over `.build`. CI (`.github/workflows/ci.yml`) calls the same commands, so local and CI results match; when
`GITHUB_STEP_SUMMARY` is set, `vmr check` appends a table of the steps (result, duration) to it, with the test counts,
coverage and analyzer findings the steps reported. Per-repository settings (lint
paths, coverage bundles, the coverage floor, test targets left out of sanitizer and coverage runs) live in
`.vmr.json`; `swift run vmr <command> --help` documents every option.

- **Coverage** is measured on the logic layer only (Views, `VMRunnerApp`, `VMController`, `Provisioner` and
  `ConfigurationBuilder` need a display and the virtualization entitlement, so unit tests can't reach them).
  `COVERAGE_MIN` (default 55, set in `.vmr.json`) is a ratchet: it only goes up as coverage does (about 60% when introduced).
- **Benchmarks** (`vmr check bench`, full gate only) run the suites named `*Benchmarks` in an optimized build and hold their
  figures to the committed baseline `.vmr-bench.json`: allocation counts of the policy decision and the network stack paths
  (exact), retired instructions per unit of work for the checksum digests and the policy decision (3%), and their wall-clock
  rates (reported, never failing). A regression fails; an improvement tells you to re-record with `vmr bench record`. A plain
  `swift test` skips them. See ADR-0022.
- **Analyzers** are the pinned, checksum-verified releases listed in `Scripts/analyzers.lock`, run by
  `vmr analyzers` (binaries land in the git-ignored `.tools/`; the SHA-256 of each archive is checked against the
  lock, not against the release's own checksum file, before anything is unpacked or run; an installed binary is reused
  only while its digest matches the stamp the verified install wrote, and never when git tracks files under `.tools/`;
  the lock also records each tag's commit for a reviewer to compare, but that field is informational and nothing checks it):
  `arcleak` (retain cycles, anchor leaks, premature releases; any finding fails), `dolly` (duplicate code; exact
  clones fail, near and structural clones are advisory) and `deadwood` (unused and dead code, production mode; any
  finding fails). Configuration: `.arcleak.json`, `.dolly.json`, `.deadwood.json`. Existing findings can be
  accepted into the `.arcleak-baseline.json`, `.dolly-baseline.json` and
  `.deadwood-baseline.json` with `vmr analyzers baseline arcleak dolly deadwood`, so only new ones fail. Accept an intentional
  finding in source with `// @al:accept -- reason`,
  `// @dl:accept -- reason` or `// @dw:accept -- reason`.
- **SwiftLint** is pinned in `Scripts/analyzers.lock` too: the `swiftlint` step and the pre-commit hook install the
  portable release into `.tools/` on first use, with the same guarantees (the archive's SHA-256 is checked against the
  lock before anything from it is unpacked or run, then the binary must report the pinned version). It is never taken
  from `PATH`, so every checkout lints with one version; `SWIFTLINT_BIN` names a binary of your own instead.
- **Documentation** (`vmr check docs`) enforces the documentation law of `docs/WHITE-PAPER.md` section 5 over `docs/` and
  this README: the white paper stays within 200 lines; ADRs, roadmap entries, diary files and research studies have the
  right names, unique numbers, front matter and headings; supersession, `blocked-by`, `decision` and `feeds` references
  resolve (no `blocked-by` cycles); and every relative link resolves. It prints `path:line: message` per violation.
- **CI** on GitHub Actions: lint, build and unit tests, app bundle checks, sanitizers, coverage, benchmarks (advisory), analyzers,
  CodeQL, and workflow linting (actionlint, zizmor). Actions are pinned to full commit SHAs and Dependabot keeps
  them current. Hosted runners can't run nested VMs, so CI never starts a virtual machine.
- **Hardened build.** `vmr build-app` checks both entitlement files against an allowlist kept in code
  (`EntitlementPolicy`) before it builds, verifies the signature, reads the effective entitlements back and
  fails on `get-task-allow` (release), a `com.apple.security.cs.*` relaxation or any entitlement outside the allowlist. `vmr build-app release --hardened` signs with
  `Resources/VMRunner.hardened.entitlements`, which adds Apple's Enhanced Security (hardened process and heap,
  read-only dyld state, platform restrictions v2). `--arm64e` additionally builds with pointer authentication.
- **Git hook.** `swift run vmr hooks install` links `.git/hooks/pre-commit` to the built `vmr` binary, which git then
  runs as `pre-commit` (it dispatches on its program name; `vmr hooks pre-commit` is the explicit form). The link
  points at the binary where it was built, so every `swift build` updates the hook with no reinstall; after
  `swift package clean` it dangles and git skips it (with a hint) until you build again. A fresh clone has no binary
  yet: `swift run vmr hooks install` builds one and installs it in a single step. Bypass with `git commit --no-verify`.
- **SwiftPM plugins.** `swift package plugin --list` shows `check`, `analyzers` and `build-app`, thin wrappers that
  forward their arguments to `vmr`. `swift run vmr` stays the primary path, because the plugin sandbox is narrow:
  - `swift package --allow-writing-to-package-directory --allow-network-connections all:443 analyzers [...]` works
    inside the sandbox (downloads and verifies the pinned releases, writes `.tools/`).
  - `swift package --allow-writing-to-package-directory check format` also works inside the sandbox. Every other gate
    step, and `build-app`, cannot: SwiftLint writes a cache outside the package, and `swift build` and `swift test` cannot
    start inside the plugin sandbox (SwiftPM cannot nest its own sandbox), while a nested build would wait forever
    on the lock the outer `swift package` holds on `.build`. Run those as
    `swift package --disable-sandbox --scratch-path .build-plugin check ...` or
    `swift package --disable-sandbox --scratch-path .build-plugin build-app ...`, or simply use `swift run vmr`.

See `CONTRIBUTING.md` for the code rules and `SECURITY.md` for how to report a vulnerability.

## License

MIT, see `LICENSE`.
