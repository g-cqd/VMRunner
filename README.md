# VMRunner

A small SwiftUI app that creates and runs **macOS** and **Linux (CentOS Stream)** virtual machines on Apple
silicon with Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization).
The app has no dependencies beyond the system frameworks; the developer tooling (`vmr`, below) uses two pinned
Apple/Swift packages and is never linked into the app.

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
| Media | Latest supported image from Apple, any signed build from [ipsw.me](https://ipsw.me), or a local `.ipsw` | Newest CentOS Stream 9/10 aarch64 boot or DVD ISO (resolved from `mirror.stream.centos.org`, SHA-256 verified), or a local ISO |
| Boot | `VZMacOSBootLoader`, installed with `VZMacOSInstaller` | UEFI (`VZEFIBootLoader`), installer ISO attached over USB |
| First-boot account | Skips Setup Assistant on macOS 27 guests (`VZMacGuestProvisioningOptions`) | – |
| Extras | Recovery boot, trackpad or mouse | Nested virtualization (M3+), Rosetta for x86_64 binaries, SPICE clipboard, Secure Boot (host macOS 27+) |

Common to both: CPU/memory, sparse disk (grow-only), extra disk images, disk cache/flush mode, 1–2 displays,
audio in/out, NAT or no network, custom MAC, shared folders (virtiofs), suspend/resume, snapshots,
duplicate, memory balloon / entropy / vsock devices.

Downloads are resumable and verified: IPSW against ipsw.me's SHA-256, ISOs against the mirror's `.SHA256SUM`.

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
| Secure Boot (Linux, host macOS 27+) | off | off | **on** | on |
| Disposable disk (changes discarded on stop) | off | off | off | **on** |
| Suspend (writes RAM to disk) | on | on | on | **off** |
| Memory balloon | on | on | on | **off** |
| Auto-login / SSH (macOS first boot) | as set | as set | as set | **off** |
| Runtime limit | none | none | none | **120 min** |

The entropy device is never removed: the guest needs it for randomness.
These settings narrow the host–guest channels. They don't make an untrusted guest safe on their own.

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

## CentOS and CI

- Apple silicon guests are **arm64 only**: you get `aarch64` CentOS Stream. An x86_64 CentOS VM can't run here.
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
Sources/VMRunner
  Model/    VMConfig (Codable settings), Security (profiles, exposure summary), APFS (clone, snapshots),
            Storage (bundle layout, sparse disks), VMLibrary (machines, setup jobs)
  Engine/   ConfigurationBuilder (VMConfig -> VZVirtualMachineConfiguration), Provisioner (media + install),
            VMController (run/pause/suspend/restore, runtime limit), Downloads, Catalogs (ipsw.me, CentOS)
  Views/    ContentView, MachineView (toolbar, display), ConfigEditor, NewMachineSheet (+ Settings)
Machines live in ~/Library/Application Support/VMRunner/Machines/<uuid>.vm
```

## Quality gates and developer tooling

All tooling is Swift: the `vmr` executable (`Sources/vmr`, logic in `Sources/DevTools`) replaced the former shell and
Python scripts. It depends on [swift-subprocess](https://github.com/swiftlang/swift-subprocess) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser), both pinned with `exact:`; the app and its
tests link neither.

```sh
swift run vmr check                          # fast gate: format, swiftlint, build, test, analyzers
swift run vmr check --full                   # + ASan, TSan and UBSan test runs, release build, coverage gate
swift run vmr check test coverage            # only the named steps; --list shows all of them
swift run vmr analyzers [run|install|baseline|versions|pins] [arcleak|dolly|deadwood...]
swift run vmr build-app [debug|release] [--hardened] [--arm64e]
swift run vmr sarif arcleak.sarif ...        # readable findings from SARIF files
swift run vmr hooks install                  # pre-commit hook: format lint and SwiftLint on staged Swift files
```

Every step runs even if one fails; each prints PASS or FAIL and `vmr check` exits non-zero if any failed. CI
(`.github/workflows/ci.yml`) calls the same commands, so local and CI results match. Per-repository settings (lint
paths, coverage bundles, the coverage floor, test targets left out of sanitizer and coverage runs) live in
`.vmr.json`; `swift run vmr <command> --help` documents every option.

- **Coverage** is measured on the logic layer only (Views, `VMRunnerApp`, `VMController`, `Provisioner` and
  `ConfigurationBuilder` need a display and the virtualization entitlement, so unit tests can't reach them).
  `COVERAGE_MIN` (default 55, set in `.vmr.json`) is a ratchet: it only goes up as coverage does (about 60% when introduced).
- **Analyzers** are the pinned, checksum-verified releases listed in `Scripts/analyzers.lock`, run by
  `vmr analyzers` (binaries land in the git-ignored `.tools/`; the SHA-256 of each archive is checked against the
  lock, not against the release's own checksum file, before anything is unpacked or run):
  [arcleak](https://github.com/g-cqd/arcleak) (retain cycles, anchor leaks, premature releases; any finding
  fails), [dolly](https://github.com/g-cqd/dolly) (duplicate code; exact clones fail, near and structural clones
  are advisory) and [deadwood](https://github.com/g-cqd/deadwood) (unused and dead code, production mode; any
  finding fails). Configuration: `.arcleak.json`, `.dolly.json`, `.deadwood.json`. Existing findings can be
  accepted into the `.arcleak-baseline.json`, `.dolly-baseline.json` and
  `.deadwood-baseline.json` with `vmr analyzers baseline arcleak dolly deadwood`, so only new ones fail. Accept an intentional
  finding in source with `// @al:accept -- reason`,
  `// @dl:accept -- reason` or `// @dw:accept -- reason`. `vmr analyzers pins` checks that the CI workflows pin
  the same releases as the lock.
- **CI** on GitHub Actions: lint, build and unit tests, app bundle checks, sanitizers, coverage, analyzers,
  CodeQL, and workflow linting (actionlint, zizmor). Actions are pinned to full commit SHAs and Dependabot keeps
  them current. Hosted runners can't run nested VMs, so CI never starts a virtual machine.
- **Hardened build.** `vmr build-app` verifies the signature, reads the effective entitlements back and
  fails on `get-task-allow` or any unexpected entitlement. `vmr build-app release --hardened` signs with
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
