---
date: 2026-10-26
question: "What caused the first Windows helper failure, and does disabling performance-monitoring emulation avoid that failure?"
feeds: [roadmap 0015, ADR-0059]
---
# Windows helper failure with performance-monitoring emulation

## Result

On macOS 27.0.1, build **26A434**, a Windows-shaped guest with the private performance-monitoring switch enabled produced an Apple virtualization-helper memory-protection fault. A fresh comparison with the switch disabled remained running for **191 seconds**, then was deliberately stopped. No successful Windows boot was established in either run.

This makes the private capability unsafe to offer on the observed build. Rejecting it before calling the setter or starting a helper is a containment measure, **not a repair to Apple's helper or a claim that Windows now boots**. The comparison does not identify the faulty memory region or prove the private switch is the sole possible cause.

## First run: enabled

Full observations and the separately authorised crash-report investigation are in the [original run report](history/board/realguest-windows-report.md).

- Main commit: `b2e51366afb1d1579604307124cce945950b9fcf`.
- Host: Mac15,12, arm64, macOS 27.0.1 / 26A434.
- Start accepted at 11:30:57 CET. Helper launched at 11:30:57.4095; crash captured at 11:30:58.2854, approximately 0.876 seconds later.
- Helper pid 67947, responsible app pid 67883. The app stayed alive and displayed the generic unexpected-stop alert.
- `EXC_BAD_ACCESS` / `SIGBUS` / `KERN_PROTECTION_FAILURE` on `com.apple.virtualization.thread.cpu-0`, in `_platform_memmove + 424`.
- Fault address `0x105034000` is the start of a 1 MiB shared-memory mapping with current `r--` protection. The exception records a write-permission fault.
- Helper UUID `4A6A588D-1AFD-30F5-A64D-6304EB79BE0B`, version 308.1.7. Its private frame names were not resolved. Read-only UUID-matched disassembly is consistent with a memory-access dispatch path; it does not name the device or region.

## Comparison: disabled

The owner authorised this comparison after the above diagnosis, then requested that the TPM study be paused and the crash addressed. No TPM code, extra private interface, firmware or driver was added.

A fresh detached scratch checkout of the **same commit** built the app with `swift run vmr build-app`, exit 0. It was ad-hoc signed with hardened runtime and the usual virtualization/audio-input entitlements. Build signature verification passed. No second implementation was substituted.

The machine used the same settings: 4 CPUs, 8192 MiB, a fresh 64 GiB sparse NVMe disk, NAT, Apple's 1920×1200 graphics device, USB input and the same read-only installer in place. Nested virtualization, sound and clipboard were off; display did not follow the window. New UUID and fresh EFI variable store/identifier were necessary scratch-run differences.

Only the PMU policy path was changed: the scratch defaults domain had `DisablePrivateInterfaces = 1` and `WindowsStartsWithoutPMU = 1`, alongside `runsControlService = 1`. These are developer controls, not a supported Windows boot fallback.

| Claim | Probe / evidence | Verdict |
|---|---|---|
| Installer matches first run | SHA-256 `8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c` | SEEN |
| Start accepted | `requested=1793011565 answered=1793011566 exit=0 (11:46:06)`; `FF8C7DFE-1898-42AD-828A-D9395470B65E: running` | SEEN |
| PMU was disabled | Notice at 11:46:05.711: `Windows starts without the performance-monitoring emulation (the developer default DisablePrivateInterfaces is on): WindowsStartsWithoutPMU is on` | SEEN |
| Helper stayed alive beyond original fault | App 84574 and helper 84634 alive at T+191 s, `control state` running | SEEN |
| Disk activity | Every sampled allocation 0 KiB; no disk or EFI mtime change | SEEN |
| Helper load | Per-minute CPU means approximately 100%, 100%, 98%, 100%; peak sampled RSS 184448 KiB | SEEN |
| App load | First-minute mean 3%, subsequent means below 1%; peak sampled RSS 171392 KiB | SEEN |
| Repeat crash | No new crash-report filename by the end; the earlier helper report remained newest | NOT SEEN |
| Windows firmware, Boot Manager or Setup | No owner observation supplied at the time this study was written; AX reads the host UI, not guest pixels | NOT SEEN |
| Controlled stop | `control stop --force` at 11:49:17–11:49:18, T+191–192 s; stopped state confirmed | SEEN |
| App/helper cleanup | App ended via its recorded pid; no VMRunner/helper process remained | SEEN |

CPU figures use differences in cumulative process CPU time over roughly 10-second intervals; 100% means one host core. The earlier run's special 300%-for-180-seconds hang criterion was **not met**. One busy core plus no disk writes is consistent with a stalled guest, but is not proof of a Windows boot stage.

The comparison was ended after the first observation interval because it had answered the early-crash question; it did not run for the original 12-minute observation budget. No second full Windows boot attempt or hardware-check workaround was made.

## Cleanup

Scratch prefix `/tmp/vmr-windows-run-1026113927`: data, tools, notes and detached checkout are removed after preserving these observations. The scratch defaults keys are deleted; an empty plist left by the preferences daemon is retained as before. AppKit's newly created temporary savedState folder is removed. No process from the run is left running.

The normal app preferences baseline is 2702 bytes, mtime 1792895605. The original ISO is 8528523264 bytes, mtime 1792890509, mode `-rw-r--r--`; the final stat and SHA-256 are checked against those baselines before scratch removal. Final verification is recorded in the session diary.

## Not verified

- Which shared region or emulated device was written, or the underlying Apple implementation defect.
- Whether another build, host model, firmware or installer behaves the same way.
- A reliable Windows boot with PMU disabled; `hasBooted` records the app's start path, not guest OS success.
- Windows Setup, TPM readiness, storage-driver discovery, measured boot or licensing compliance.
- The TPM feasibility sketch is paused; no TPM implementation is part of this work.

The existing fail-closed capability policy should prevent the known-crashing build from invoking the private switch. A passing selector encoding/read-back probe alone must not override evidence of a runtime failure.
