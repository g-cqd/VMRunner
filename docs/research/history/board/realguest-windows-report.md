# Real-guest run: a Windows machine in the app — 2026-10-26

Seen means output, files, Accessibility text, or an owner-supplied image from this run. Inferred means interpretation. No agent screen capture or input was used.

## 0. Summary

The app accepted a Windows start with performance-monitoring emulation enabled at 11:30:57 CET, then the guest stopped unexpectedly within seconds.
A framework helper crash-report filename appeared; the app itself remained alive.
The owner supplied a screenshot of the same error observed through Accessibility.
Windows Boot Manager, Setup and NVMe visibility were NOT SEEN.
The run stopped under its unexpected-error condition; the two remaining configurations were NOT RUN.

## 1. Host and inputs

| Claim | Observation | Basis | Verdict |
|---|---|---|---|
| Host | macOS 27.0.1, build 26A434, arm64, Mac15,12; preflight 11:25:47 CET | SEEN | YES |
| Build is in registry range | 26A434 is within 26A0…26Z99999 | INFERRED from host build and registry range | YES |
| Commit built | Detached worktree from main, b2e51366afb1d1579604307124cce945950b9fcf | SEEN | YES |
| Build succeeded | One `swift run vmr build-app`, exit 0; nested runner release build reported 141.19 s, app release build 37.94 s (not total wall time) | SEEN | YES |
| Signature | `flags=0x10002(adhoc,runtime)`, arm64; identifier `com.example.VMRunner`; virtualization and audio-input entitlements | SEEN | YES |
| Free space | Preflight 95 GiB available; after preparation approximately 93 GiB | SEEN | YES |
| No existing app or run | No VMRunner process and no previous `/tmp/vmr-windows-run*` paths at preflight | SEEN | YES |
| Policy | Neither AllowPrivateInterfaces nor AllowControlService key existed; no matching managed-preference filename was printed | SEEN | YES |
| ISO | `~/Downloads/Windows11_Client_arm64_en-us_26300_9457.iso`, 8528523264 bytes, mode `-rw-r--r--`, mtime 1792890509 | SEEN | YES |
| SHA-256 before and after | Expected and both observed values: `8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c` | SEEN | YES |
| ISO unchanged | Size, mtime and mode matched before/after; referenced read-only in place; no copy or mount performed | SEEN | YES |
| New Machine supports Windows | `newMachineChoices: [Self] = [.macOS, .linux, .windows]` | SEEN in built source | YES |
| Fact checks | Counts in order: WindowsStartsWithoutPMU 4; DisablePrivateInterfaces 2; which is unavailable 1; Windows starts without 1; runsControlService 1; approvals.json 1; guest cases 1; installerName 1 | SEEN | YES |
| Accessibility | Helper returned true for trusted; deliberately passing the shell pid returned refusal exit 77 before any AX call | SEEN | YES |

### Owner authorisation

After being told the run requires booting their Windows ISO with **4 CPUs, 8 GiB RAM and a 64 GiB sparse disk** while observing the window, the owner replied:

> i'm fully okay with that, i have an iso in the downloads folder

Recorded at the 2026-10-26 11:25:47 CET preflight. After being asked to delete only an existing empty scratch preferences domain, the owner replied:

> go ahead

The 42-byte scratch-domain plist dated 2026-10-25 contained `{}`. `defaults delete` reported domain not found while `defaults read` continued returning `{}`. After confirming the empty file with plutil, the agent removed that file under this explicit approval. A subsequent defaults read reported domain not found. The normal preferences were not removed.

### Temporary machines

Both were created before first app launch, using the app's framework calls to make real EFI variable stores and generic machine identifiers. The app then generated `Machines.approvals.json` without an approval prompt. No driver disc was attached.

| Name | UUID | Disk apparent / allocated before launch |
|---|---|---|
| win-a | 85F19797-F39C-41D0-991C-D777F828FB04 | 68719476736 bytes / 0 KiB |
| win-b | 63EE6E52-1FC2-43C1-8175-7855BE48BFDB | 68719476736 bytes / 0 KiB |

Both configs: Windows, provisioned, 4 CPUs, memoryMiB 8192, diskGiB 64, NVMe, NAT, 1920×1200, fitsWindowAtStart false, automaticallyReconfiguresDisplay false, mouse pointer, audioOutput false, sharesClipboard false, maxRuntimeMinutes 15, installerISO the path above, installerAttached true, agentAccess true. Folder UUIDs matched config ids. EFI stores were 131072 bytes; identifiers 70 bytes. No custom GPU, driver disc, Secure Boot, serial console or provisioning spec was supplied.

Scratch domain: `com.example.VMRunner.data-directory-override`, with only `runsControlService = 1`. Neither developer override was set. Token capabilities were list/start/state/stop; the secret was never printed or included here.

## 2. Sub-runs

| Claim | A — emulation enabled | B1 — kill switch | B2 — developer override | Basis |
|---|---|---|---|---|
| Launch | App pid 67883; 11:30:53 CET; socket ready | NOT RUN | NOT RUN | SEEN |
| Initial list | Both machines stopped, listed as Windows (CLI column truncated to `windo`) | NOT SEEN | NOT SEEN | SEEN |
| Start timing | `requested=1793010657 answered=1793010657 exit=0 (11:30:57)` | NOT SEEN | NOT SEEN | SEEN |
| Start output | `85F19797-F39C-41D0-991C-D777F828FB04: running` | NOT SEEN | NOT SEEN | SEEN |
| Capability error | None returned on start; no starts-without-emulation notice | NOT SEEN | NOT SEEN | SEEN |
| Guest helper | pid 67947, `/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/…` | NOT SEEN | NOT SEEN | SEEN |
| Subsequent state | At 11:31:10, T+13 s: `win-a (85F19797-F39C-41D0-991C-D777F828FB04): stopped` | NOT SEEN | NOT SEEN | SEEN |
| Error | `The virtual machine stopped: Internal Virtualization error. The virtual machine stopped unexpectedly.` | NOT SEEN | NOT SEEN | SEEN, AX and owner image |
| App stability | Alive after error; terminated by recorded pid during cleanup | NOT SEEN | NOT SEEN | SEEN |
| Framework crash report | New filename `com.apple.Virtualization.VirtualMachine-2026-10-26-113110.ips`; contents not read | NOT SEEN | NOT SEEN | SEEN |
| Reached Windows Setup | NOT SEEN | NOT SEEN | NOT SEEN | SEEN evidence does not establish a boot stage |

Display log at 11:30:57.232:

> Starting display 1920×1200 px for a window of 720×600 pt; host screen scale 2.0, guest pixels per point 1.000000; source fixed size, width cap does not apply, remembered size none; match window false, follows window false, restoring false

The rewritten config had `hasBooted: true`, lastDisplayWidth 1920, lastDisplayHeight 1200. This establishes that the app completed its start path, **not** that Windows booted successfully.

The helper was already absent at the first post-start sample (T+6 s), so its runtime CPU and peak RSS were NOT SEEN. The exact failure instant is not established. Three app CPU intervals averaged 7%, maximum 17%; peak sampled app RSS 156208 KiB. No ≥300% streak was measured; the card's 180-second hang criterion was not met. This was an early unexpected stop, not an observed long-running hang.

Disk samples before start and at T+26 s showed 0 KiB allocated, apparent size 68719476736, unchanged disk mtime 1793010556. EFI store size 131072 and mtime 1793010556 were also unchanged. Windows disk writes were NOT SEEN.

No app-subsystem error/fault line was returned by log show. App stdout included `sandbox_extension_issue_file_to_process failed ... Operation not permitted`; its causal relevance is NOT ESTABLISHED. A later framework helper crash filename is evidence of a helper failure, not an explanation of its cause.

## 3. Owner observation

The owner supplied `~/Desktop/screenshot.png`. The agent read that supplied file; it did not take a screenshot or copy the image. The file name suggests T+6 s, but the actual capture time was not independently verified.

The image shows the app's “Virtual Machine Error” alert with exactly the error quoted above. No guest firmware or Windows UI is visible. No owner keystrokes were reported. The planned 2–3 minute and 8–9 minute looks were cancelled after the unexpected error; both are NOT SEEN.

## 4. Findings

- **Start API:** YES, the framework accepted start with PMU emulation enabled; sustained Windows execution was NOT SEEN.
- **Kill-switch error:** NOT SEEN; B1 was not run.
- **Without PMU comparison:** NOT SEEN; B2 was not run.
- **Windows boot stage, NVMe disk in Setup, hardware requirements:** NOT SEEN.
- **Failure:** An early unexpected guest stop and a new framework helper crash-report filename; the app remained alive.
- **Cause:** NOT ESTABLISHED. Reading the helper crash report in a separate diagnostic investigation would be a next step; this run intentionally read only report filenames.
- No attempt was made to work around installer requirements, change configurations, or retry a failed guest.

## 5. Deviations

- The owner authorised removal of the pre-existing empty scratch preferences file before the run resumed.
- The env and Swift/shell/config files were created with the Write tool. A small preparation build/hash wrapper and an observation wrapper were added to run the prescribed work in the background; the observer was terminated by its recorded pid on the unexpected error.
- The observation wrapper was started before the initial AX collection exposed the already-stopped guest, then stopped immediately after that finding. No scheduled look was reached.
- The owner voluntarily supplied an image; only that supplied file was read, with no agent capture.
- The unexpected-error stop condition ended the card after A; B1 and B2 were not attempted.
- AppKit created a new temporary savedState folder despite restoration being disabled. It did not exist at baseline and was removed as a run-created artifact.

## 6. Cleanup

All recorded app, helper, sampler, watchdog, logstream and observer pids were absent after cleanup; no remaining scratch script process or framework guest process was found. The app was ended via its recorded pid, with no GUI interaction.

The scratch defaults domain was deleted. The daemon left an empty 42-byte plist at `~/Library/Preferences/com.example.VMRunner.data-directory-override.plist`; as prescribed by the run, this post-run empty file was left in place.

The owner's normal preferences remained **2702 bytes, mtime 1792895605**, exactly matching baseline. The ISO's final size, mtime, mode and SHA-256 matched baseline. No ISO was mounted.

Removed run-created paths after preserving this report:
- `/tmp/vmr-windows-run-1026112646`
- `/tmp/vmr-windows-run-1026112646-tools`
- `/tmp/vmr-windows-run-1026112646-notes`
- detached worktree `/tmp/vmr-windows-run-1026112646-src`
- `/tmp/vmr-windows-run.env`
- new `/var/folders/_l/mtv6k9m15890t4m22sqh77_00000gn/T/com.example.VMRunner.savedState`

Final verification: no `/tmp/vmr-windows-run*` paths remain; git worktree list shows only main at b2e5136; git status remains only the pre-existing untracked `.vscode/`; no VMRunner or framework guest processes remain; the new savedState folder is absent; normal preference size/mtime still match; free space is back to 95 GiB. Kept: this report, the owner's unchanged ISO and supplied screenshot, the system-generated helper crash report, and the empty scratch preferences plist. No source files or commits were changed.

## 7. Previously unknown observations

N1: The guest used a new framework helper process. N2: Host build is in range. N3: Firmware/installer behaviour NOT SEEN. N4: No Downloads permission prompt was observed. N5: Successful start output recorded; failure formatting NOT SEEN. N6: Accessibility available. N7: New Machine offers Windows. N8: CPU use computed from cumulative process CPU times; helper samples missed its brief lifetime.

## 8. Authorised post-run crash investigation — 2026-10-26

After the agent proposed inspecting the helper crash report without another boot, the owner replied “go ahead”. Only this later investigation read the crash report's contents. The preceding run's statements about reading filenames only describe that earlier phase.

### Direct evidence

Source: `~/Library/Logs/DiagnosticReports/com.apple.Virtualization.VirtualMachine-2026-10-26-113110.ips`.

| Finding | Evidence | Basis |
|---|---|---|
| Correct helper and parent app | pid 67947; responsiblePid 67883, responsibleProc VMRunner | SEEN |
| Framework version | Virtualization helper 308.1.7, macOS 27.0.1 (26A434) | SEEN |
| Precise timing | procLaunch `11:30:57.4095`; captureTime `11:30:58.2854` (+0100) | SEEN |
| Lifetime until crash capture | Approximately 0.876 seconds; the report filename's 11:31:10 is later than captureTime | INFERRED from timestamps |
| Failure | `EXC_BAD_ACCESS`, `SIGBUS`, `KERN_PROTECTION_FAILURE at 0x0000000105034000` | SEEN |
| Destination mapping | `0x105034000–0x105134000`, 1024 KiB shared memory, current protection `r--`, maximum `rwx` | SEEN |
| Faulting instruction/thread | `_platform_memmove + 424`; `com.apple.virtualization.thread.cpu-0`; ESR description `(Data Abort) byte write Permission fault`; FAR equals the first byte of the read-only mapping | SEEN |
| Other vCPUs | cpu-1, cpu-2 and cpu-3 are waiting in `_pthread_cond_wait` | SEEN |

The helper attempted a host memory write to a mapped region that was not writable. This is not an installer dialog or a guest-reported hardware-requirement error. The observed fault is in Apple's helper process; that fact alone does not prove whether the trigger is a framework bug, the experimental configuration, guest behaviour, or an interaction between them.

### Static comparison and limits

The installed helper's arm64e UUID from dwarfdump matches the crash image: `4A6A588D-1AFD-30F5-A64D-6304EB79BE0B`. An atos attempt did not resolve the helper's private frames. UUID-matched arm64e disassembly was then examined read-only with llvm-objdump.

Helper return offsets on the faulting stack: `0x3d2738`, `0x3cffb4`, `0x3b7054`, `0x28e734`, `0xb1580`, `0xb1f78`. The first is immediately after an indirect call in a bounded memory-access loop; the next walks address ranges and dispatches the access to that loop. The higher caller is in guest CPU instruction-handling code. These descriptions are **INFERRED from assembly**, not recovered private function names. No available symbol identifies the region as firmware, framebuffer, installer, or disk memory. Its 1 MiB size is not enough to identify it.

Production source comparison: the Windows builder creates a generic platform, applies the guarded PMU capability, uses Apple's EFI loader and graphics device, and passes no custom GPU. Nested virtualization was off. The PMU module validates encodings, sets the switch and reads it back before start. This static contract does not demonstrate that the undocumented feature is safe during guest execution. No evidence specifically implicates or clears PMU, NVMe, USB media, EFI, or graphics.

A read-only unified-log query scoped to pid 67947 and 11:30:56–11:31:12 returned startup/XPC messages but no explanatory device or guest fault message.

### Next diagnostic step, not run

Do not change production code or make a speculative private-API addition on the basis of this trace. A separate, explicitly bounded scratch comparison should first establish whether the same helper fault occurs with PMU disabled through the existing developer switch. A firmware-only control without the installer could then distinguish a media-dependent trigger from a pre-installer failure. Change one variable per run and compare the actual faulting stack and mapping, not just the generic app alert. Such tests would diagnose this early crash, not establish Windows compatibility or fix its separately documented display and hardware limitations.

No additional VM was started, no source code was edited, and no crash report was modified or deleted during this investigation.
