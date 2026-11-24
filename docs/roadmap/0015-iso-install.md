---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0060
---
# 0015 — Install from any arm64 UEFI ISO; Windows on ARM is experimental

The media section accepts any ISO. Study: `docs/research/windows-on-arm-2026-10.md`.

2026-10-21: the media section said plainly that Windows guests were not supported (ADR-0010).

2026-10-25: ADR-0059 supersedes ADR-0010. Windows on ARM becomes an experimental guest, built on the private capability of
roadmap 0029, with no virtual TPM, no suspend and no custom GPU. Nothing below is built or run yet.

2026-10-25: the Windows preset is in the app, experimental (items 1 to 3): the guest picker lists Windows, the sheet takes a local
installer ISO with an optional expected SHA-256 and a read-only driver disc, the editor shows the rows a Windows machine has, and
the help has a topic for it. No Windows installer has been run (item 4).

2026-10-26: the first installer attempt crashed Apple's helper on build 26A434 with PMU enabled. A same-commit, fresh-machine
comparison with PMU disabled remained running for 191 seconds but established no Windows boot. The
[crash study](../research/windows-pmu-crash-2026-10.md) records both runs. That build's PMU capability is refused before
application; this contains the observed crash path, not the unresolved Windows boot problem. TPM research is paused.

The [development history](../research/development-history-2026-10.md) indexes the imported planning and guest-run evidence.

2026-10-26 continued: a [boot-display investigation](../research/windows-boot-display-2026-10.md) verified the second trap switch,
measured the firmware's Blt-only GOP and tested a disposable RAM-backed replacement. The media EFI entry returned a timeout;
keeping the diagnostic resident avoided its later failure. No Windows screen or successful boot was observed. An owner-observed
media handoff is needed before any production bootstrap or private-capability change; the app guard remains.

2026-10-26 integration: [ADR-0060](../adr/0060-windows-boot-uses-a-bounded-framebuffer-and-a-paired-capability.md) replaces the one-switch/NVMe assumptions after the owner's [WinPE/storage evidence](../research/windows-setup-storage-2026-10.md). The app gains the owned framebuffer boot medium, paired capability, bounded host RAM display, fixed mode and Virtio defaults. Unit/native sanitizer tests cover binary layout, metadata, policy and framebuffer operations. Native app runtime acceptance and completed installation are recorded separately in the next diary, not inferred from the scratch success. TPM remains paused.

## Windows items

1. A Windows guest with generic platform, owned EFI framebuffer bootstrap, Secure Boot off, Virtio main disk, USB input and virtio network. Both checked private switches and the display/media prerequisites are required on the verified build. The legacy diagnostic default cannot relax this path.
2. The New Machine preset: 4 CPUs, 8 GiB, a 64 GiB sparse disk, NAT, 1920 x 1200, an installer ISO slot (local file, optional
   expected SHA-256) and a read-only driver ISO slot, both attached as USB mass storage.
3. The requirements panel and the help: private interface in use, the fixed no-TPM wording, no suspend, a licence per
   installation, Insider Preview builds expire, a driver disc is needed for the virtio network device.
4. A run against a real Windows installer, by the owner: whether the machine boots with the framework's own display, how far
   Setup gets, and what a first boot shows. Scratch WinPE and an online Virtio target were owner-observed; completed installation and installed first boot remain unverified. Native integration needs its own runtime acceptance. Nothing may alter the installer or what Setup checks. The RAM display uses fixed 1920 x 1200; no app-driven guest resizing or acceleration is promised.

## Not in scope

An answer file, an unattended setup, a changed installer, or any way around what Windows Setup checks. A guest-side display
driver. Downloads of Windows media or drivers. Acceleration for Windows. The owned EFI framebuffer bootstrap is now in scope under ADR-0060.
