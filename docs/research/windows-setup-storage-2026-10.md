---
date: 2026-10-26
question: "Can the framebuffer bootstrap reach visible Windows Setup and expose a compatible installation target?"
feeds: [roadmap 0015, ADR-0059]
---
# Windows Setup: live display and a visible Virtio target

**Disposable probe only, not a production app fix.** The owner observed Windows start and supplied screenshots of WinPE device/disk enumeration. Windows sees the temporary 64 GiB target. No installation completed; Setup's refreshed drive list, installed Windows, TPM readiness and graphics acceleration remain unverified. The production PMU guard is unchanged. TPM work remains paused.

This follows the [initial boot/display probes](windows-boot-display-2026-10.md). The independently written EFI bootstrap, both measured private switches and original read-only Windows ISO were used in bounded standalone diagnostics, not an ordinary VMRunner start. The owner controlled the guest and supplied screenshots; the agent generated no input, foreground activation or screen captures. Neither the installer nor its hardware checks was changed.

## Evidence and limits

| Claim | Evidence | Verdict |
|---|---|---|
| Windows logo appeared | Owner report during the 13:19 observation run | Owner-observed, not inferred from EFI checkpoints |
| Windows installation UI began | Owner's 13:32 report: "windows installation seems to be starting"; later report of no drive to install on | Owner-observed; no installation claimed |
| Display continues beyond boot-services forwarding | Host RAM mirror activated; owner used WinPE commands and supplied later screenshots | Observed in this diagnostic path |
| Initial NVMe target was absent from the owner's Setup list | Owner report in the 13:26 run | Observed symptom; NVMe root cause not established |
| Early storage enumeration lacked the Virtio controller | Owner's 14:24 SCSIAdapter screenshot showed only Storage Spaces | A point-in-time observation, superseded by later PCI enumeration |
| Virtio block enumerates and has a started driver | Owner's 14:31:08 PCI screenshot: `PCI\VEN_1AF4&DEV_1042`, Red Hat VirtIO SCSI controller, SCSIAdapter, **Started**, `oem0.inf` | Observed; a block device can have a SCSIAdapter-class Windows driver |
| Windows sees the target disk | Owner's 14:31:41 DiskPart screenshot: Disk 3 **Online**, **64 GB**, **64 GB free** | Observed; not proof of installation or a refreshed Setup drive list |
| Driver package is incompatible | Earlier owner report of the Load Driver UI versus the later started controller and visible disk | Cannot sustain a blanket incompatibility diagnosis; exact loading mechanism/timing unresolved |
| Other Virtio devices lack drivers | PCI screenshots show problem code 28 for network, balloon/entropy/socket-related devices, observer `1AF4:10BF` and display `1AF4:1050` | Observed; not evidence that storage is still absent |

Screenshots were read from the owner's supplied Desktop files, not captured by the agent or copied into Git. Relevant names are `Screenshot 2026-10-26 at 14.24.39.png`, `14.31.08.png`, `14.31.19.png` and `14.31.41.png` (each with the same date/name prefix). The [archive](history/windows-setup-storage/README.md) retains textual observations and exact diagnostic sources/logs.

## Display mechanism

Apple's firmware GOP remains Blt-only. The EFI bootstrap publishes a reserved-RAM BGR framebuffer; its forwarding timer ends at ExitBootServices. A host-side custom Virtio observer permits public `guestMemoryMapping(atPhysicalAddress:length:)` access to that framebuffer without a Windows driver for the observer. The host copies only the bounded framebuffer into an in-memory image over the normal virtualization view; it saves no frame files. The underlying view retains owner keyboard/mouse handling.

The latest mirror accepts only 640–1920 by 480–1200 pixels, checks address overflow and mapping length, caps firmware-variable reads at 1 MiB and retains no mapping across updates. Polling was increased from approximately 5 Hz to a **target** of 15 Hz. This is not a measured 15 fps rendering rate or GPU acceleration. The owner reported poor responsiveness earlier; smoothness remains an acceptance item. The final run logged 2125 changed frames, not a benchmark.

This remains unsafe scratch research code: it is not compiled with the app's strict-memory-safety rules and has no production lifecycle, hostile-metadata, firmware-parser or image-generator regression coverage. The archival source must not simply be copied into the app.

## Storage and driver provenance

The final run used 4 CPUs, 8192 MiB and a fresh sparse 64 GiB **Virtio block** target. Bootstrap, original installer and driver media were USB mass-storage attachments; media were read-only. DiskPart listed 33 MB bootstrap, 8133 MB installer, 32 MB driver medium and 64 GB target. Never identify the intended target solely by a persistent disk number: Disk 3 was this run's enumeration.

The driver came from Fedora's `virtio-win-0.1.302-1/virtio-win-0.1.302.iso`, 877373440 bytes, SHA-256 `303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d`. The full ISO was verified in the earlier experiment. The final fetch used bounded HTTP ranges for the three files and checked them against the earlier full-image-derived hashes. Sources and individual hashes are archived; no third-party driver binaries or ISO are committed.

The package is `viostor/w11/ARM64`, version `07/22/2026,100.103.104.30200`, PE machine `0xaa64`. Its INF matches both `PCI\VEN_1AF4&DEV_1001` and `PCI\VEN_1AF4&DEV_1042`. The catalog's certificates include Microsoft Windows Hardware Compatibility Publisher; certificate inspection alone does not prove Windows trust. The Windows screenshot establishes a started driver named `oem0.inf`, not a dump/hash of its installed files.

The 32 MiB `VMRDRIVERS` FAT medium contained both `viostor\w11\ARM64` and `$WinPEDriver$\viostor`. Automatic loading from the latter is documented for Server, not assumed for this Client image. The screenshots do not establish whether discovery, an owner Load Driver action or another installation phase bound the driver. Compatibility filtering was not disabled by the agent, and no driver was force-loaded by the agent. `findstr` was absent in this WinPE; the useful owner-run commands were unfiltered `pnputil /enum-devices /bus PCI` and `diskpart` / `list disk` / `exit`.

## Lifecycle and next work

The final diagnostic ran from **14:21:20 to 14:36:21 CET**, stopped at its 900-second limit and had an independent 930-second supervisor cap. Only one VM ran at a time. The supervisor preserved small source/log/checkpoint notes, then removed executables, sparse target, driver/bootstrap disks, downloaded headers and EFI stores. No helper or scratch mount remained at the post-run check. The archive includes before/after ISO hashes and file metadata and preference metadata; each pair matches. Preferences remained 2702 bytes / mtime 1792895605. The ISO's SHA-256 remains `8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c`.

Next: review a production boot/display integration and compound private-capability decision, with memory/lifetime tests, then adopt an explicitly verified storage/driver flow. Keep the known-unsafe standalone PMU guard intact. Do not infer that changing the default storage device alone fixes the app's boot path. Confirm Setup's drive list separately and use persistent owner-authorised storage only for a later actual installation. No additional guest run is needed merely to repeat this established DiskPart result.
