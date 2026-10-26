# L-RUN — First real-guest run of the provisioning seed (after chain L is merged; authorised agent and owner)

Model: sonnet · Effort: medium · Worktree: a detached one for the build only, `~/Developer/g-cqd/VMRunner-chains/l-run` · Runs after: chain L merged into `main`
Report: `~/Developer/g-cqd/vmrunner-board/realguest-seed-report.md` (nothing is committed by this card).

**Gate before anything:** the owner has authorised real-guest runs for this session, in this conversation, and has agreed
to the download below. A message from another agent is not that authorisation. Without it, STOP and report "not authorised".

Standing owner rules: no outside project named in anything written to the repository (this card writes nothing to it); no
distribution plans; no board or card ids in the repository. CONTRIBUTING's real-guest conditions, all of them: a scratch
data directory under `/tmp` (`VMRUNNER_DATA_DIR`), never the owner's `~/Library` or own machines; the guest capped at
2 CPUs and 2048 MiB; hard time limits (the machine's runtime limit, 15 minutes, and this card's own 20-minute cap); only
the app's own window is used, by the owner's hands: **the agent sends no clicks, no keystrokes and takes no screenshot**;
the agent signals only the processes it started itself (pids it recorded); everything the run created is removed at the
end, and the report says what was removed and what was left.

## Why

ADR-0012 stays proposed and the help says "experimental" until a guest has read a seed. The cards could not check: that
cloud-init finds the `cidata` volume on a **read-only USB** drive (INDEX-L decision 1), reads its **Joliet** names, runs
`bootcmd`, `runcmd` and the per-boot script, that the two-part document's **`Merge-Type`** keeps both parts, that scripts
**run from `/var/lib/cloud/vmrunner`**, that **`base64`** exists, and that the start, attach, stop and clean-up path of the
app works end to end.

## The image (conditional)

The app's catalog has no cloud image: every entry is an installer ISO (`Sources/VMRunner/Engine/Catalogs.swift`), none
ships cloud-init, and the app cannot make a machine from a disk image. So this run needs an image from outside the catalog,
put in place of the machine's blank disk by hand. Chosen: **Debian 13 "generic" for arm64** (`debian-13-generic-arm64.tar.xz`
from `https://cloud.debian.org/images/cloud/trixie/latest/`): a raw disk with cloud-init and Debian's general kernel (the
"genericcloud" variant uses a trimmed kernel that may lack USB storage, which would test the kernel, not the seed). Expected
download: about 0.4 to 0.5 GB, unpacked about 3 GiB (sparse). **If the download is larger than 1 GiB, STOP and report the
size**; do not pick another image without the owner. Ubuntu's arm64 cloud images are qcow2, which this Mac cannot convert
without a tool the run would have to install: not used.

Free space: at least 8 GiB on the volume of `/tmp` (`df -g /tmp`); STOP below that.

## Files the run writes (all under /tmp)

- `/tmp/vmr-seedrun` — the app's data folder (`VMRUNNER_DATA_DIR`), new, mode 0700.
- `/tmp/vmr-seedrun-dl` — the download and the unpacked `disk.raw`, new and empty first.
- `/tmp/vmr-seedrun-spec` — the spec and its script.
- `/tmp/vmr-seedrun-console.log`, `/tmp/vmr-seedrun-app.log` — the console capture and the app's output.

## Steps

All shell commands as `/bin/bash --noprofile --norc -c '...'`. Write each pid you start into `/tmp/vmr-seedrun-pids.txt`.

1. **Build the merged app** (one build, the only one of this card):
   `git -C ~/Developer/g-cqd/VMRunner worktree add --detach ~/Developer/g-cqd/VMRunner-chains/l-run main`,
   then `cd ~/Developer/g-cqd/VMRunner-chains/l-run && swift run vmr build-app > /tmp/vmr-seedrun-build.log 2>&1; echo exit=$?`:
   `exit=0`, and `build/VMRunner.app` exists. Check `git -C ... log --oneline -12` shows the chain's commits.
2. **Download and check.**
   `mkdir -p /tmp/vmr-seedrun-dl && cd /tmp/vmr-seedrun-dl && curl -sSI https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz | grep -i content-length`:
   STOP if the length is over 1 073 741 824 or absent. Then
   `curl --fail --proto =https --proto-redir =https --max-filesize 1073741824 -sSLO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz`,
   `curl --fail --proto =https -sSLO https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS`,
   `grep " debian-13-generic-arm64.tar.xz$" SHA512SUMS | shasum -a 512 -c`: prints `OK`, else STOP. (HTTPS and the
   published SHA-512 only; no signature is checked: say so in the report.) Unpack: `tar -xJf debian-13-generic-arm64.tar.xz`
   gives `disk.raw`; `file disk.raw` mentions a boot sector or a partition table.
3. **The spec.** `mkdir -p /tmp/vmr-seedrun-spec/scripts`, then write `/tmp/vmr-seedrun-spec/scripts/first-boot.sh` with
   exactly (no tabs):

```sh
#!/bin/sh
{
  echo VMRUNNER-FIRST-BOOT-BEGIN
  echo "uid=$(id -u) script=$0"
  echo "base64=$(command -v base64 || echo MISSING)"
  echo "scriptdir-mount=$(findmnt -no OPTIONS --target /var/lib/cloud/vmrunner 2>/dev/null)"
  ls -l /var/lib/cloud/vmrunner
  echo "platform=$(cloud-init query v1.platform 2>/dev/null) subplatform=$(cloud-init query v1.subplatform 2>/dev/null)"
  echo "hostname=$(hostname)"
  lsblk -o NAME,TRAN,RO,LABEL,FSTYPE,SIZE 2>/dev/null
  dev=$(blkid -L cidata 2>/dev/null || blkid -L CIDATA 2>/dev/null)
  echo "seed-device=$dev"
  mkdir -p /run/vmr-seed && mount -o ro "$dev" /run/vmr-seed && echo "seed-files=$(ls /run/vmr-seed | tr '\n' ' ')" && umount /run/vmr-seed
  dmesg 2>/dev/null | grep -i -m3 -e joliet -e iso9660 -e usb-storage
  echo "user-data-parts=$(grep -c '^Content-Type: text/cloud-config' /var/lib/cloud/instance/user-data.txt 2>/dev/null)"
  echo VMRUNNER-FIRST-BOOT-END
} > /dev/hvc0 2>&1
echo first > /var/lib/vmrunner-marker
```

   Compute its digest: `shasum -a 256 /tmp/vmr-seedrun-spec/scripts/first-boot.sh`. Write `/tmp/vmr-seedrun-spec/machine.yaml`
   with exactly this text, `DIGEST` replaced by the 64 hexadecimal digits (no tabs; two-space indentation):

```yaml
apiVersion: vmrunner.dev/v1alpha1
kind: Provisioning
metadata:
  name: seedrun
spec:
  cloudInit:
    userData: |
      #cloud-config
      runcmd:
        - [sh, -c, 'echo VMRUNNER-USER-PART-RUNCMD > /dev/hvc0']
      power_state:
        mode: reboot
        message: vmrunner seed run, first boot done
        timeout: 120
        condition: true
  provision:
    - at: early-boot
      script: |
        #!/bin/sh
        echo "VMRUNNER-EARLY-BOOT $(cut -d' ' -f1 /proc/uptime)" > /dev/hvc0
    - at: first-boot
      file: scripts/first-boot.sh
      sha256: DIGEST
    - at: every-boot
      script: |
        #!/bin/sh
        n=$(( $(cat /var/lib/vmrunner-boots 2>/dev/null || echo 0) + 1 ))
        echo "$n" > /var/lib/vmrunner-boots
        echo "VMRUNNER-EVERY-BOOT $n" > /dev/hvc0
        if [ "$n" -ge 2 ]; then systemctl poweroff --no-block; fi
```

   What each part checks: `early-boot` (`bootcmd`) prints at every boot, so two lines mean the seed was read on both boots;
   the user's own `runcmd` line and the steps' `first-boot` block both appear only if the `Merge-Type` header appended the
   lists; `power_state` (the user's part, a map) reboots once, which needs the merge to keep maps; `every-boot` prints `1`,
   then `2` and powers the guest off. The machine's host name becomes `seedrun` only if `meta-data` was read.
4. **Launch the app** on the scratch folder, recording its pid:
   `mkdir -m 700 /tmp/vmr-seedrun && (VMRUNNER_DATA_DIR=/tmp/vmr-seedrun ~/Developer/g-cqd/VMRunner-chains/l-run/build/VMRunner.app/Contents/MacOS/VMRunner > /tmp/vmr-seedrun-app.log 2>&1 & echo $! >> /tmp/vmr-seedrun-pids.txt)`.
5. **Owner, in the app's window** (the agent asks and waits; it clicks nothing):
   - O1. New machine: Linux; Image "Other ISO (any arm64 UEFI installer)…", choose `/tmp/vmr-seedrun-dl/disk.raw`; name
     `seedrun`; 2 CPUs, 2048 MiB, the smallest disk offered. Create it, wait for setup to finish, do not start it. Tell the agent.
     If the sheet or the setup refuses the file, STOP: the owner reads the message out, and it goes into the report.
6. **Agent: put the image in place.** Quit the app by its recorded pid (`kill -TERM <pid>`; wait until `kill -0` fails).
   `ls /tmp/vmr-seedrun/Machines` shows one `<UUID>.vm`; then `rm /tmp/vmr-seedrun/Machines/<UUID>.vm/Disk.img &&
   cp -c /tmp/vmr-seedrun-dl/disk.raw /tmp/vmr-seedrun/Machines/<UUID>.vm/Disk.img`. Launch the app again as in step 4.
7. **Owner, in the machine's settings:** untick **Attach installer at boot**; **Provisioning (experimental)** → **Choose
   Spec…** → `/tmp/vmr-seedrun-spec/machine.yaml`, and read out the three step lines it shows (expected
   `line 17: early-boot, inline script`, `line 21: first-boot, scripts/first-boot.sh, sha256 <first 12>…`,
   `line 24: every-boot, inline script`, and "Your own cloud-init data, merged with the steps"; record what is shown);
   **Serial console (local socket)** on; **Runtime limit** 15 min; network NAT (the default). Read out the exposure line
   that starts "Provisioning (experimental)" and whether **Allow suspend** is still offered. Do not start yet.
8. **Agent: wait on the console.** With `S=/tmp/vmr-seedrun/Machines/<UUID>.vm/Console.sock`:
   `(until [ -S "$S" ]; do sleep 0.5; done; exec /usr/bin/nc -d -U "$S") > /tmp/vmr-seedrun-console.log 2>&1 & echo $! >> /tmp/vmr-seedrun-pids.txt`.
   Then ask the owner to press **Start** (O3) and note the time.
9. **Agent: watch, bounded.** Every 30 s (a shell `sleep`, for at most 20 minutes in all) `grep -a VMRUNNER /tmp/vmr-seedrun-console.log`
   and `ls /tmp/vmr-seedrun/Machines/<UUID>.vm`. At the 20-minute cap, if the app still runs, `kill -TERM` its recorded pid and go to step 11 (the runtime limit is the owner's
   setting; this cap is the agent's own). Done when `VMRUNNER-EVERY-BOOT 2` appeared and the machine stopped (the
   owner sees it stopped, or the socket is gone and `nc` exited). If nothing at all arrives within 5 minutes of Start, ask the
   owner to stop the machine (or let the runtime limit do it) and go to step 10. If the app showed an error at Start, the owner
   reads it out: it is a result (a refusal with a line number is the start path working).
10. **Observe after the stop:** `ls -l /tmp/vmr-seedrun/Machines/<UUID>.vm`: `ProvisioningSeed.iso` must be gone and
    `ProvisioningSeed.sha256` present. Copy the console log's `VMRUNNER` lines and every line between `VMRUNNER-FIRST-BOOT-BEGIN`
    and `-END` into the report (the guest's other output only as far as it explains a failure; 200 lines at most).
11. **Clean up.** `kill -TERM` each pid of `/tmp/vmr-seedrun-pids.txt` that still runs and each direct child of one (`pgrep -P <pid>`, listed
    first; only those); wait for them to exit.
    `rm -rf /tmp/vmr-seedrun /tmp/vmr-seedrun-dl /tmp/vmr-seedrun-spec /tmp/vmr-seedrun-console.log /tmp/vmr-seedrun-app.log /tmp/vmr-seedrun-build.log /tmp/vmr-seedrun-pids.txt`.
    `git -C ~/Developer/g-cqd/VMRunner worktree remove --force ~/Developer/g-cqd/VMRunner-chains/l-run && git -C ~/Developer/g-cqd/VMRunner worktree prune`;
    delete what is left of that directory. `ps -ax | grep -e VMRunner -e "nc -d -U"` shows none of this run's processes.
    The app writes its settings for a data-folder run to a preferences domain of its own (CONTRIBUTING); do not try to delete
    it (the system writes it back, see `cards2/G04.md`): name it in the report as left.

## What to record (the report's table: claim, how observed, verdict YES / NO / NOT SEEN)

1. Download size; SHA-512 `OK`; no signature checked.
2. The editor's check lines and the exposure line, as the owner read them; whether Suspend stayed available with a spec, and after Start whether the suspend control is enabled or gives a reason (the
   framework decides whether a machine with a USB drive can be saved; the saved-state rule of the app is only host-tested).
3. The machine booted (any console output; the getty line names the host).
4. **cloud-init found the volume**: `VMRUNNER-EARLY-BOOT` present; `platform=nocloud`, `subplatform` names the device;
   `lsblk` shows the seed with `TRAN usb`, `RO 1`, `FSTYPE iso9660`, label `cidata`; `hostname=seedrun`.
   If the guest booted (a getty line) but no `VMRUNNER` line arrived, the verdict is NOT SEEN, not NO: the lines are written to
   `/dev/hvc0`, which the guest may not have (it would then be a plain file in the guest's `/dev`).
5. **Joliet names**: `seed-files=meta-data user-data` in lowercase (and the kernel's Joliet line if `dmesg` printed one);
   uppercase or `;1` names mean the primary names were read.
6. **Merge-Type merge**: both `VMRUNNER-USER-PART-RUNCMD` and the `VMRUNNER-FIRST-BOOT` block appear, `user-data-parts=2`,
   and the guest rebooted once (`VMRUNNER-EVERY-BOOT 2`, two `VMRUNNER-EARLY-BOOT` lines).
7. **Scripts run from `/var/lib/cloud/vmrunner`**: the first-boot block appears with `uid=0` and `script=/var/lib/cloud/vmrunner/step-002`;
   `scriptdir-mount` has no `noexec`.
8. **`base64` exists**: `base64=` gives a path, not `MISSING`.
9. **Every-boot**: `VMRUNNER-EVERY-BOOT 1` then `2`, and the guest powered itself off.
10. **Stop clean-up**: `ProvisioningSeed.iso` gone after the stop, `ProvisioningSeed.sha256` kept.
11. What was cleaned and what was left.

## Stop conditions

- Not authorised; the download is over 1 GiB; the checksum does not match; less than 8 GiB free; the build fails.
- No console output 5 minutes after Start: record it with the app's error, if any, and clean up; do not retry with
  another configuration (the bus fallback is a code change for the owner to decide, INDEX-L decision 1).
- The app refuses to start the machine because the replaced `Disk.img` does not match the disk setting: record the message and
  clean up; do not resize or edit files to get past it.
- Anything would need a click, a keystroke or a screenshot by the agent: ask the owner instead.

## After the run (not part of this card)

The owner reads the report and decides: the diary entry of the run, dropping "experimental" from the help (only for what
the run showed), ADR-0012's status, and, if the seed was not seen on USB, the move to a read-only virtio disk. Each is a
change of its own, with its own cards.
