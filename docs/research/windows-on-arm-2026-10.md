---
date: 2026-10-21
question: "Can Windows on ARM run under Virtualization.framework?"
feeds: [roadmap 0015, ADR-0010]
---
# Windows 11 on ARM under Virtualization.framework

**Status: investigated, not implemented.** It can be made to work, but only through undocumented API and a lot of
scaffolding. It is not a good fit for a supported feature today.

## Verdict

- No public API supports Windows guests. Apple describes the framework as running "macOS and Linux-based operating
  systems". The macOS 27 headers never mention Windows, TPM, or PMU.
- One unofficial fork shows it working: `mustafaakin/tart`, branch `windows-guest-extras` (announced 1 Oct 2026, tested
  on macOS 26.6 and 27 on an M4 Pro). It is single-author and AI-assisted, ~1,900 lines, and not accepted upstream.
  Upstream Tart marked Windows "Not possible at the moment" ([issue 1123](https://github.com/openai/tart/issues/1123)).
  UTM's Apple backend, Lume, and VirtualBuddy do not ship it; UTM sends Windows through QEMU.
- **The blocker is not the TPM.** Windows does not boot without PMU emulation, which VZ only exposes through a private
  selector (`_setPerformanceMonitoringUnitEmulationEnabled:` on `VZGenericPlatformConfiguration`), and Windows Boot
  Manager needs a linear UEFI framebuffer that Apple's firmware does not provide.
- **Recommendation:** experimental and opt-in at most, off by default, failing closed if the private selector is
  missing. Not suitable for a Mac App Store build (guideline 2.5.1: public APIs only).

## What Windows needs that VZ does not give

| Need | What the fork does (verified in its source) |
|---|---|
| PMU | Calls the private setter; without it one vCPU spins at 100% and Windows never boots. |
| UEFI framebuffer | Ships a small EFI driver that backs the GOP with reserved RAM, loaded by a tiny `BOOTAA64.EFI` shim. |
| TPM 2.0 | VZ has no vTPM. Setup hard-blocks, and even after a registry bypass failed ("0x8007000e"). The fork skips Setup: a WinPE script applies the image with DISM and runs `bcdboot`. |
| Storage / network / display drivers | virtio-win ARM64 drivers (`viostor`, `NetKVM`, `viogpudo`, `viorng`, `viofs`), pinned by hash, injected with DISM. |
| Install media | A custom GPT disk holding the ISO contents, drivers, and scripts, attached as USB. A stock ISO as USB media is unverified. |
| OOBE | An answer file (local account, auto-logon) instead of the interactive flow; `oobe\bypassnro` behaviour varies by build. |

virtio-win drivers are Microsoft *attestation*-signed, not WHQL-signed (WHQL needs a paid RHEL subscription). Audio has
no driver. Nested virtualization hangs. There is no suspend. Display is display-only, with no GPU acceleration.

## Licensing

- Microsoft's own page hosts the Arm64 ISO ([download](https://www.microsoft.com/en-us/software-download/windows11arm64),
  [docs](https://learn.microsoft.com/en-us/windows/arm/iso)); the link expires in 24 hours, so an app should let the user
  download it and pick the file.
- Microsoft lists Parallels as the authorised Mac solution and requires a licence per instance. Running under VZ is
  unsupported by Apple and Microsoft. The app must not redistribute the ISO or automate activation workarounds, and
  should say a no-TPM guest is outside Microsoft's requirements.

## Performance (the fork author's single-machine numbers, unreplicated)

CPU about 90–93% of host (similar to QEMU with hvf); disk 0.9–1.1 GB/s with flush-every-write; boot 7–9 s; install about
12 minutes. No measurements of x64 emulation under VZ were found.

## What a first slice would be

A Windows platform type that refuses to start without the private selector; "Create from ISO" validating the ISO
(`efi/boot/bootaa64.efi`, `sources/install.wim` or `install.esd`), building the install media, running the unattended
install with a random local password; run with virtio-blk, NAT, virtio-gpu, USB input, and entropy only. Defer the guest
agent, shared folders, audio, resizing, and snapshots.

## Not verified

Whether the private selectors work on macOS 26.7 (the fork was tested on 26.6 and 27); a stock ISO booting as USB media;
dynamic resolution; time sync; Windows Update on a no-TPM DISM-applied image; whether `NVMe` (inbox driver) could replace
`viostor`; Secure Boot's final state in the fork.

Sources: the fork's source and [write-up](https://mustafaakin.dev/blog/windows-on-tart/), Tart issue 1123, the
virtio-win [package scripts](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md),
[UTM's Windows guide](https://docs.getutm.app/guides/windows/), Microsoft's
[Mac options page](https://support.microsoft.com/windows/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips-cd15fd62-9b34-4b78-b0bc-121baa3c568c).
