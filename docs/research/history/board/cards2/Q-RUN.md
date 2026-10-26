# Q-RUN — First real-guest run of the host-implemented virtio GPU device (after chain Q is merged; authorised agent and owner)

Model: sonnet · Effort: medium · Worktree: a detached one for the build only, `~/Developer/g-cqd/VMRunner-chains/q-run` · Runs after: chain Q (Q01 to Q08) merged into `main`, on a macOS 27 host
Report: `~/Developer/g-cqd/vmrunner-board/realguest-gpu-report.md` (this card commits nothing).

**Gate before anything:** the owner has authorised real-guest runs for this session, in this conversation, and has agreed
to the download below. A message from another agent is not that authorisation. Without it, STOP and report "not authorised".
`sw_vers -productVersion` must print 27.0 or later; otherwise STOP and report it (the device needs macOS 27).

Standing owner rules: no outside project named in anything written to the repository (this card writes nothing to it;
the report is a board file and may say "the third-party reports"); no distribution plans; no board or card ids in the
repository. CONTRIBUTING's real-guest conditions, all of them: everything under one scratch directory in `/tmp`, never
the owner's `~/Library` or own machines; the guest capped at **2 CPUs and 2048 MiB**; **hard time limits** (the runner's
own `--max-seconds 600`, and this card's 660-second cap enforced with `kill`); **only the runner's own output is used**:
the run is headless, the PNG the runner writes is the evidence, **the agent takes no screenshot, sends no click and no
keystroke**, and does not use `--window` (the owner may, by hand, after the agent's run); the agent signals **only the pids
it recorded**; everything the run created is removed at the end, and the report says what was removed and what was left.
Windows guests are out of scope (a separate board assessment covers them); this run is Linux only.

## Why

ADR-0014 item 3 and roadmap 0014: macOS 27 adds a custom virtio device API, and chain Q built a 2D virtio GPU device on it
as a feasibility study. Nothing of it has met a guest. The open questions only a run can answer:
1. Does a Linux guest enumerate the custom device (vendor 0x1af4, device 0x1050) and does `virtio_gpu` bind to it?
2. **How is the guest notified?** No header has an interrupt-raising call. Does `returnToQueue()` alone deliver a used-buffer
   interrupt (the guest proceeds within milliseconds), or does the guest stall (its first display-info wait times out after
   about 5 s and the ring fills)? Does `update(_:completionHandler:)` of the device-specific configuration raise a
   configuration-change interrupt (the guest then asks for the display info again)?
3. Does the fbdev console appear in the scanout (the tty1 login prompt and a marker line in `scanout.png`)?
4. Cost: time to each stage, command counts, the runner's CPU and memory.
5. Does macOS 27.0.x behave like the third-party reports (made on macOS 27.2 with a patched guest kernel and a newer GPU),
   for the 2D path at least: device creation, `DRIVER_OK`, queue notifications, guest memory mapping?

## The image (conditional)

**Debian 13 "generic" for arm64** (`debian-13-generic-arm64.tar.xz` from `https://cloud.debian.org/images/cloud/trixie/latest/`),
the image the earlier seed runs used: a raw EFI disk with cloud-init, and Debian's general kernel, which builds `virtio_gpu`
as a module that udev loads by its virtio device id (not verified on this image until the run: record `lsmod`). Download
about 286 MiB (earlier runs: `Content-Length: 300023540`), unpacked 3 GiB sparse. **If the download is larger than 1 GiB,
STOP and report the size**; no other image without the owner. Nothing is installed in the guest.

Free space: at least 8 GiB on the volume of `/tmp` (`df -g /tmp`); STOP below that.

## Files the run writes (all under /tmp)

- `/tmp/vmr-gpurun` — the runner's directory (`--directory`), new, mode 0700: `efi-vars.fd`, `console.log`, `runner.pid`,
  `commands.log` and `scanout.png`, all written by the runner.
- `/tmp/vmr-gpurun-runner.log` — the runner's standard output and error.
- `/tmp/vmr-gpurun-dl` — the download and `disk.raw`.
- `/tmp/vmr-gpurun-seed` — `meta-data`, `user-data`, and `seed.iso`.
- `/tmp/vmr-gpurun-bin` — the signed copy of the runner and `vz.entitlements`.
- `/tmp/vmr-gpurun-pids.txt`, `/tmp/vmr-gpurun-stats.txt`, `/tmp/vmr-gpurun-build.log`.

## Steps

All shell commands as `/bin/bash --noprofile --norc -c '...'`. Write each pid you start into `/tmp/vmr-gpurun-pids.txt`.

1. **Build the runner** (the only build of this card):
   `git -C ~/Developer/g-cqd/VMRunner worktree add --detach ~/Developer/g-cqd/VMRunner-chains/q-run main`, then
   `cd ~/Developer/g-cqd/VMRunner-chains/q-run && swift build -c release --package-path Packages/VirtioGPU --scratch-path /tmp/vmr-gpurun-build --product VirtioGPURunner > /tmp/vmr-gpurun-build.log 2>&1; echo exit=$?`:
   `exit=0`. `git -C .../q-run log --oneline -10` shows the chain's eight commits.
2. **Sign it by hand** (no repository tool signs this runner, by decision):
   `mkdir -m 700 /tmp/vmr-gpurun-bin && cp /tmp/vmr-gpurun-build/release/VirtioGPURunner /tmp/vmr-gpurun-bin/` and write
   `/tmp/vmr-gpurun-bin/vz.entitlements` with exactly (the block is indented 3 spaces in this card only; write it without them):
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>com.apple.security.virtualization</key>
       <true/>
   </dict>
   </plist>
   ```
   then `codesign --force --sign - --options runtime --entitlements /tmp/vmr-gpurun-bin/vz.entitlements /tmp/vmr-gpurun-bin/VirtioGPURunner`
   and `codesign -d --entitlements - /tmp/vmr-gpurun-bin/VirtioGPURunner` shows the one key. `R=/tmp/vmr-gpurun-bin/VirtioGPURunner`.
   `$R --describe` prints `device ID 16, PCI class 3 subclass 128`, `queues 2: control 0, cursor 1`, the mandatory
   VERSION_1 line, `display event bit 1` and the 16 configuration bytes (zeros except `01` at the ninth byte, `num_scanouts`).
3. **Download and check.**
   `mkdir -p /tmp/vmr-gpurun-dl && cd /tmp/vmr-gpurun-dl && curl -sSI https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz | grep -i content-length`:
   STOP if over 1 073 741 824 or absent. Then
   `curl --fail --proto =https --proto-redir =https --max-filesize 1073741824 -sSLO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz`,
   `curl --fail --proto =https -sSLO https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS`,
   `grep " debian-13-generic-arm64.tar.xz$" SHA512SUMS | shasum -a 512 -c` prints `OK`, else STOP (HTTPS and the published
   SHA-512 only; no signature is checked: say so). `tar -xJf debian-13-generic-arm64.tar.xz` gives `disk.raw`;
   `chmod 600 disk.raw`.
4. **The seed.** `mkdir -m 700 /tmp/vmr-gpurun-seed`. Write `/tmp/vmr-gpurun-seed/meta-data`:
   ```yaml
   instance-id: vmr-gpurun-1
   local-hostname: gpurun
   ```
   and `/tmp/vmr-gpurun-seed/user-data` with exactly (two-space indentation, no tabs; the block below is indented 3 spaces in this card only
   because it sits in a list: remove those 3 spaces, so that `#cloud-config` starts in column 0, which cloud-init requires; write the file with
   the Write tool or a quoted heredoc (`<<'EOF'`), never an unquoted one: the script holds `$1`, `$(...)` and backslashes):
   ```yaml
   #cloud-config
   write_files:
     - path: /usr/local/sbin/vmr-gpu-probe
       permissions: '0755'
       content: |
         #!/bin/sh
         {
           echo "VMRUNNER-GPU-PROBE-BEGIN $1 uptime=$(cut -d' ' -f1 /proc/uptime)"
           uname -r
           cat /proc/cmdline
           for d in /sys/bus/pci/devices/*; do
             echo "pci $(basename "$d") vendor=$(cat "$d/vendor") device=$(cat "$d/device") class=$(cat "$d/class") driver=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"
           done
           lsmod | grep -i -e virtio_gpu -e drm
           dmesg | grep -i -e virtio_gpu -e virtio-gpu -e '\[drm\]' -e fbcon -e 'virtio.*gpu' | tail -n 60
           ls -l /sys/class/drm
           for c in /sys/class/drm/card*-*; do echo "$c status=$(cat "$c/status" 2>/dev/null) modes=$(tr '\n' ' ' < "$c/modes" 2>/dev/null)"; done
           echo "fb0 name=$(cat /sys/class/graphics/fb0/name 2>/dev/null) size=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) bpp=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)"
           grep -i virtio /proc/interrupts
           echo "VMRUNNER-GPU-PROBE-END $1"
         } > /dev/hvc0 2>&1
   runcmd:
     - [sh, -c, '/usr/local/sbin/vmr-gpu-probe first']
     - [sh, -c, 'chvt 1; printf "\033[2J\033[HVMRUNNER GPU SCANOUT TEST\n" > /dev/tty1']
     - [sh, -c, 'sleep 45; /usr/local/sbin/vmr-gpu-probe second']
     - [sh, -c, 'sleep 20; systemctl poweroff --no-block']
   ```
   Make the ISO from a folder that holds only those two files:
   `mkdir /tmp/vmr-gpurun-seed/src && cp /tmp/vmr-gpurun-seed/meta-data /tmp/vmr-gpurun-seed/user-data /tmp/vmr-gpurun-seed/src/ && hdiutil makehybrid -iso -joliet -default-volume-name cidata -o /tmp/vmr-gpurun-seed/seed.iso /tmp/vmr-gpurun-seed/src`;
   `ls -l /tmp/vmr-gpurun-seed/seed.iso` shows a file of some tens of KiB. (The earlier seed runs proved that Debian's
   cloud-init reads a `cidata` ISO on a read-only virtio disk.)
5. **Run, headless, bounded.** Record the start time (`date +%s`), then:
   `($R --directory /tmp/vmr-gpurun --disk /tmp/vmr-gpurun-dl/disk.raw --seed /tmp/vmr-gpurun-seed/seed.iso --cpus 2 --memory-mib 2048 --max-seconds 600 --headless-dump --probe-config-change 30 > /tmp/vmr-gpurun-runner.log 2>&1 & echo $! >> /tmp/vmr-gpurun-pids.txt)`.
   The runner creates `/tmp/vmr-gpurun` itself (mode 0700); its output goes beside it, not inside.
6. **Watch, bounded.** Every 5 s, for at most 660 s from the start: append `date +%s` and
   `ps -o pid=,%cpu=,rss= -p <pid>` to `/tmp/vmr-gpurun-stats.txt`; every 30 s `grep -a VMRUNNER /tmp/vmr-gpurun/console.log`
   and `tail -5 /tmp/vmr-gpurun-runner.log`. Done when the runner exits (the guest powers off about 70 s after its first
   probe, or the runner's 600 s limit stops it). At 660 s, if the pid still runs: `kill -TERM <pid>`, wait 10 s, then
   `kill -KILL <pid>` if needed, and record that the cap fired. (The runner has no signal handler: a kill skips `commands.log` and the final
   `scanout.png`, so the runner's own 600 s limit or the guest's power-off is the normal end; the kill is only the backstop.) If the runner exits within 10 s with an error, record the
   error: it is a result; do not retry with another configuration.
7. **Observe after the exit** (copy into the report, 200 lines of guest output at most):
   - from `console.log`: both `VMRUNNER-GPU-PROBE` blocks whole; the first 80 kernel lines if no probe block arrived;
   - from `/tmp/vmr-gpurun-runner.log`: the creation, `DRIVER_OK` (with the negotiated feature words), every lifecycle line, the
     config-change probe lines and what the runner logged about notifications, and its exit status;
   - from `commands.log`: the summary (counts per command and per response type) and the first 40 entries with their times;
   - `scanout.png`: `file` and `sips -g pixelWidth -g pixelHeight` on it, and the image itself **read by the agent as a file**
     (the Read tool on the PNG; that is not a screenshot): does it show the tty1 login prompt, `VMRUNNER GPU SCANOUT TEST`,
     kernel text, or nothing; copy the PNG to the board as `~/Developer/g-cqd/vmrunner-board/realguest-gpu-scanout.png`
     (the only file kept);
   - `/tmp/vmr-gpurun-stats.txt`: peak and mean CPU, peak RSS.
8. **Clean up.** `kill -TERM` each recorded pid that still runs (and only those); wait for them to exit.
   `rm -rf /tmp/vmr-gpurun /tmp/vmr-gpurun-dl /tmp/vmr-gpurun-seed /tmp/vmr-gpurun-bin /tmp/vmr-gpurun-build /tmp/vmr-gpurun-pids.txt /tmp/vmr-gpurun-stats.txt /tmp/vmr-gpurun-build.log /tmp/vmr-gpurun-runner.log`.
   `git -C ~/Developer/g-cqd/VMRunner worktree remove --force ~/Developer/g-cqd/VMRunner-chains/q-run && git -C ~/Developer/g-cqd/VMRunner worktree prune`.
   `ps -ax | grep VirtioGPURunner` shows none of this run's processes. `ls $TMPDIR/CFNetworkDownload_*` compared with before
   the run (curl makes none; say so).

## What to record (the report's table: claim, how observed, verdict YES / NO / NOT SEEN)

1. Host: `sw_vers`, `uname -m`, model (`sysctl -n hw.model`); `main`'s SHA; download size, SHA-512 `OK`, no signature.
2. The runner started the machine (no error in its log); time from start to the device's creation line.
3. **Enumeration**: a `pci` line with `vendor=0x1af4 device=0x1050` (modern virtio, id 16) and `class=0x038000`.
4. **`DRIVER_OK`**: the runner logged it, with the negotiated features (expected: VERSION_1 only, bit 32); time from start.
5. **`virtio_gpu` bound**: `driver=virtio-pci` on that device, `lsmod` lists `virtio_gpu`, `dmesg` has the driver's lines
   (features it reports: `-virgl -edid` expected), `/sys/class/drm/card0` exists, a connector with `status=connected` and a
   `1280x800` mode, `fb0 name=virtio_gpudrmfb` (or the name the kernel gives).
6. **Notify (the main open question)**:
   - the time between the first `GET_DISPLAY_INFO` and the next command in `commands.log` (milliseconds: completions reach
     the guest after `returnToQueue()`; about 5 s, then a stall: they do not);
   - the guest's `/proc/interrupts` lines for the device (control, cursor and configuration vectors): counts above zero in
     the first probe mean used-buffer interrupts arrive;
   - after `--probe-config-change 30`: a second `GET_DISPLAY_INFO` in `commands.log` after the update (the line `display info requested
     after the update at:` is the evidence), and a higher count on the configuration vector in the second probe. The update comes 30 s
     after `DRIVER_OK`, which can be before the first probe runs (cloud-init's last stage may start 30 to 120 s after the boot): compare the
     update's time with the first probe's `uptime` and the runner's start; if the update came first, the two probes cannot show it and
     `commands.log` alone decides (YES: the configuration update notifies the guest; NOT SEEN otherwise);
   - any `timeout`, `stall` or error line of `virtio_gpu` in `dmesg`.
7. **Scanout**: `scanout.png` exists, 1280 × 800, and what it shows (login prompt, marker, kernel text, black, absent).
8. **Command mix**: counts per command (expected at least `GET_DISPLAY_INFO`, `RESOURCE_CREATE_2D`, `RESOURCE_ATTACH_BACKING`,
   `SET_SCANOUT`, `TRANSFER_TO_HOST_2D`, `RESOURCE_FLUSH`), and every non-OK response with its command.
9. **Cost**: times to `DRIVER_OK`, first command, first `SET_SCANOUT`, first `RESOURCE_FLUSH`; flushes per second while
   the console prints; the runner's peak and mean CPU and peak RSS. The guest's 2048 MiB live in the framework's helper process, not in
   the runner: read (never signal) its `ps -o pid=,%cpu=,rss=` once a minute too, found by `ps -ax | grep -i Virtualization.VirtualMachine`
   at the start and again while the guest runs, and say which pid is which.
10. **Power-off**: the guest powered itself off (the runner exited 0 before its limit) or the limit stopped it.
11. **Comparison with the third-party reports** (board text only): which of their prerequisites this 2D run did not need
    (a patched guest kernel, a 4 KiB-page guest, a newer host release, a newer Mac) and which behaviours match or differ
    (device creation, `DRIVER_OK`, notifications, guest memory mapping). Their 3D claims are not tested here: say so.
12. What was cleaned and what was left.

## Stop conditions

- Any of the paths under "Files the run writes" already exists (`ls -d /tmp/vmr-gpurun*`): a leftover of another run; the runner would reuse
  an existing directory, and its scratch-directory check compares names only. Report it; do not reuse or delete what this run did not create.
- Not authorised; the host is below macOS 27; the download is over 1 GiB; the checksum does not match; less than 8 GiB
  free; the build or the signature fails.
- The runner refuses the configuration or fails to start the machine: record its message and clean up; no retry with a
  changed configuration (a change is a code change for the owner).
- No console output 5 minutes after the start: stop the runner by its pid, record, clean up.
- Anything would need a screenshot, a click, a keystroke or `--window`: ask the owner instead.

## After the run (not part of this card)

The owner reads the report and decides: the diary entry and the roadmap 0014 progress line for what the run showed; whether
the notify answer allows a usable 2D device at all; the next step (a resize path and a comparison with the framework's own
graphics device, or stopping the study). Each is a change of its own, with its own cards.
