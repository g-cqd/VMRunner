# Real-guest report: provisioning seed on a Debian 13 arm64 cloud image (L-RUN), 2026-10-23

VMRunner built from `main` at `1c30a38` (chain L merged; the log shows the chain's commits `9064bea` seed as read-only USB, `9dd5759` seed built at each start, `b7681b8` spec in settings, `e817141` help topic, and the rest). Mac15,12, Darwin 25.6.0. Wall time 22:00 to about 22:22.

## Verdict in one line

The machine booted from the replaced disk and reached a login prompt on the serial console, but **no `VMRUNNER` line ever arrived** in 9.5 minutes, and the prompt shows host name `localhost` (not `seedrun`). The seed was **not seen to work**. The start path, the editor and the stop clean-up worked. Per the card the run stopped there (no retry with another configuration).

## Deviations from the card (all authorised by the owner's go-ahead)

1. **Accessibility instead of the owner's hands.** I pressed buttons and set values in the app's own window through the Accessibility API on the app's own pid only (`AXPress`, `AXValue`, `AXSelected`, `AXIncrement/AXDecrement`). `AXIsProcessTrusted()` was true. No keystroke, no mouse click, no activation, no screenshot, no other process touched. A small helper (`ax`, built from my own source in `/tmp`) was used and removed.
2. **Files chosen through a mounted volume.** The app's file picker (SwiftUI `fileImporter`, an in-process open panel) cannot reach `/tmp` without a keystroke (Go to Folder) because `/tmp` is hidden. So I created a 4 GiB sparse disk image `/tmp/vmr-seedrun-img/s.sparseimage`, mounted it as `/Volumes/VMRSEED`, put a clone (`cp -c`) of `disk.raw` and a copy of the spec folder on it, and chose `/Volumes/VMRSEED/disk.raw` and `/Volumes/VMRSEED/spec/machine.yaml`. The bytes and the spec text are the card's; only the paths differ from `/tmp/vmr-seedrun-dl/disk.raw` and `/tmp/vmr-seedrun-spec/machine.yaml`. The image was detached at the end. (This is a defect-like finding in itself: see D2.)
3. After the `cp -c` of `disk.raw` over `Disk.img` I ran `chmod 600` on it (the original `Disk.img` was 0600; `cp -c` kept the download's 0644).
4. Because the app's launch ran from a fish shell, the first download attempt failed on `--proto =https` syntax; I re-ran the same command under `/bin/bash --noprofile --norc -c` as the card says. Nothing was downloaded by the failed attempt.
5. The guest was stopped with the toolbar's **Shut Down** (the card says the owner stops it or the runtime limit does), pressed through Accessibility, about 9 min 50 s after Start. The app's runtime limit (15 min) was not reached.

## Table

| # | Claim | How observed | Verdict |
|---|---|---|---|
| 1 | Download size, SHA-512, signature | `Content-Length: 300023540` (286 MiB, under the 1 GiB cap); curl flags as the card; `shasum -a 512 -c` printed `debian-13-generic-arm64.tar.xz: OK`. Download took 44 s. HTTPS and the published SHA-512 only; **no signature was checked**. `tar -xJf` gave `disk.raw` (3 221 225 472 bytes, 2.7 GiB allocated); `file`: DOS/MBR boot sector, GPT protective partition. | YES |
| 2a | Editor check lines (read by me from the window) | After Choose Spec: `machine.yaml | /Volumes/VMRSEED/spec/machine.yaml`, `line 17: early-boot, inline script`, `line 21: first-boot, scripts/first-boot.sh, sha256 a80aa98b4d6b…`, `line 24: every-boot, inline script`, `Your own cloud-init data, merged with the steps`; buttons Change Spec…, Check Again, Remove. Exactly the expected lines. | YES |
| 2b | Exposure line starting "Provisioning (experimental)" | **Not seen in the window.** The exposures sit in a SwiftUI `DisclosureGroup` ("What this machine can reach on the host"); `AXPress` on it opened only its Help popover and setting `AXDisclosing` had no effect, so the list could not be expanded without a click. Source only (`Security.swift:251`): "Provisioning (experimental): at each start the guest reads a seed built from <spec> and runs its steps as root." (level medium). | NOT SEEN (read from source, inferred) |
| 2c | Suspend with a spec | The **Allow suspend** checkbox stayed offered and ticked (value 1) after the spec was chosen. After Start the toolbar showed Pause, **Suspend**, Shut Down, Force Stop, all enabled (no disabled flag, no reason shown). Suspend was not pressed. | YES (offered and enabled); the saved-state outcome itself NOT SEEN |
| 3 | The machine booted | Console socket output: `Debian GNU/Linux 13 localhost hvc0` then `localhost login:`. Output within the first 40 s after Start (22:08:45). The getty line names `hvc0`, so the guest has that device. | YES |
| 4 | cloud-init found the `cidata` volume (EARLY-BOOT, platform, lsblk, hostname) | No `VMRUNNER-EARLY-BOOT` line and no first-boot block in 9.5 min; host name at the prompt `localhost`, not `seedrun`. Because the guest does have `hvc0` (the getty is on it), the lines would have appeared if `bootcmd` had run. `ProvisioningSeed.iso` (57 344 bytes, 0400) and `.sha256` were built at Start and the app attached it without error. I could not log in (no password, no input allowed), so whether the guest *saw* a USB drive at all is unknown. A scan of the powered-off `Disk.img` for cloud-init logs found nothing usable (logs not flushed or in the journal), and no `/var/lib/vmrunner-marker` text. | **NO** for "seed read by cloud-init in the window of the run"; **NOT SEEN** for why (USB not enumerated, `cidata` not probed, or ordering) |
| 5 | Joliet names | Nothing printed (first-boot script never ran). | NOT SEEN |
| 6 | Merge-Type merge (both parts, `user-data-parts=2`, one reboot, two EARLY-BOOT lines) | No `VMRUNNER-USER-PART-RUNCMD`, no reboot, console showed one boot. | NOT SEEN (follows from 4) |
| 7 | Scripts run from `/var/lib/cloud/vmrunner` as uid 0 without `noexec` | Nothing printed. | NOT SEEN |
| 8 | `base64` exists | Nothing printed. | NOT SEEN |
| 9 | Every-boot 1 then 2 and the guest powers itself off | No `VMRUNNER-EVERY-BOOT` line. The guest did **not** power itself off; it stayed at the login prompt until Shut Down. | NO (the script did not run) |
| 10 | Stop clean-up | After the stop `ls`: `ProvisioningSeed.iso` **gone**, `ProvisioningSeed.sha256` (64 bytes) **kept**. Console socket gone, `nc` exited. | YES |

Also seen on the way:

- The app **accepted `disk.raw` (3 GiB) as the machine's `Disk.img` while the setting says 16 GiB**: no refusal at Start, no message (the card's mismatch stop condition did not trigger).
- The New Machine sheet accepted a raw disk image as "Other ISO" and its setup finished at once (about 5 s); `config.json` then had `installerISO: /Volumes/VMRSEED/disk.raw`, `installerAttached: true`, `diskGiB: 16` (the smallest offered), 2 CPUs, 2048 MiB, NAT, `diskInterface: virtio`.
- The app process 74568 had **exited on its own by about 22:21** (not by my signal; no crash report found in DiagnosticReports; the log has no error line). Cause not observed. It was alive at 22:19 and answered Accessibility queries.
- The stop was graceful: after **Shut Down** the console reset and the machine stopped within 20 s, so the guest handled the power request (it was alive and responsive to ACPI, just not provisioned).

## What was seen vs inferred

Seen: items 1, 2a, 2c (buttons), 3, 10, the config values, the timings. Inferred: the exposure line text (from source), and the conclusion that `bootcmd` did not run (from the absence of lines on a console that provably exists). Not determined: why. The most useful next probes (each a decision for the owner, none done here): a console login (needs a user or a root password in `user-data`, e.g. a `chpasswd` entry in the spec, plus input to the console), or the card's fallback of a read-only virtio disk for the seed (INDEX-L decision 1). Debian's cloud-init may also be reading `cidata` only on a datasource list that finds it later than 9 minutes is unlikely.

## Timings

| Phase | Time |
|---|---|
| `vmr build-app` (merged main) | 46 s (22:00:46 to 22:01:32), exit 0 |
| Download 300 023 540 B | 44 s (22:01:40 to 22:02:24) |
| Create machine through the sheet | setup done in about 5 s |
| Start pressed | 22:08:45 |
| First console output (login prompt) | under 40 s after Start |
| Watched | 22:08:45 to 22:18:37, 9 min 52 s; runtime-limit countdown read `14:59`, then `5:41` at 22:09:xx... (limit 15 min, not reached) |
| Shut Down pressed / machine stopped | 22:18:37 / within 20 s |

## Defects and observations

- D1. **A raw disk image is accepted as "installer ISO" with no complaint, and a disk larger than the file it replaced is accepted silently.** Both are how the card works, but the sheet could say "this file does not look like an ISO" for a partitioned raw disk. Low.
- D2. **The file picker cannot reach `/tmp` or any hidden folder without a keystroke**, and nothing else (a path field, drop target) takes a path. A path field next to Choose Spec/Choose ISO would help anyone driving the app without a keyboard. Low, tooling.
- D3. **The exposure list cannot be expanded through Accessibility** (SwiftUI `DisclosureGroup` whose label holds a help button: the disclosure's only exposed action is the help popover). Same limitation for assistive technology users: the disclosure has no `AXPress` toggle. Low-medium (accessibility).
- D4. **The open panel wrote to the owner's preferences domain even with `VMRUNNER_DATA_DIR`.** `~/Library/Preferences/com.example.VMRunner.plist` was 1887 bytes (mtime Oct 22 20:50) before my run and is now 2575 bytes (mtime Oct 23 22:07). It now holds `NSNavPanelExpandedSizeForOpenMode = {880, 448}` and `NSOSPLastRootDirectory` (a 1376-byte bookmark, which very likely points at `/Volumes/VMRSEED`, now gone), which I could not compare with the earlier content since only counts and the split-view keys were recorded. This is the open panel's own state, written to the bundle id's domain, the same limitation CONTRIBUTING gives for split-view autosave. Not edited by me; the owner may `defaults delete com.example.VMRunner NSOSPLastRootDirectory` and `NSNavPanelExpandedSizeForOpenMode` if they care.
- Split-view check (read only): `defaults read com.example.VMRunner | grep -c NSSplitView` was **2 before and 2 after**. The sidebar-frame value still reads `0, 0, 314, 943, YES, NO` (the collapsed marker already there from the earlier run); the autosave fix did not change it this run. So the fix is not contradicted, and the split-view entry was not rewritten.
- D5. The app exited by itself shortly after the machine stopped (see above). Not reproduced; worth one look if it recurs.

## Cleaned and left

Removed: `/tmp/vmr-seedrun` (data folder with the 3 GiB-allocated machine), `/tmp/vmr-seedrun-dl` (tarball, SHA512SUMS, `disk.raw`), `/tmp/vmr-seedrun-spec`, `/tmp/vmr-seedrun-img` (the sparse image, after `hdiutil detach` of `/Volumes/VMRSEED`; `/Volumes` shows only Macintosh HD), `/tmp/vmr-seedrun-tools` (my helper sources and binaries), `/tmp/vmr-seedrun-strings.txt`, the console, app, build, pid and baseline logs. Removed `$TMPDIR/com.example.VMRunner.savedState` (it did not exist before my launches). The `$TMPDIR/CFNetworkDownload_*.tmp` files: the same six as before the run (none caused by me; the download was `curl`, not the app); left alone. The `l-run` worktree was removed with `git worktree remove --force` and `prune`; `VMRunner-chains/l-run` is gone. Processes: app pids 62224 (quit by TERM) and 74568 (exited by itself), the console `nc` 75161 (exited when the socket closed); `ps` shows none of this run's processes. `df -g /tmp`: 62 GiB free before, 65 after.

Left: the owner's preferences domain `com.example.VMRunner`, changed as in D4 (named, not deleted). The repository was not edited; the main checkout now reads `c7d2fc8` (moved by someone else after my build at `1c30a38`) with only the existing untracked `.vscode/`. The `VMRunner-chains/k-vmr-client` worktree is also no longer there; I did not touch it (I only removed `l-run`), so it was removed by its own chain.
