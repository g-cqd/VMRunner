---
date: 2026-10-26
question: "Can the Windows media boot path be made usable without changing the installer or its hardware checks?"
feeds: [roadmap 0015, ADR-0059]
---
# Windows boot: trap emulation, a real framebuffer and media handoff

**Historical status after the initial probes: boot remained unverified.** The [follow-up Setup/storage study](windows-setup-storage-2026-10.md) records later owner-observed Windows startup and a visible Virtio target; the results below describe the earlier six runs only. The app's known-crashing PMU guard remains in place. Nothing in this study changes the Windows ISO, Setup requirements, TPM support, or production private-API scope.

This follows the [first crash comparison](windows-pmu-crash-2026-10.md) and [firmware/display design](windows-framebuffer-shim-2026-10.md). The owner explicitly asked to fix Windows boot rather than stop at crash containment. Their previously authorised 4 CPU / 8192 MiB / 64 GiB sparse-disk exception and read-only ISO reference were retained. Each real probe was disposable, used no existing user machine, generated no keys/clicks and captured no screen.

## Newly established facts

| Claim | Evidence | Verdict |
|---|---|---|
| The reported implementation enables a second switch | Pinned source revision `e4c623c3fa1f81f9f9befc6cdc16f54b86b6ef47`, platform source: fine-grained trap emulation alongside PMU | READ, not proof of a boot here |
| The second switch has the expected Boolean ABI | `_setFineGrainedTrapsEmulationEnabled:` is `v20@0:8B16`; `_fineGrainTrapsEmulationEnabled` is `B16@0:8`; true reads back, original false restored | SEEN in a no-VM contract probe |
| Enabling both switches alone is insufficient | Same early read-only shared-memory write fault in helper 98406, about 0.881 s after launch | SEEN |
| No-installer EFI control avoids that early fault | A fresh paired-switch configuration without the ISO stopped normally | SEEN; no Windows involved |
| Apple's actual GOP is Blt-only on this host | Guest diagnostic stage 3 records PixelFormat 3; stage 4 records 1920×1200 | SEEN from scratch EFI variables |
| The replacement framebuffer and protocol proxies installed | Stages 5–8: reserved RAM at `0x26d850000`, two proxy installations, timer setup | SEEN, EFI checkpoint evidence |
| The installer EFI entry was loaded and called | Stages 11–12, selected `\EFI\BOOT\BOOTAA64.EFI` on the other volume | SEEN |
| That call returned a timeout | Stage 13 records `0x8000000000000012` (`EFI_TIMEOUT`) | SEEN |
| The media likely waits for a boot key | Entry is the media boot file; return follows roughly eight seconds | INFERRED; no owner saw/reported the prompt |
| Direct boot-manager paths are not available on the exposed filesystem | Guest root listing contains only `EFI`; the Microsoft Boot subdirectory was not opened; root bootmgr, bootmgfw and cdboot_noprompt candidates did not load | SEEN, restricted to exposed EFI filesystem |
| Remaining resident after return avoids the later diagnostic failure | Two longer resident probes ran to the host stop, without a new helper crash | SEEN; not proof of Windows boot |
| Windows Boot Manager screen, WinPE or Setup | No owner observation supplied | NOT SEEN |

The pinned platform source was read from `https://github.com/mustafaakin/tart` at the revision above. Its FSL licence is not treated as permission to copy that implementation into the app. This probe uses independently written code and the standard UEFI interfaces from pinned BSD-licensed headers.

## What ran

Host: Mac15,12 / arm64, macOS 27.0.1 / 26A434, virtualization helper 308.1.7. Production remained at `d9df0c3`; the standalone probes did not remove or bypass the production guard for an ordinary app start.

The signed scratch runner used the same 4 CPUs, 8192 MiB, fresh 64 GiB sparse NVMe disk, generic EFI platform, 1920×1200 Apple graphics, USB input and NAT. Entropy, balloon and socket devices matched the ordinary configuration. Bootstrap runs added an owned read-only boot disk and a diagnostic serial port; the serial output remained empty. Both private Boolean calls were guarded by exact class/method/type checks and read-back. They were not added to production code.

| Run (CET) | Changes and result |
|---|---|
| 12:07:57 | Both switches, stock ISO, no bootstrap: helper fault at 12:07:58; same EXC_BAD_ACCESS/SIGBUS write into a read-only 1 MiB mapping as the earlier app run |
| 12:08:59 | Firmware-only control, no ISO: normal guest stop around 12:09:00 |
| 12:15:57 | Initial bootstrap disk with a Microsoft Basic Data partition rather than an ESP: later EXC_BREAKPOINT around 12:16:07. Entry execution was not instrumented, so do not infer the shim ran |
| 12:21:59 | Proper EFI System Partition and persistent diagnostic checkpoints: replacement GOP installed; installer entry returned EFI_TIMEOUT; later helper EXC_BREAKPOINT after returning from the diagnostic application |
| 12:24:39 | Resident-on-return correction: loader candidates absent except BOOTAA64; EFI_TIMEOUT; stayed running until stop at 12:27:49 |
| 12:29:47 | Added bounded guest directory listing and the standard no-prompt candidate: same timeout and no-prompt file unavailable; stayed running until stop at 12:32:55 |

The later breakpoint stack led through a helper fatal/unimplemented instruction path, not the original memmove protection fault. Returning an EFI application while installed protocols/timers still point into its image is an invalid lifetime pattern; the resident correction removes that pattern. That is a diagnostic-code correction, **not** a finding that the original app had that lifetime bug. Private symbols were unavailable; interpretation of the fatal stack used UUID-matched read-only disassembly.

The runner's nominal 180-second repeated timer drifted to roughly 188–190 seconds on the longer probes; a separate 240-second recorded-pid backstop was armed for each. Only one VM ran at a time, and no hard backstop fired. Every machine and its firmware variables were fresh.

## Bootstrap design and verified bounds

The standalone UEFI application replaces the discovered GOP interfaces with proxies advertising a real reserved-RAM BGR framebuffer, a single bounded mode and conservative Blt operations. A boot-services timer forwards changed rows to Apple's original Blt-only device. It stops forwarding at ExitBootServices. It then loads a file from the other EFI filesystem using normal EFI image-loading services. It does not edit or generate Windows setup files, installer contents, hardware-check settings or input events.

A first host-generated FAT disk used the wrong GPT partition type. The corrected prototype creates a protective MBR, primary/backup GPT headers with CRCs, an **EFI System Partition** and FAT16 containing `EFI/BOOT/BOOTAA64.EFI`. A host read-only mount and `cmp` verified the file bytes. The original Windows ISO was never mounted or copied.

The final tested 9216-byte EFI image rebuilt byte-for-byte from the archived source and pinned headers: SHA-256 `7fef045bcc3d0b3ec72353ee5c95f3684b824986e96af854dfda86e484c90d7e`.

[Sources, pin/checksums, stage records and host logs](history/windows-boot-probe/README.md) are retained as historical research text, not executable app resources. The follow-up timeout-retry variant compiled with warnings-as-errors but **was not run**. It only reloads the media entry after a timeout; it does not synthesize input.

## What is still required

1. An owner-observed run of the retry probe. The owner brings the diagnostic window forward and may press a key **if the actual media asks**. No agent input is permitted. The owner reports the exact screen and any error; an EFI timeout is not a screenshot or proof of the prompt.
2. Establish the furthest actual Windows stage and what happens after ExitBootServices. Forwarding to the Blt-only device ends then, so this bootstrap alone does **not** establish a usable Windows desktop or even a live Setup display.
3. If a real boot is demonstrated, review a production boot/display design, its dependencies and private capabilities before integrating it. Do not merely clear the known-unsafe-build guard because a selector probe passed.
4. Bounds and lifecycle tests for any firmware/image generator adopted into developer tooling. None of the scratch C or Python is proposed as reviewed production code.

No successful boot, installer compatibility, TPM readiness or workaround of Windows Setup's checks is claimed. TPM work remains paused.

## Cleanup

Probe sources and small logs/checkpoints were preserved in the research archive; raw firmware binaries, images, complete EFI stores, downloaded headers and scratch executables are removed. The normal app preferences remained 2702 bytes with mtime 1792895605. The ISO's size, mode, mtime and SHA-256 are rechecked before removal of scratch artifacts. The new helper crash reports remain system-owned evidence; none was deleted. Final cleanup and checks are recorded in the session diary.
