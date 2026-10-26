# Real-guest report 3: the app's own provisioning seed as a read-only virtio disk, 2026-10-23

VMRunner `main` at `1b6f8d4`, built with `vmr build-app` in a detached worktree (`VMRunner-chains/l-run3`), exit 0. One guest boot, Debian 13 generic arm64 (`debian-13-generic-arm64.tar.xz`, `Content-Length: 300023540`, curl with `--max-filesize 1073741824`, vendor `SHA512SUMS` over HTTPS: `OK`; no signature checked). Provisioning ON (the L-RUN spec, digest `a80aa98b4d6b...` as before), installer NOT attached, 2 CPUs / 2048 MiB, NAT, serial console on, runtime limit 15 min. Run at about 23:00.

## Verdict in one line

**The seed was read and everything the spec asks for ran.** With the bus changed to a read-only virtio disk, cloud-init found the app's own `cidata` volume (`/dev/vdb`), both user-data parts were merged, both boots printed their lines, and the guest powered itself off. The whole sequence (two boots) took well under a minute.

## Deviations (same as report 2, all within the authorisation)

1. The open panel was avoided: I wrote the machine bundle by hand before launch (`config.json` with `source.local`, `isProvisioned`, 2 CPUs, 2048 MiB, `diskGiB 16`, `serialConsole`, `maxRuntimeMinutes 15`, `installerAttached false`, `provisioningSpecPath`), `Disk.img` (`cp -c` of the download, 0600), and `EFIVariables.fd` and `MachineIdentifier` made by a 3-line Swift script calling the two framework constructors the app's setup uses. Scratch data dir `/tmp/vmr-seed3-data` (0700, `VMRUNNER_DATA_DIR`). The app rewrote `config.json` from 346 to 2301 bytes.
2. Start was the app's own `--start seedrun` launch argument, not a button. Accessibility was used only to read the window (button states, static text) on the app's own pid; no keystroke, click, activation or screenshot (zero screenshots this time).
3. The raw 3 GiB disk against `diskGiB: 16` was started without complaint (third time).

## Table

| # | Open question | Verdict | Evidence |
|---|---|---|---|
| 1 | Download size, SHA-512, no signature | YES | 300 023 540 B, `shasum -a 512 -c` printed `debian-13-generic-arm64.tar.xz: OK`; no signature checked |
| 2 | Editor check lines | YES (read from the window) | `line 17: early-boot, inline script`, `line 21: first-boot, scripts/first-boot.sh, sha256 a80aa98b4d6b...`, `line 24: every-boot, inline script`, `Your own cloud-init data, merged with the steps`; buttons Change Spec..., Check Again, Remove. The exposure line was not read (still inside the collapsed disclosure, as in report 1). |
| 3 | The machine booted | YES | getty `Debian GNU/Linux 13 seedrun hvc0` / `seedrun login:` |
| 4 | cloud-init found the volume on virtio | YES | `VMRUNNER-EARLY-BOOT 3.01`; `platform=nocloud subplatform=config-disk (/dev/vdb)`; `hostname=seedrun`; `vdb virtio 1 cidata iso9660 56K` (TRAN virtio, RO 1, label cidata); `seed-device=/dev/vdb` |
| 5 | Joliet names | YES | `seed-files=meta-data user-data ` (lower case); kernel: `ISO 9660 Extensions: Microsoft Joliet Level 3` (twice, once per boot, at 1.17 s and 3.73 s) |
| 6 | Merge-Type merge | YES | `VMRUNNER-USER-PART-RUNCMD` and the first-boot block both present; `user-data-parts=2`; one reboot: two `VMRUNNER-EARLY-BOOT` lines (3.01 and 2.60) and `power_state` (the user part's map) took effect |
| 7 | Scripts run from `/var/lib/cloud/vmrunner` as uid 0, no `noexec` | YES | `uid=0 script=/var/lib/cloud/vmrunner/step-002`; `scriptdir-mount=rw,relatime,discard,errors=remount-ro`; listing `step-001` (79 B), `step-002` (973 B), `step-003` (212 B), all `-rwx------ root` |
| 8 | `base64` exists | YES | `base64=/usr/bin/base64` |
| 9 | Every-boot 1 then 2 and power-off | YES (power-off inferred from state) | `VMRUNNER-EVERY-BOOT 1` then `VMRUNNER-EVERY-BOOT 2`; afterwards the toolbar showed Start again, the console socket was gone and `nc` had exited, the seed ISO was removed. The runtime limit (15 min) was not near, so the stop was the guest's `systemctl poweroff`. I did not see the poweroff line itself (the console prints nothing after the second login prompt). |
| 10 | Stop clean-up | YES | after the stop: `ProvisioningSeed.iso` gone, `ProvisioningSeed.sha256` (64 B, 0600) kept |
| 11 | Suspend button with the seed attached | **NOT OBSERVED** | The run finished in under a minute, before I polled the toolbar, and the single boot allowed was used. After the stop all I saw was Start. Source only: `restoresSavedState` compares the active spec path ("its seed is a read-only virtio disk"). In report 1 the button was enabled with a USB seed. No suspend was tried, so nothing is known about the saved state. |
| 12 | Allow suspend still offered | YES (read from the window) | the "Allow suspend (writes memory to disk)" row is present with the spec set |

## Console (clean, whole VMRUNNER-relevant capture; control sequences and tree glyphs aside)

```
VMRUNNER-EARLY-BOOT 3.01
VMRUNNER-EVERY-BOOT 1
VMRUNNER-USER-PART-RUNCMD
VMRUNNER-FIRST-BOOT-BEGIN
uid=0 script=/var/lib/cloud/vmrunner/step-002
base64=/usr/bin/base64
scriptdir-mount=rw,relatime,discard,errors=remount-ro
total 12
-rwx------ 1 root root  79 Oct 23 21:00 step-001
-rwx------ 1 root root 973 Oct 23 21:00 step-002
-rwx------ 1 root root 212 Oct 23 21:00 step-003
platform=nocloud subplatform=config-disk (/dev/vdb)
hostname=seedrun
NAME    TRAN   RO LABEL  FSTYPE   SIZE
vda     virtio  0                   3G
|-vda1  virtio  0        ext4     2.9G
`-vda15 virtio  0        vfat     127M
vdb     virtio  1 cidata iso9660   56K
seed-device=/dev/vdb
seed-files=meta-data user-data 
[    1.169349] ISO 9660 Extensions: Microsoft Joliet Level 3
[    3.732635] ISO 9660 Extensions: Microsoft Joliet Level 3
user-data-parts=2
VMRUNNER-FIRST-BOOT-END
Debian GNU/Linux 13 seedrun hvc0
seedrun login:
VMRUNNER-EARLY-BOOT 2.60
VMRUNNER-EVERY-BOOT 2
Debian GNU/Linux 13 seedrun hvc0
seedrun login:
```

## Seen vs inferred

Seen: everything in the console block. Inferred: that the final stop was the guest's own poweroff (not a host stop), from the elapsed time and the absence of any pressing by me; the Suspend question is not observed.

Oddities, not defects of the seed: the `step-00N` mtimes read 21:00 because the guest clock is UTC (host 23:00 local, UTC+2). The two `Joliet Level 3` kernel lines (1.17 s and 3.73 s) are both from the first-boot run's `dmesg | grep -m3`: the boot-time mount and the script's own `mount -o ro` (inferred; the order of the first `seedrun login:` relative to the reboot was not analysed).

## Timings

| Step | Time |
|---|---|
| `vmr build-app` | about 1 min, exit 0 |
| Download + SHA-512 + unpack | about 1 min |
| App launched with `--start seedrun` | 23:00:21 |
| Last console byte (file mtime) | 23:00:38, so 17 s after launch for both boots and the shutdown |
| First EARLY-BOOT line | guest uptime 3.01 s |

## Defects and observations

- D1. **The whole path now works with the seed on virtio**, so reports 1 and 2's USB suspicion (ordering) is consistent; USB alone was still never tested after the change and does not need to be.
- D2. The guest finished before a human or script could look at the toolbar; a Suspend check needs a spec whose every-boot step does not power off (or a longer first boot), a decision for the owner. A second boot was not made (one boot authorised).
- D3. The exposure list still cannot be expanded through Accessibility (report 1, D3); not retried.
- D4. The raw-disk-versus-`diskGiB` mismatch is still accepted silently.
- Owner preferences: `~/Library/Preferences/com.example.VMRunner.plist` was 2575 bytes, mtime 1792786038 before and after (unchanged); `NSSplitView` key count 2 before and after.

## Cleaned and left

Removed: `/tmp/vmr-seed3` (logs, console capture, pids), `/tmp/vmr-seed3-data` (machine bundle, 3 GiB), `/tmp/vmr-seed3-dl` (tarball, sums, `disk.raw`), `/tmp/vmr-seed3-spec`, `/tmp/vmr-seed3-tools` (my helpers), `$TMPDIR/com.example.VMRunner.savedState`, the `l-run3` worktree (`git worktree remove` left its build directory, which I then deleted by hand; `worktree prune` run; `git worktree list` shows only the main checkout). Processes: app 97980 (TERM, exited), the console `nc` (exited when the socket closed); none of this run's remain. Repository not edited (`git status`: only the existing untracked `.vscode/`). Left: nothing of mine in `~/Library`.
