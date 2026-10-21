# VMRunner

A small SwiftUI app that creates and runs **macOS** and **Linux (CentOS Stream)** virtual machines on Apple
silicon with Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization).
No dependencies beyond the system frameworks.

## Build and run

```sh
Scripts/build-app.sh            # release build -> build/VMRunner.app (ad-hoc signed, hardened runtime)
Scripts/build-app.sh debug      # debug build
open build/VMRunner.app
swift test                      # unit tests
```

The app needs the `com.apple.security.virtualization` entitlement, which the script applies when signing.
`swift run` won't work for the same reason: use the script.

Requires an Apple silicon Mac on macOS 26+. Built with Xcode 27 / Swift 6.

Start a machine from the command line (handy for scripts):

```sh
open build/VMRunner.app --args --start "My VM"     # by name or UUID
```

## What it does

| | macOS guest | Linux guest |
|---|---|---|
| Media | Latest supported image from Apple, any signed build from [ipsw.me](https://ipsw.me), or a local `.ipsw` | Newest CentOS Stream 9/10 aarch64 boot or DVD ISO, or Debian's netboot `mini.iso` (resolved from the project's own server, SHA-256 verified), or a local ISO |
| Boot | `VZMacOSBootLoader`, installed with `VZMacOSInstaller` | UEFI (`VZEFIBootLoader`), installer ISO attached over USB |
| First-boot account | Skips Setup Assistant on macOS 27 guests (`VZMacGuestProvisioningOptions`) | – |
| Extras | Recovery boot, trackpad or mouse | Nested virtualization (M3+), Rosetta for x86_64 binaries, SPICE clipboard, Secure Boot (host macOS 27+) |

Common to both: CPU/memory, sparse disk (grow-only), extra disk images, disk cache/flush mode, one display,
audio in/out, NAT or no network, custom MAC, shared folders (virtiofs), suspend/resume, snapshots,
duplicate, memory balloon / entropy / vsock devices.

Downloads are resumable and verified: IPSW against ipsw.me's SHA-256, ISOs against the checksum the project publishes
next to them. Only HTTPS from a short allowlist of hosts is accepted, and redirects that leave it are refused.

**Linux providers.** Only CentOS Stream and Debian's `mini.iso` are registered. Debian netinst, Alpine, AlmaLinux, Rocky,
Ubuntu Server, and Fedora Server are parsed and tested but unregistered (`LinuxCatalog.candidates`), with their hosts
off the download allowlist, until they are approved. See the discussion of trust below.

**Graphics.** macOS guests use Apple's paravirtual graphics device (drawn by your Mac's GPU through Metal). Linux guests
get a 2D virtio-gpu display with no 3D acceleration, so OpenGL and Vulkan are software-rendered.

### Help

Every setting has a tooltip, a "?" popover with a plain-language explanation (with a "For experienced users"
section), and the **Help** window (Help ▸ VMRunner Help, searchable) covers every feature, its limits, and its trade-offs.
The text lives in `Sources/VMRunner/Help` and is tested for completeness.

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
- **Network egress control** (IP, domain, and URL blocks, and VPN requirements) exists as a tested policy engine
  (`NetworkPolicy`, `VPNMonitor`) but is not enforced on a running machine yet. NAT gives the guest no filtering, and
  the host cannot see a VPN running inside a guest.
- **3D acceleration for Linux guests**: not available through Apple's Virtualization framework.
- **Secure Boot** is implemented for macOS 27+ hosts but couldn't be exercised on the development machine (macOS 26.7).

## Layout

```
Sources/VMRunner
  Model/       VMConfig (Codable settings), Security (profiles, exposure summary), APFS (clone, snapshots),
               Storage (bundle layout, sparse disks), VMLibrary (machines, setup jobs), NetworkPolicy and its rules
  Engine/      ConfigurationBuilder (VMConfig -> VZVirtualMachineConfiguration), Provisioner (media + install),
               VMController (run/pause/suspend/restore, runtime limit), Downloads, Catalogs, LinuxProviders, VPNMonitor
  ViewModels/  MachineModel, ConfigEditorModel, NewMachineModel, SnapshotsModel, ...: the logic behind each screen
  Views/       Thin SwiftUI views; each editor section takes only the fields it shows
  Help/        The help catalog (HelpTopic, one content file per area)
Machines live in ~/Library/Application Support/VMRunner/Machines/<uuid>.vm
```
