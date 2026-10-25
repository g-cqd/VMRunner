---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0059
---
# 0015 — Install from any arm64 UEFI ISO; Windows on ARM is experimental

The media section accepts any ISO. Study: `docs/research/windows-on-arm-2026-10.md`.

2026-10-21: the media section said plainly that Windows guests were not supported (ADR-0010).

2026-10-25: ADR-0059 supersedes ADR-0010. Windows on ARM becomes an experimental guest, built on the private capability of
roadmap 0029, with no virtual TPM, no suspend and no custom GPU. Nothing below is built or run yet.

2026-10-25: the Windows preset is in the app, experimental (items 1 to 3): the guest picker lists Windows, the sheet takes a local
installer ISO with an optional expected SHA-256 and a read-only driver disc, the editor shows the rows a Windows machine has, and
the help has a topic for it. No Windows installer has been run (item 4).

## Windows items

1. A guest kind of its own for Windows, with the machine of ADR-0059 item 5: generic platform, EFI, Secure Boot off, NVMe main
   disk, USB keyboard and pointer, virtio network, the PMU capability on. A machine whose capability is unavailable or off
   does not start and says why; the developer default `WindowsStartsWithoutPMU` lets an owner try anyway.
2. The New Machine preset: 4 CPUs, 8 GiB, a 64 GiB sparse disk, NAT, 1920 x 1200, an installer ISO slot (local file, optional
   expected SHA-256) and a read-only driver ISO slot, both attached as USB mass storage.
3. The requirements panel and the help: private interface in use, the fixed no-TPM wording, no suspend, a licence per
   installation, Insider Preview builds expire, a driver disc is needed for the virtio network device.
4. A run against a real Windows installer, by the owner: whether the machine boots with the framework's own display, how far
   Setup gets, and what a first boot shows. Not run. Nothing in this item may alter the installer or what Windows Setup checks.
   The .app display resizer, the uncapped 1920 x 1200 display, the Linux share tag and the generic machine identifier are
   accepted defaults that are unverified on a real Windows guest.

## Not in scope

An answer file, an unattended setup, a changed installer, or any way around what Windows Setup checks. A guest-side display
driver or a firmware shim. Downloads of Windows media or drivers. Acceleration for Windows.
