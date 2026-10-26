# Real-guest report 2: why cloud-init did not read the provisioning seed (follow-up of L-RUN), 2026-10-23

VMRunner `main` at `c7d2fc8`, built with `vmr build-app` in a detached worktree (`VMRunner-chains/l-run2`) in 55 s (22:22:29 to 22:23:24), exit 0. Two guest boots in all (the cap), each far under 20 minutes. Wall time about 22:22 to 22:50.

## Verdict in short

- **A (kernel does not see the USB drive): refuted.** The kernel enumerates it on both images, read-only, and (hdiutil ISO, generic image) `lsblk` shows `TRAN usb`, `RO 1`, `LABEL cidata`, `FSTYPE iso9660`.
- **B (our ISO is not a valid cidata volume): not supported.** The app's ISO is a valid ISO 9660 with a Joliet tree and volume id `CIDATA`; a Linux reading of it was not obtained (see "not seen").
- **C (ordering / timing of ds-identify against the USB drive): the main remaining suspect, not proven.** No boot tested a USB-only seed on the generic image, so it is inferred.
- **D (user-data content): not supported.** The same compiled content was never read by a guest, but the minimal content over virtio was read at once, and the content is plain cloud-config.
- **Probe 1 could not be run as written**: the Debian nocloud arm64 image stops in `systemd-firstboot` on the graphical console ("Press any key to proceed") and never reaches a getty on `hvc0`, so there was no root login on the serial socket. A key press is forbidden. See P1.
- **Probe 2 was run with an added discriminator** (a second seed on a read-only virtio disk, in the same boot). Result: **cloud-init on the generic image found the seed on the virtio disk (`/dev/vdb`, `subplatform=config-disk (/dev/vdb)`) 45 s after Start**, host name `seedvio`, `bootcmd` and `runcmd` markers printed on `hvc0`. The USB seed was visible beside it but cloud-init chose `vdb` first, so **USB alone was not tested**.
- Recommendation: **move the seed to a read-only virtio block disk** (details at the end). Keep USB only if a later run shows it works alone.

## Conditions and deviations (all in the owner's authorisation)

1. Scratch data dir `/tmp/vmr-seed2-data` (0700, `VMRUNNER_DATA_DIR`), guest 2 CPUs / 2048 MiB, runtime limit 15 min, NAT, serial console on.
2. **Documented deviation (asked for): the open panel was avoided.** The machine bundle was written by hand before the app started: `config.json` with the app's own fields (`source: {local: {_0: <path>}}`, `isProvisioned: true`, `cpuCount 2`, `memoryMiB 2048`, `diskGiB 16`, `serialConsole true`, `maxRuntimeMinutes 15`, `provisioningSpecPath` or `installerISO`/`extraDisks`), `Disk.img` (`cp -c` of the downloaded `disk.raw`, mode 0600), and `EFIVariables.fd` and `MachineIdentifier` made with a 5-line Swift script that calls `VZEFIVariableStore(creatingVariableStoreAt:)` and `VZGenericMachineIdentifier()` (the two calls the app's setup makes). With no approvals file present the app grandfathered the paths of the machines on disk, so no approval prompt appeared. For boot 2 I deleted the scratch approvals file first, for the same reason (my scratch folder only).
3. **Start was by the app's own `--start <name>` launch argument** (as in the macOS report), not a button press. Stopping was by `AXPress` on Shut Down and Force Stop of the app's own pid. No keystroke, no click, no activation. `AXIsProcessTrusted()` true.
4. **Window screenshots, app window only, by window number (`screencapture -l`): three**, because the console socket was silent in boot 1 and the screen was the only way to see why (boot 1 twice, boot 2 once). Nothing else was captured.
5. In boot 1 I wrote to the console socket from a small Python client (login and read-only commands, as the brief said) but it never got a prompt, so nothing was sent except `\r`.
6. Boot 2 attaches **two** seeds (USB via "Attach installer", virtio via a read-only extra disk) instead of one, to separate bus from content in a single boot. The brief's single-seed probe 2 would have left C unseparated.
7. Download 1: `debian-13-nocloud-arm64.tar.xz`, `Content-Length: 287139812` (274 MiB), curl flags as the card with `--max-filesize 1073741824`, SHA-512 `OK` against the vendor's `SHA512SUMS` over HTTPS (the host redirects to a mirror over HTTPS); 42 s. Unpacks to `disk.raw` (3 221 225 472 bytes, GPT). The `.raw` file itself was not downloaded (the tarball is the smaller vendor file and it is the one the sums list). No signature checked.
   Download 2: `debian-13-generic-arm64.tar.xz`, 300 023 540 bytes, SHA-512 `OK`, 51 s.
8. The raw nocloud disk is 3 GiB and the setting said 16 GiB; the app started it without complaint (same as last time).

## P1: nocloud image, our seed on USB (spec on, installer unattached)

Started 22:25:00 by `--start seedrun`. The app built the seed at start (`ProvisioningSeed.iso` 57 344 bytes mode 0400, `ProvisioningSeed.sha256` 64 bytes) and attached it without a message. `config.json` grew from 478 to 2301 bytes when the app rewrote it. The spec digest was `a80aa98b4d6b…` again (same script).

**Console socket: nothing arrived in 90 s** (my client was connected from 22:25:10; the socket stayed silent, not even a login prompt after `\r`). `Disk.img` mtime moved, the toolbar countdown ran (13:19 left), so the guest was running.

**What the screen showed (window screenshot at 22:26, read by me):** the Debian 13 boot stopped at

```
Welcome to your new installation of Debian GNU/Linux 13 (trixie)!
Please configure your system!
-- Press any key to proceed --
[  OK  ] Finished systemd-update-done.service ...
[  OK  ] Finished apparmor.service - Load AppArmor profiles.
[    2.052778] scsi 0:0:0:0: Direct-Access     Apple    Virtual Disk     1    PQ: 0 ANSI: 6
[    2.057121] scsi 0:0:0:0: Attached scsi generic sg0 type 0
[    2.061788] sd 0:0:0:0: [sda] 112 512-byte logical blocks: (57.3 kB/56.0 KiB)
[    2.062052] sd 0:0:0:0: [sda] Write Protect is on
[    2.062281] sd 0:0:0:0: [sda] Write cache: disabled, read cache: enabled, doesn't support DPO or FUA
[    2.072171] sd 0:0:0:0: [sda] Attached SCSI disk
```

- **Seen:** the kernel enumerates the app's seed as a USB mass-storage disk `sda` (the `scsi` host is `usb-storage`'s), 112 blocks of 512 B = 57 344 B = the ISO's size, write-protected, attached at kernel time 2.05 s. The systemd lines just before it are stamped about 1.80 s (AppArmor profile loading, journal catalog), so the drive appeared roughly 0.25 s after those services started.
- **Seen:** the image waits for a key in `systemd-firstboot` (machine id not initialised) and the console is `tty0` (graphical), not `hvc0`. Hence no serial login: the brief's assumption ("logs in as root without a password on the serial console") does not hold for this nocloud image under this app. A key press is not allowed, so the guest-side commands (`blkid`, `mount`, `ls`, `od`) of probe 1 **were not run**. I did not try to edit the guest disk (ext4 is not readable here and the kernel command line is on the root file system).
- Shut Down (22:27:40) did nothing in the guest (it is stuck before its power handling: the toolbar read "Shutting down…" for 25 s); **Force Stop** worked. After the stop: `ProvisioningSeed.iso` gone, `.sha256` kept (clean-up path again OK). Boot 1 lasted about 2 min 40 s.

### Host-side inspection of the app's seed (copied at 22:25, parsed by a small Python reader, `-I`)

- `file`: `ISO 9660 CD-ROM filesystem data 'CIDATA'`; 57 344 bytes, volume space 28 blocks of 2048.
- Primary volume descriptor: system id empty, volume id `CIDATA`, root directory with `META-DATA` (78 B) and `USER-DATA` (3144 B), **no `;1` suffix, no Rock Ridge**.
- Supplementary volume descriptor: escape sequence `%/E` (Joliet level 3), volume id `cidata` (UCS-2, lower case), names `meta-data`, `user-data` (lower case).
- macOS mounted it read-only (`hdiutil attach -readonly`) as `cidata`, "ISO Joliet", showing `meta-data` and `user-data`; contents: `meta-data` = `instance-id: '5EED0000-0000-4000-8000-000000000001'` and `local-hostname: 'seedrun'`; `user-data` = a `multipart/mixed` document with boundary `==vmrunner-seed-boundary==`, part 1 the user's `#cloud-config` (runcmd, power_state), part 2 with `Merge-Type: list(append)+dict(no_replace,recurse_list)+str()` holding `bootcmd`/`runcmd`/`write_files` (base64 script bodies).
- Whether Linux reads those names is **not seen**. By its rules Linux isofs takes the Joliet tree when the kernel has it (`CONFIG_JOLIET`), else the primary tree with names lower-cased and `;1` stripped, so either name set shows `meta-data`/`user-data`. That is inferred, not observed.

## P2: generic image, hdiutil ISO on USB (installer route) and a second hdiutil ISO on a read-only virtio disk

Same `debian-13-generic-arm64` disk as last time (re-downloaded, sums OK). Provisioning OFF (`provisioningSpecPath` empty). Start 22:46:55 by `--start seedrun2`.

- USB seed: `seed-usb-hdiutil.iso`, made with `hdiutil makehybrid -iso -joliet -default-volume-name cidata` from a directory holding the **app's own compiled `user-data` and `meta-data`** (copied out of the mounted app seed), attached with `installerAttached: true` (the app's installer route, USB read-only). Host name in its `meta-data`: `seedrun`.
- Virtio seed: `seed-vio.iso`, same hdiutil command, a minimal `user-data` (`bootcmd` echoing `VMRUNNER-PROBE2-VIRTIO-BOOTCMD` and `runcmd` echoing `VMRUNNER-PROBE2-VIRTIO-RUNCMD host=$(hostname) sub=$(cloud-init query v1.subplatform)` plus `lsblk` to `/dev/hvc0`), `meta-data` host name `seedvio`, attached as a read-only extra disk (`extraDisks[].readOnly: true`, a virtio block device).
- Structure of the hdiutil ISO vs the app's (host-parsed): hdiutil writes Rock Ridge (`SP`, `ER IEEE_P1282`, `PX`), system id `APPLE INC., TYPE: 0002`, Joliet level 1 (`%/@`), file names also without `;1`, volume id `CIDATA`/`cidata`, 900 KiB. The app's has no Rock Ridge, empty system id, Joliet level 3 (`%/E`), 56 KiB.

**Console (verbatim, the whole capture, 479 bytes, first output 45 s after Start; control sequences removed):**

```
VMRUNNER-PROBE2-VIRTIO-BOOTCMD
VMRUNNER-PROBE2-VIRTIO-RUNCMD host=seedvio sub=config-disk (/dev/vdb)
NAME    TRAN   RO LABEL  FSTYPE   SIZE
sda     usb     1 cidata iso9660  900K
vda     virtio  0                   3G
├─vda1  virtio  0        ext4     2.9G
└─vda15 virtio  0        vfat     127M
vdb     virtio  1 cidata iso9660  900K

Debian GNU/Linux 13 seedvio hvc0

seedvio login:
```

The window (screenshot) read `Debian GNU/Linux 13 seedvio tty1 / seedvio login:`.

- **Seen:** cloud-init on this image found a NoCloud seed (`config-disk` on `/dev/vdb`), applied `meta-data` (host name `seedvio`) and ran `bootcmd` and `runcmd` (both marker lines, in order). So this image's cloud-init is not disabled, `/dev/hvc0` exists and is the console, the generic kernel has `iso9660` and read-only virtio block, and cloud-init reads a hdiutil-made ISO with Joliet.
- **Seen:** the USB seed was in the guest at runcmd time as `sda`, `TRAN usb`, `RO 1`, `LABEL cidata`, `FSTYPE iso9660`, 900K (the hdiutil ISO of the app's compiled data). So the generic kernel has usb-storage and isofs, `blkid` labels the ISO `cidata`, and read-only is honoured.
- **Not seen:** whether cloud-init would have used `sda` alone. The NoCloud datasource sorts candidate devices in reverse name order (inferred from its source as I remember it), so `vdb` comes before `sda`; it stopped at `vdb`. The `host=seedvio` value is consistent with that (the USB seed would have said `seedrun`).
- **Not seen:** `dmesg`, `cloud-init.log`, `/run/cloud-init/ds-identify.log` (no login on the image). The console shows no kernel log, so no timing for this boot.
- Shut Down at 22:48:04, the console socket vanished within 5 s and the toolbar returned to the editor: a clean ACPI stop. Boot 2 lasted about 1 min 10 s of the 15-minute limit. I did not watch 6 minutes because the markers had arrived at 45 s.

## Diagnosis, ranked

1. **C (ds-identify / probing ran before the USB drive existed) is the most likely cause of the first run, but is inferred.** What supports it: on the nocloud boot the USB disk appeared at 2.05 s, a quarter second after services such as AppArmor were already loading at about 1.8 s; usb-storage enumerates asynchronously, while virtio block devices are present very early. cloud-init's generator (`ds-identify`) runs at the start of PID 1 and, finding no `cidata` volume, can leave the datasource unset (Debian's default policy then disables cloud-init, which fits "no markers, host name `localhost`" last time). What is missing: a guest log from a USB-only boot of the generic image.
2. **B (our ISO's format or label): unlikely.** The volume id is `CIDATA` in the primary tree and `cidata` in Joliet; the same data written by hdiutil appears to the kernel and `blkid` as `LABEL cidata`, `iso9660`. Minor differences from hdiutil's ISO: no Rock Ridge, Joliet level 3 (`%/E`, which Linux accepts as well as `%/@`), empty system id. None is known to matter; not tested on Linux.
3. **D (content): unlikely.** A valid multipart user-data with `Merge-Type` was never run by a guest here, so the multipart merge, the scripts and the `bootcmd` path are still untested, but nothing suggests a problem with how it is found. Note the merge is still **not seen to work** (L-RUN items 5 to 9 remain NOT SEEN).
4. **A (kernel does not see USB): refuted** by two screens and an `lsblk`.

The previous run's guess "USB not enumerated" is therefore wrong; the likelier story is "enumerated too late, or ranked below cloud-init's first look".

## Recommendation

- **Try a read-only virtio block disk for the seed** (the card's INDEX-L decision 1 fallback). The probe shows that route works on this image with an hdiutil-built ISO, found 45 s after Start. In the code that attaches the seed (`MachineConfiguration` / `ConfigurationBuilder`, the place that today builds a USB mass-storage device from `ProvisioningSeed.iso`), use a `VZVirtioBlockDeviceConfiguration` over `VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)` instead of `VZUSBMassStorageDeviceConfiguration`, keep the file read-only and removed at stop, and keep the label `cidata`. Because the machine's own disk is virtio and takes `vda`, the seed will be `vdb` (or a name after other extra disks), so the spec must not assume a device name.
- The saved-state rule (`restoresSavedState`: "the provisioning spec in use (its seed is a USB drive...)") would then compare a block device instead; update it and the `ProvisioningSeed.prepare` comment accordingly.
- **Do not change the ISO writer yet.** If a later run shows a USB-only seed failing while the virtio seed works, that settles C and nothing in the ISO needs to change. If an ISO fix is wanted anyway as belt and braces: add Rock Ridge and use Joliet level 1, to match hdiutil's output byte for byte in the places Linux looks; this is a guess, not something the probes showed to be needed.
- **One more real-guest boot would close C:** the generic image, the app's own seed (spec on) as a virtio read-only disk, watching for `VMRUNNER-EARLY-BOOT`. A second, cheaper split: the same image with only the hdiutil ISO on USB (no virtio seed). Either gives the missing "USB alone" or "app ISO on virtio" answer; both were outside this run's two boots.
- For a nocloud image, the run needs a way past `systemd-firstboot` without a key (kernel command line `systemd.firstboot=off` or a prepared disk); not worth pursuing now.

## Timings

| Step | Time |
|---|---|
| `vmr build-app` (worktree at `c7d2fc8`) | 55 s |
| Download nocloud tarball (287 MB) and check | 42 s (22:22:44 to 22:23:26) |
| Boot 1 (nocloud, seed on USB): Start / watched / Force Stop | 22:25:00 / 90 s of console silence, screen read 22:26 / 22:27:50, about 2 min 50 s in all |
| Download generic tarball (300 MB) and check | 51 s (22:45:44 to 22:46:35) |
| Boot 2 (generic, hdiutil ISO on USB plus virtio) Start / first console output / Shut Down | 22:46:55 / about 22:47:40 (about 45 s) / 22:48:04, stopped within 5 s |

## Defects and observations

- D1. **The app's ISO and hdiutil's differ** (see P2); no failure attributed to it.
- D2. **Debian's nocloud arm64 image is not usable by a socket-only run**: it waits in `systemd-firstboot` for a key on `tty0` and has no getty on `hvc0` until it passes. The owner's note about passwordless root on the serial console is not true here. Also the Shut Down request is not handled by a guest in that state (Force Stop needed), which the toolbar handled with its "Force Stop pulls the plug" hint.
- D3. **The app did not exit by itself this time.** App 1 (pid 76943) ran until I terminated it (it stayed alive after Force Stop for about 40 s while I worked); app 2 (pid 77235) stayed alive through the stop and until I sent TERM, 1 min 19 s after launch. The earlier self-exit did not recur in two short runs (not a conclusion; the earlier one came about 3 minutes after the stop).
- D4. **The first Python console client spun on a closed socket** (`recv` returning empty after Force Stop used 6 s of CPU) because my client did not stop on EOF; it was my script's fault, not the app's. I killed that recorded pid.
- D5. Start with a raw 3 GiB disk against `diskGiB: 16` was accepted silently again (as in the first report).
- D6. The preferences domain **did not change** in this run: `~/Library/Preferences/com.example.VMRunner.plist` was 2575 bytes (mtime Oct 23 22:07) before and after, and `defaults read com.example.VMRunner | grep -c NSSplitView` read 2 after (read-only looks only). Avoiding the open panel kept it untouched.

## Cleaned and left

Removed: `/tmp/vmr-seed2` (build log, app logs, console logs, the app's seed copy, the two hdiutil ISOs and their source folders, the screenshots, pids file), `/tmp/vmr-seed2-data` (both machine bundles, 3 GiB each, the approvals file), `/tmp/vmr-seed2-dl` and `/tmp/vmr-seed2-dl2` (tarballs, SHA512SUMS, `disk.raw`), `/tmp/vmr-seed2-spec`, `/tmp/vmr-seed2-tools` (my sources and binaries: `ax`, `win`, `efi.swift`, `con.py`, `iso.py`), the console-log copies, and `$TMPDIR/com.example.VMRunner.savedState` (not there before my launches). The `l-run2` worktree was removed (`git worktree remove --force`, `prune`); `git worktree list` shows only the main checkout; `git status` shows only the existing untracked `.vscode/`; the repository was not edited (the build wrote only into the worktree). The one image I mounted on the host (the app's seed copy) was detached ("disk4" ejected); `hdiutil info` lists no VMRunner scratch image. Processes: app 76943 (TERM), app 77235 (TERM), console client 76975 (TERM), `nc` 77243 (exited when the socket closed); `ps` shows none of this run's processes. The six `$TMPDIR/CFNetworkDownload_*.tmp` files are the older ones (Oct 22 01:41 to 09:53); none was caused by me (the downloads were `curl`), left alone. `df -g /tmp`: 65 GiB free after (62 at the lowest point during the run, before the first cleanup).

Left: nothing of mine in `~/Library` (preferences unchanged, see D6), no files under `/tmp` from this run.
