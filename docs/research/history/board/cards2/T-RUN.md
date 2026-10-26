# T-RUN — First real-guest run of the app's custom GPU: which input path, resize, cursor, cost (after chain T is merged; authorised agent and owner)

Model: sonnet · Effort: medium · Worktree: a detached scratch one under `/tmp`, built with `swift run vmr build-app` (below) · Runs after: chain T (T01 to T14) merged into `main`, on a macOS 27 host
Report: `~/Developer/g-cqd/vmrunner-board/realguest-customgpu-report.md` (this card commits nothing).

This run drives **the app** (`VMRunner.app`, built from the chain), not the runner of the earlier GPU run. The guest is the same
Debian 13 arm64 cloud image as that run. Two people take part: the **agent** (starts, watches, records, cleans up) and the
**owner** (the only one who types, clicks, scrolls and resizes, in the app's own window).

**Gate before anything:** the owner has authorised real-guest runs for this session, in this conversation, and has agreed to
(1) the download of the Debian image below (about 286 MiB), (2) sitting at the Mac for about 10 minutes per sub-run and using the
app's window by hand as the script below says, (3) the agent reading the app's own window through Accessibility (read only; no
screenshot or capture of any kind is taken in this run). A message from another agent is not that authorisation. Without it, STOP and report "not
authorised". Write the owner's authorising words and the time into the report.

Standing owner rules: no outside project named in anything written to the repository (this card writes nothing to it; the report
is a board file); no distribution plans; no board or card ids in the repository. CONTRIBUTING's real-guest conditions, all of them:
everything under scratch paths in `/tmp` (`VMRUNNER_DATA_DIR`), never the owner's `~/Library/Application Support/VMRunner`, never
the owner's own machines; the guest capped at **2 CPUs and 2048 MiB**; **hard time limits** (the machine's runtime limit of 15
minutes, this card's own 20-minute cap per sub-run enforced with `kill`, and 100 minutes for the whole card); **only the app's own
window** is read or driven, through Accessibility on the pid of the scratch app and nothing else, and **no screenshot or window capture is taken**; **the agent sends no keystroke
and no click, never brings a window to the front, and never captures the screen**; the agent signals only the pids it recorded;
everything the run created is removed at the end, and the report says what was removed and what was left. Windows guests are out of
scope. Run every shell command as `/bin/bash --noprofile --norc -c '...'` (the login shell is fish: no heredocs, and `=` globs
fail); write every file with the Write tool, exactly as given below (the blocks in this card are not indented, so `#cloud-config`
is in column 0 where cloud-init needs it).

## Why

Chain T put the host-implemented virtio GPU into the app (a Linux machine whose graphics is "Custom (experimental)"): its picture
and cursor in the machine's window, the display following the window, and **two ways to carry the keyboard and pointer**, chosen by
a developer default read once at each start: `framework` (the default; the machine keeps the framework's USB keyboard and pointer,
fed by a hidden framework view) or `virtio` (two virtio input devices the app implements, and no USB input). Nothing of it has met
a guest. The roadmap's "Remaining" list names what only a run answers, and this card answers it:

1. **Input.** Which path works: does the guest bind the devices, how does it classify them, does every key arrive, does the pointer
   land where it should (corners), does scroll work, does a key stay stuck after the window loses the keyboard? Sub-run A is the
   `framework` path, sub-run B the `virtio` path; the guest, the script and the owner's actions are the same.
2. **Resize.** Does the first resize reach the guest, and does the second (the clear-then-set writes exist for the second)?
3. **Cursor and its alpha.** A text console draws no pointer, so this needs a graphical session: optional sub-run D.
4. **Cost** against the framework's own graphics device: optional sub-run C (`gpu: apple`), same script.
5. **Stability.** Does the app survive all of it (the framework raises on element misuse: a crash is a result).

## Facts read from the code (chain tip `ae136ef699bb3afab6648137bd50382efa6ca3ac`, on `2974518`; paths from the repository root)

Read, not run on a guest. Where one proves wrong, record the real behaviour: that is a result.

| Fact | Where |
|---|---|
| A machine is the folder `<data>/Machines/<UUID>.vm` holding `config.json`, `Disk.img`, `EFIVariables.fd`, `MachineIdentifier`; the folder name is `"<id.uuidString>.vm"` (upper-case UUID) | `Sources/VMRunner/Model/Storage.swift:121,124,125,128,129` |
| A bundle whose folder name differs from its `id` is ignored | `Sources/VMRunner/Model/VMLibrary.swift:140` |
| A Linux machine boots the existing `Disk.img` with no setup when `isProvisioned` is true; setup itself would make the EFI store and machine identifier, which the run must make by hand (the start only references them) | `Sources/VMRunner/Model/VMLibrary.swift:357` (`startMachine` guard), `Sources/VMRunner/Engine/Provisioner.swift:49-50`, `Sources/VMRunner/Engine/ConfigurationBuilder.swift:158` |
| `config.json` is decoded over the defaults of a new Linux machine, so missing keys are filled; values are validated; an unknown `gpu` reads as `apple` | `Sources/VMRunner/Model/VMConfig.swift:264`, `Sources/VMRunner/Model/VMConfig+Validation.swift:35` |
| The keys the run writes: `id`, `name`, `guest`, `isProvisioned`, `cpuCount`, `memoryMiB`, `diskGiB`, `networkMode`, `serialConsole`, `gpu`, `sharesClipboard`, `audioOutput`, `maxRuntimeMinutes`, `extraDisks` | `Sources/VMRunner/Model/VMConfig.swift:122,140,159,203,228` |
| **The cloud-init seed**: `provisioningSpecPath` would compile a spec into `ProvisioningSeed.iso`; an **extra disk with `readOnly: true`** is a virtio block disk and can carry the hdiutil-made `cidata` ISO as it is. The run uses the extra disk. Its path must be absolute, exist, and not lie inside `Machines/` | `Sources/VMRunner/Engine/ConfigurationBuilder.swift:207-215`, `Sources/VMRunner/Model/VMConfig+Validation.swift:67` |
| An extra disk is a host path that needs approval; a data folder whose `Machines.approvals.json` does not exist when the app first loads **grandfathers** the machines already in it, so no approval prompt appears. A file that exists and approves nothing does not (checked by a test, below) | `Sources/VMRunner/Model/VMLibrary.swift:106-107`, `Sources/VMRunner/Model/HostPathApprovals.swift:66,101`, `VMLibrary.swift:356-365` |
| **The serial console is a local socket, not a log file**: `Console.sock` in the bundle (or, if the bundle path is over 103 bytes, in a short folder of `$TMPDIR`); the guest's first virtio console port, `hvc0`. Only a client connected to it sees the output | `Sources/VMRunner/Engine/ConfigurationBuilder.swift:80-102`, `Sources/VMRunner/Model/ConsoleSocketPlacement.swift:23-28`, `Sources/GuestConsole/ConsoleSocket.swift:27` |
| `--start <name or uuid>` starts the machine at launch with no button and no approval prompt for approved paths; `--display-diagnostics` logs every step of the resize | `Sources/VMRunner/VMRunnerApp.swift:56-62`, `Sources/VMRunner/Model/DisplayDiagnostics.swift:12` |
| The bundle identifier of the built app is `com.example.VMRunner`; the app logs under it; with `VMRUNNER_DATA_DIR` set its settings live in the defaults domain `<identifier>.data-directory-override` | `Resources/Info.plist:5`, `Sources/VMRunner/Model/Log.swift:11`, `Sources/VMRunner/Model/PreferencesDomain.swift:6,11` |
| The developer default is `CustomGPUInput` (`framework` or `virtio`, anything else is `framework`), read once at each machine start from that domain | `Sources/VMRunner/Engine/CustomGPU/CustomGPUInputPath.swift:15,21`, `Sources/VMRunner/Engine/VZGuestMachine.swift:127` |
| With the `virtio` path the machine has **no** USB keyboard and pointer; with `framework` it has them; the GPU is a custom virtio device in both | `Sources/VMRunner/Engine/ConfigurationBuilder+Screen.swift:18-29` |
| The virtio tablet reports `ABS_X` and `ABS_Y` over 259 to 16384 (0x103 to 0x4000); the keyboard maps Mac key codes to Linux key codes (Delete 14, Command 125, Option 56, Control 29, Caps Lock 58) | `Sources/VirtioInput/VirtioInputStaticConfig.swift:53-58`, `Sources/VirtioInput/VirtioKeyMap.swift` |
| The app logs, always, whether the guest answered each resize (`Display resize: guest responded` or `did not respond`, and `asking again`); it does **not** log the device's GET_DISPLAY_INFO requests, and logs custom-device trouble only once per kind | `Sources/VMRunner/Views/Machine/VMDisplay.swift:106-116`, `Sources/VMRunner/Engine/CustomGPU/CustomGPUDevice.swift:132`, `TroubleLog.swift` |
| The guest has answered a resize when it flushes a picture of the requested size; the follower asks again at 2, 4, 8, 16, then every 30 s | `Sources/VMRunner/Engine/CustomGPU/CustomGPUResizableDisplay.swift`, `Sources/VMRunner/Model/DisplayFollower.swift` |
| Losing the key window releases the keys and buttons held, on the virtio path only (the framework's view is left to itself) | `Sources/VMRunner/Views/Machine/CustomGPUView.swift:49`, `Sources/VMRunner/Engine/CustomGPU/VirtioInputSurface.swift`, `FrameworkInputSurface.swift` |
| The runtime limit asks the guest to shut down, then forces the stop 30 s later | `Sources/VMRunner/Model/RuntimeLimit.swift:9` |
| Isolated and Hardened force Apple's device (`gpu = .apple`) and close the console, extra disks and network; an organisation can force `apple` with `AllowCustomGPU`. The run keeps the Standard posture | `Sources/VMRunner/Model/Security.swift:129`, `Sources/VMRunner/Model/ManagedPreferences.swift:93` |
| `swift run vmr build-app` builds only the app's product (release by default), assembles `build/VMRunner.app` under the package root, ad-hoc signs it with the hardened runtime and `Resources/VMRunner.entitlements` (virtualization and audio input), and verifies the result | `Sources/DevTools/App/AppBundler.swift:24,12`, `Sources/DevTools/CLI/BuildAppCommand.swift`, `Resources/VMRunner.entitlements` |

## Assumptions (unverified until the run; record the real answer where it differs)

1. The Debian 13 generic arm64 kernel binds `virtio_input` to the two virtio input devices (PCI device `0x1052`), exposes
   `/dev/input/event*` and has `evdev`; its console reaches `fb0` on the custom GPU as in the earlier GPU run.
2. `python3` is in the image (the cloud-init package depends on it): the guest reads input devices with a small Python script
   instead of `evtest`, so **no package is installed and no network is needed** (NAT stays on only to keep cloud-init's boot short:
   the earlier seed runs printed their first line 45 s after Start). `evtest` and `kbd` are therefore not used.
3. `/dev/hvc0` is the serial console the app serves (the earlier seed runs printed on it). `/dev/console` is **not** used: on this
   image it is `tty0`.
4. The autologin drop-in for `getty@tty1` works with the user cloud-init creates; if it does not, the tty1 prompt shows and the
   owner logs in as `vmr` with the password `vmr-customgpu` (a throwaway guest account, no ssh with a password).
5. The Mac's keyboard layout does not matter: both paths send **physical key positions**, which the guest reads as a US layout.
   The owner types by position (the script says which keys) and the agent compares **key codes**, not the letters on the screen.
6. The guest's clock and the Mac's agree to a few seconds; the run does not depend on it (the host stamps each console line itself).
7. A text console sends no cursor commands, so cursor and alpha are NOT SEEN without sub-run D (the earlier GPU run counted none).
   D installs about 100 MB of X packages over NAT and its recipe has never run: if X does not come up, record the log and stop D.
8. Clipboard sharing is **not tested**: the image has no spice agent and a text console has no clipboard; `sharesClipboard` and
   `audioOutput` are off (devices the run does not use).
9. The Accessibility permission is the one of the program that runs the agent's commands; if `ax` answers "not trusted", the run
   continues without it (the owner reads the window state out; a stop is by the guest's own power-off, the runtime limit, or
   `kill -TERM` of the scratch app's pid at the cap).

## Files and processes the run creates

All paths below come from `/tmp/vmr-customgpu-run.env`, written by step 1 (`TS` is `date +%m%d%H%M%S`, ten digits, so that the
console socket path stays under 103 bytes):

| Variable | Path | Holds |
|---|---|---|
| env file | `/tmp/vmr-customgpu-run.env` | the variables below |
| `DATA` | `/tmp/vmr-customgpu-run-$TS` | `VMRUNNER_DATA_DIR`: the app's data folder, new, mode 0700 |
| `DL` | `/tmp/vmr-customgpu-run-$TS-dl` | the download only: tarball, `SHA512SUMS`, `disk.raw` (untrusted data; nothing is run from here) |
| `SEED` | `/tmp/vmr-customgpu-run-$TS-seed` | `src/user-data`, `src/meta-data`, `seed.iso`, and for D `src-x/`, `seed-x.iso` |
| `TOOLS` | `/tmp/vmr-customgpu-run-$TS-tools` | the scripts and the two small programs this card gives (your own files, not downloaded) |
| `NOTES` | `/tmp/vmr-customgpu-run-$TS-notes` | `pids.txt`, `ids.txt`, build log, per-run folders `A/`, `B/`, ... |
| `SRC` | `/tmp/vmr-customgpu-run-$TS-src` | the detached worktree; the app is `$SRC/build/VMRunner.app` (`APP`) |
| defaults | `~/Library/Preferences/com.example.VMRunner.data-directory-override.plist` | the one setting for sub-run B |

Processes: the scratch app (one per sub-run), a console reader (`nc` and a timestamper), a sampler. The Virtualization framework
starts its own helper process for each running machine (not a child of the app): the run **reads** it (`ps`) and records its pid.

## Steps

### Preconditions (STOP and report if any fails)

P1. Authorisation (above). P2. `sw_vers -productVersion` prints `27.` something (the custom device needs macOS 27); record
`sw_vers`, `uname -m`, `sysctl -n hw.model`. P3. `df -g /tmp` shows at least 15 free GiB in the "Avail" column.
P4. **No other VMRunner is running**: `pgrep -x VMRunner` prints nothing (do not signal one that does). P5. **Nothing of an
earlier run is left**: `ls -d /tmp/vmr-customgpu-run*` prints nothing (it prints "No such file"): a leftover is reported, never
reused or deleted. P6. `defaults read com.example.VMRunner.data-directory-override` answers `does not exist` (the run owns that
domain; if it exists, STOP and report). P7. No organisation policy turns the custom GPU off:
`defaults read com.example.VMRunner AllowCustomGPU` answers `does not exist` or `1`, and `ls "/Library/Managed Preferences" | grep -i vmrunner` prints nothing.
P8. The chain is in the code that will be built: either it is merged, `git -C ~/Developer/g-cqd/VMRunner log main --oneline | grep -F "Add a virtio input path for the custom GPU, beside the framework"`
prints one line (then `COMMIT=main`); or the owner says in this conversation to build the chain before it is merged, and names where
it is: build from the chain's worktree `~/Developer/g-cqd/VMRunner-chains/t-custom-gpu` (branch `chain/t-custom-gpu`)
after T01 to T14 are applied, or from `main` once merged. The expected final tree of the chain on `2974518` is
`78030571a0274a7b2db250e8674ad349db4b718f` (on another base the tree differs). Neither: STOP.

### 1. The run's variables and folders (the fresh-path check)

```
/bin/bash --noprofile --norc -c 'set -eu; if ls -d /tmp/vmr-customgpu-run* > /dev/null 2>&1; then echo "STOP: a leftover exists"; ls -d /tmp/vmr-customgpu-run*; exit 1; fi; TS=$(date +%m%d%H%M%S); P=/tmp/vmr-customgpu-run-$TS; { echo "TS=$TS"; echo "DATA=$P"; echo "DL=$P-dl"; echo "SEED=$P-seed"; echo "TOOLS=$P-tools"; echo "NOTES=$P-notes"; echo "SRC=$P-src"; echo "APP=$P-src/build/VMRunner.app"; echo "REPO=~/Developer/g-cqd/VMRunner"; } > /tmp/vmr-customgpu-run.env; for d in "$P" "$P-dl" "$P-seed" "$P-tools" "$P-notes"; do mkdir -m 700 "$d"; done; cat /tmp/vmr-customgpu-run.env; ls -ld /tmp/vmr-customgpu-run-*'
```

Expected: nine variable lines, then five directories, each `drwx------`. A `mkdir` that fails because the path exists is the
STOP of P5. From here every command starts with `. /tmp/vmr-customgpu-run.env;` inside `bash -c`. Record the cap: the clock time
of this step is the start of the 100-minute budget.

### 2. Build the app (the only build of this card)

With `COMMIT=main` (P8):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; git -C "$REPO" worktree add --detach "$SRC" main && git -C "$SRC" log --oneline -16 && git -C "$SRC" rev-parse HEAD'
```

(If the owner chose the unmerged chain: `git clone --no-hardlinks ~/Developer/g-cqd/VMRunner-chains/t-custom-gpu "$SRC"` instead
(it checks out the branch `chain/t-custom-gpu`); on base `2974518` the tree printed by `git -C "$SRC" rev-parse HEAD^{tree}` is
`78030571a0274a7b2db250e8674ad349db4b718f`. It touches nothing of the owner's repository.) The log shows the chain's commits, the newest being "Add a virtio input path for the custom GPU,
beside the framework's" (or later ones). Then, in the background (it takes minutes; the earlier app build took 55 s warm):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; cd "$SRC" && swift run vmr build-app > "$NOTES/build.log" 2>&1; echo exit=$?'
```

Expected `exit=0`, `$APP` exists, and:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; ls -ld "$APP"; codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|flags|Signature"; codesign -d --entitlements - "$APP" 2>&1 | grep -E "com.apple"; ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"); echo "ID=$ID" >> /tmp/vmr-customgpu-run.env; echo "DOMAIN=$ID.data-directory-override" >> /tmp/vmr-customgpu-run.env; grep -c CustomGPUInput "$SRC/Sources/VMRunner/Engine/CustomGPU/CustomGPUInputPath.swift"; tail -3 "$NOTES/build.log"'
```

Expected: `flags=0x10002(adhoc,runtime)`, the entitlements `com.apple.security.virtualization` and
`com.apple.security.device.audio-input` and nothing else, the identifier `com.example.VMRunner`, and `1` or more for the grep. If
`ID` is not `com.example.VMRunner`, use the printed one everywhere (the later commands read `$ID` and `$DOMAIN`). Check
`grep -F "ID=" /tmp/vmr-customgpu-run.env` shows the two new lines.

### 3. Download and check the image (same as the earlier GPU run)

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; cd /; curl -sSIL --proto =https --proto-redir =https https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.tar.xz | grep -i -E "^HTTP|^location|^content-length"'
```

The first answer is a `302` to a mirror, the last `200` with `Content-Length: 300023540` when this card was written. **STOP if the
last length is absent or over 1 073 741 824**; any other size under 1 GiB is recorded. Then:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; cd /; U=https://cloud.debian.org/images/cloud/trixie/latest; curl --fail --proto =https --proto-redir =https --max-filesize 1073741824 -sSL -o "$DL/debian-13-generic-arm64.tar.xz" $U/debian-13-generic-arm64.tar.xz && curl --fail --proto =https --proto-redir =https -sSL -o "$DL/SHA512SUMS" $U/SHA512SUMS && stat -f %z "$DL/debian-13-generic-arm64.tar.xz" && want=$(awk "\$2 == \"debian-13-generic-arm64.tar.xz\" { print \$1 }" "$DL/SHA512SUMS") && have=$(shasum -a 512 "$DL/debian-13-generic-arm64.tar.xz" | awk "{ print \$1 }") && { [ -n "$want" ] && [ "$want" = "$have" ] && echo "SHA-512 OK" || echo "SHA-512 MISMATCH"; }'
```

Expected: the byte size (equal to the Content-Length), `SHA-512 OK`. Anything else: STOP (HTTPS and the vendor's published SHA-512
only; **no signature is checked**: say so in the report). Unpack, checking the listing first:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; cd /; tar -tJf "$DL/debian-13-generic-arm64.tar.xz"'
```

It lists exactly `disk.raw` (anything else: STOP). Then
`/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; cd /; tar -xJf "$DL/debian-13-generic-arm64.tar.xz" -C "$DL" disk.raw && chmod 600 "$DL/disk.raw" && ls -l "$DL/disk.raw" && file "$DL/disk.raw"'`:
a raw disk of 3 221 225 472 bytes whose `file` line mentions a boot sector or a partition table (the image is already raw: no conversion; the earlier runs used it as it is).

### 4. The seed (the guest's script)

Write `$SEED/src/meta-data` (create the folder first: `mkdir -m 700 "$SEED/src"`) with exactly:

```
instance-id: vmr-customgpu-1
local-hostname: cgrun
```

and `$SEED/src/user-data` with exactly the following (two-space YAML indentation, no tabs; it carries three scripts, which are the
guest's whole part of the run: read them before using them. It installs nothing. The two lines `#VMR-X-...` are comments here and
only sub-run D replaces them):

```
#cloud-config
users:
  - name: vmr
    gecos: custom GPU run
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: vmr-customgpu
ssh_pwauth: false
#VMR-X-UPDATE
#VMR-X-PACKAGES
write_files:
  - path: /etc/systemd/system/getty@tty1.service.d/vmr-autologin.conf
    permissions: '0644'
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear --autologin vmr %I $TERM
  - path: /etc/systemd/system/vmr-run.service
    permissions: '0644'
    content: |
      [Unit]
      Description=custom GPU run: probe, input reader and phases
      [Service]
      Type=simple
      ExecStart=/usr/local/sbin/vmr-probe
      StandardOutput=null
      StandardError=null
  - path: /usr/local/sbin/vmr-probe
    permissions: '0755'
    content: |
      #!/bin/sh
      # Runs as root from vmr-run.service once per boot. Everything it reports goes to the serial console, /dev/hvc0, between
      # markers that start with VMRUNNER-CG-. The phases the person at the window follows are also written to tty1.
      C=/dev/hvc0
      up() { cut -d' ' -f1 /proc/uptime; }
      say() { printf '%s\n' "$*" > "$C"; }

      probe() {
        {
          echo "VMRUNNER-CG-PROBE-BEGIN $1 uptime=$(up)"
          uname -r
          cat /proc/cmdline
          echo "--- /proc/bus/input/devices"
          cat /proc/bus/input/devices
          for n in /sys/class/input/event*; do
            [ -e "$n" ] || continue
            node=$(basename "$n")
            echo "udev $node: $(udevadm info -q property -n "/dev/input/$node" 2>/dev/null | grep -E '^(ID_BUS|ID_INPUT[A-Z_]*|ID_VENDOR_ID|ID_MODEL_ID)=' | tr '\n' ' ')"
          done
          ls -l /dev/input
          echo "--- modules"
          lsmod | grep -i -E 'virtio|hid|usb|evdev|drm'
          echo "--- pci"
          for d in /sys/bus/pci/devices/*; do
            echo "pci $(basename "$d") vendor=$(cat "$d/vendor") device=$(cat "$d/device") class=$(cat "$d/class") driver=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"
          done
          echo "--- display"
          ls -l /sys/class/drm
          for c in /sys/class/drm/card*-*; do
            [ -e "$c/modes" ] || continue
            echo "$c status=$(cat "$c/status" 2>/dev/null) modes=$(tr '\n' ' ' < "$c/modes" 2>/dev/null)"
          done
          echo "fb0 name=$(cat /sys/class/graphics/fb0/name 2>/dev/null) size=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) bpp=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)"
          echo "tty1 size=$(stty size < /dev/tty1 2>/dev/null)"
          grep -i -E 'virtio|xhci|usb' /proc/interrupts
          echo "--- kernel log"
          dmesg | grep -i -E 'virtio|input|drm|usb|hid|fbcon|evdev' | tail -n 120
          echo "--- tools"
          command -v python3 evtest Xorg
          python3 --version
          if [ -r /var/log/Xorg.0.log ]; then
            echo "--- Xorg log"
            grep -E '\(EE\)|\(WW\)|modeset|libinput|cursor' /var/log/Xorg.0.log | tail -n 40
          fi
          if [ -s /var/log/vmr-xinit.log ]; then
            echo "--- xinit log"
            tail -n 20 /var/log/vmr-xinit.log
          fi
          echo "VMRUNNER-CG-PROBE-END $1"
        } > "$C" 2>&1
      }

      # The text on tty1 as the guest holds it (what was typed, as the guest drew it), without blank lines.
      snap() {
        label=$1
        size=$(stty size < /dev/tty1 2>/dev/null)
        cols=${size#* }
        {
          echo "VMRUNNER-CG-SCREEN-BEGIN $label uptime=$(up) tty1=$size"
          fold -b -w "${cols:-160}" /dev/vcs1 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$'
          echo "VMRUNNER-CG-SCREEN-END $label"
        } > "$C" 2>&1
      }

      # One line about the display the guest sees, repeated every 15 seconds, so a resize shows as a changed first mode.
      displayline() {
        for c in /sys/class/drm/card*-*; do
          [ -e "$c/modes" ] || continue
          say "VMRUNNER-CG-DRM uptime=$(up) $(basename "$c") status=$(cat "$c/status") first=$(head -n 1 "$c/modes") modes=$(wc -l < "$c/modes") fb0=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) tty1=$(stty size < /dev/tty1 2>/dev/null) who=$(who | tr '\n' ';')"
        done
      }

      phase() {
        say "VMRUNNER-CG-PHASE $1 uptime=$(up)"
        printf '\n==== PHASE %s: %s ====\n' "$1" "$2" > /dev/tty1
        printf '\n==== PHASE %s: %s ====\n' "$1" "$2" >> /run/vmr-banner
      }

      S=$(cut -d. -f1 /proc/uptime)
      wait_until() { while [ $(( $(cut -d. -f1 /proc/uptime) - S )) -lt "$1" ]; do sleep 1; done; }

      : > /run/vmr-banner
      sleep 2
      probe first
      snap start

      # A graphical session, only where the optional packages were installed: X on its own console, with the same banners in a window.
      xorg=$(command -v Xorg || true)
      if [ -n "$xorg" ] && command -v xinit > /dev/null 2>&1; then
        say "VMRUNNER-CG-XMODE starting uptime=$(up) server=$xorg"
        (xinit /usr/local/sbin/vmr-xclient -- "$xorg" :0 vt7 -nolisten tcp -noreset > /var/log/vmr-xinit.log 2>&1 &)
        sleep 10
      fi

      (while :; do displayline; sleep 15; done) &
      (dmesg -W 2> /dev/null | grep --line-buffered -i -E 'drm|virtio|fbcon|input|usb|hid' | sed -u 's/^/VMRUNNER-CG-DMESG /' > "$C") &

      python3 /usr/local/sbin/vmr-input-reader 420 &
      reader=$!
      S=$(cut -d. -f1 /proc/uptime)

      phase 1 "TYPE AND POINT for 2 minutes: keys, then the pointer to the four corners, clicks, scroll"
      wait_until 115; snap after-typing
      phase 2 "RESIZE the window by dragging an edge, wait 20 s, then resize it again"
      wait_until 205; snap after-resize
      phase 3 "FULL SCREEN: enter it, wait 10 s, leave it"
      wait_until 255; snap after-fullscreen
      phase 4 "FOCUS LOSS: hold K, click another window of yours, release K there, come back"
      wait_until 315; snap after-focus-loss
      phase 5 "HANDS OFF: the guest scrolls its screen for 30 s"
      timeout 30 yes 'VMRUNNER-LOAD 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ' > /dev/tty1
      wait_until 350
      phase 6 "HANDS OFF: nothing to do, the guest is idle"
      wait_until 410; snap end
      wait "$reader"
      probe last
      sleep 3
      say "VMRUNNER-CG-POWEROFF uptime=$(up)"
      systemctl poweroff
  - path: /usr/local/sbin/vmr-input-reader
    permissions: '0755'
    content: |
      #!/usr/bin/python3
      # Reads every /dev/input/event* for the number of seconds given as the first argument and prints what arrives to the
      # serial console (/dev/hvc0), one line per key or button event, a sample of the pointer's movement, and a summary every
      # 10 seconds. Nothing is sent to any input device and no device is grabbed.
      import glob
      import os
      import select
      import struct
      import sys
      import time

      WINDOW = float(sys.argv[1])
      EVENT = struct.Struct("llHHi")  # struct input_event on a 64-bit kernel: time (two 8-byte numbers), type, code, value
      TYPES = {0: "SYN", 1: "KEY", 2: "REL", 3: "ABS", 4: "MSC", 5: "SW", 17: "LED", 18: "SND", 20: "REP"}
      ABS_INTERVAL = 0.05
      SETTLE_AFTER = 0.3
      SUMMARY_INTERVAL = 10.0
      RESCAN_INTERVAL = 5.0

      console = open("/dev/hvc0", "w", buffering=1)
      start = time.monotonic()


      def say(text):
          console.write("VMRUNNER-CG-" + text + "\n")


      def stamp():
          return "t=%.3f e=%.3f" % (time.monotonic() - start, time.time())


      def read_name(node):
          try:
              with open("/sys/class/input/%s/device/name" % node, "rb") as handle:
                  return handle.read().strip().decode("latin-1")
          except OSError:
              return ""


      class Device:
          def __init__(self, path, fd):
              self.path = path
              self.node = os.path.basename(path)
              self.fd = fd
              self.name = read_name(self.node)
              self.counts = {}  # type name -> number of events
              self.keys = {}  # key code -> [presses, releases, repeats]
              self.down = set()  # key codes pressed and not yet released
              self.axes = {}  # (type name, code) -> [minimum, maximum, last, printed]
              self.first = None  # time of the first event that is not a SYN
              self.last = None  # time of the last one
              self.last_event = 0.0
              self.last_printed = {}  # (type name, code) -> time of the last printed line
              self.dirty = True


      def event_line(device, kind, code, value, tag="EV"):
          say("%s %s dev=%s %s code=%d value=%d" % (tag, stamp(), device.node, kind, code, value))


      def handle(device, etype, code, value):
          now = time.monotonic() - start
          kind = TYPES.get(etype, "T%d" % etype)
          device.counts[kind] = device.counts.get(kind, 0) + 1
          device.dirty = True
          if etype == 0:
              return
          if device.first is None:
              device.first = now
          device.last = now
          device.last_event = now
          if etype == 1:
              entry = device.keys.setdefault(code, [0, 0, 0])
              if value == 1:
                  entry[0] += 1
                  device.down.add(code)
              elif value == 0:
                  entry[1] += 1
                  device.down.discard(code)
              else:
                  entry[2] += 1
              event_line(device, kind, code, value)
          elif etype == 3:
              axis = device.axes.setdefault((kind, code), [value, value, value, True])
              axis[0] = min(axis[0], value)
              axis[1] = max(axis[1], value)
              axis[2] = value
              if now - device.last_printed.get((kind, code), -1.0) >= ABS_INTERVAL:
                  device.last_printed[(kind, code)] = now
                  axis[3] = True
                  event_line(device, kind, code, value)
              else:
                  axis[3] = False
          else:
              event_line(device, kind, code, value)


      def settle(device):
          """Prints the position the pointer came to rest at, if the last movement was not printed."""
          if time.monotonic() - start - device.last_event < SETTLE_AFTER:
              return
          for (kind, code), axis in sorted(device.axes.items()):
              if not axis[3]:
                  axis[3] = True
                  event_line(device, kind, code, axis[2], tag="SETTLED")


      def summary(device, label):
          keys = " ".join("%d:%d/%d/%d" % (code, *entry) for code, entry in sorted(device.keys.items()))
          axes = " ".join("%s%d=[%d..%d last %d]" % (kind, code, *axis[:3]) for (kind, code), axis in sorted(device.axes.items()))
          counts = " ".join("%s=%d" % item for item in sorted(device.counts.items()))
          say(
              "SUM %s %s dev=%s name=%s %s first=%s last=%s down=%s axes: %s keys(code:press/release/repeat): %s"
              % (
                  label,
                  stamp(),
                  device.node,
                  ascii(device.name),
                  counts or "none",
                  "-" if device.first is None else "%.3f" % device.first,
                  "-" if device.last is None else "%.3f" % device.last,
                  sorted(device.down),
                  axes or "none",
                  keys or "none",
              )
          )
          device.dirty = False


      devices = {}  # path -> Device
      failed = set()


      def rescan():
          for path in sorted(glob.glob("/dev/input/event*")):
              if path in devices or path in failed:
                  continue
              try:
                  fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
              except OSError as error:
                  failed.add(path)
                  say("OPEN-FAILED %s %s" % (path, error))
                  continue
              devices[path] = Device(path, fd)
              say("OPEN %s dev=%s name=%s" % (stamp(), devices[path].node, ascii(devices[path].name)))


      def drop(device, why):
          say("READ-STOPPED %s dev=%s %s" % (stamp(), device.node, why))
          failed.add(device.path)
          del devices[device.path]
          os.close(device.fd)


      say("READER-START %s window=%g python=%s" % (stamp(), WINDOW, sys.version.split()[0]))
      rescan()
      next_scan = RESCAN_INTERVAL
      next_summary = SUMMARY_INTERVAL
      while time.monotonic() - start < WINDOW:
          by_fd = {device.fd: device for device in devices.values()}
          if by_fd:
              ready = select.select(list(by_fd), [], [], 0.25)[0]
          else:
              time.sleep(0.25)
              ready = []
          for fd in ready:
              device = by_fd[fd]
              try:
                  data = os.read(fd, EVENT.size * 128)
              except BlockingIOError:
                  continue
              except OSError as error:
                  drop(device, str(error))
                  continue
              if not data:
                  drop(device, "end of file")
                  continue
              for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                  _, _, etype, code, value = EVENT.unpack_from(data, offset)
                  handle(device, etype, code, value)
          for device in devices.values():
              settle(device)
          elapsed = time.monotonic() - start
          if elapsed >= next_scan:
              next_scan = elapsed + RESCAN_INTERVAL
              rescan()
          if elapsed >= next_summary:
              next_summary = elapsed + SUMMARY_INTERVAL
              for device in devices.values():
                  if device.dirty:
                      summary(device, "periodic")

      for device in devices.values():
          summary(device, "final")
      say("READER-END %s devices=%d" % (stamp(), len(devices)))
  - path: /usr/local/sbin/vmr-xclient
    permissions: '0755'
    content: |
      #!/bin/sh
      # The clients of the optional graphical session: a window that shows the phases, a window to type in, and a window manager.
      xterm -geometry 110x12+10+10 -title phases -e tail -n +1 -f /run/vmr-banner &
      xterm -geometry 110x28+10+250 -title typing &
      exec twm
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, restart, getty@tty1.service]
  - [systemctl, start, --no-block, vmr-run.service]
```

What the guest does, in order: cloud-init creates the user `vmr`, writes the files, restarts `getty@tty1` with an autologin
drop-in, and starts `vmr-run.service`, which runs `vmr-probe` as root. `vmr-probe` prints a probe block (devices, drivers,
display, kernel log) between `VMRUNNER-CG-PROBE-BEGIN/END` markers to `/dev/hvc0`, takes the text of tty1 (`/dev/vcs1`) between
`VMRUNNER-CG-SCREEN-BEGIN/END` markers, starts `vmr-input-reader` for 420 s (it reads every `/dev/input/event*`, grabs nothing and
sends nothing), prints a `VMRUNNER-CG-DRM` line every 15 s (the connector's first mode, `fb0` size, tty1 size, who is logged in),
follows new kernel messages as `VMRUNNER-CG-DMESG` lines, and walks six **phases** that it announces on `hvc0` and on tty1 (the
owner reads them on the guest's screen): 1 type and point, 2 resize, 3 full screen, 4 focus loss, 5 hands off while the guest
scrolls its screen for 30 s, 6 hands off idle. At 420 s the reader prints its final tallies, the probe is printed again, and the
guest powers off (`VMRUNNER-CG-POWEROFF`). Make the ISO:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; cd /; ls "$SEED/src"; hdiutil makehybrid -iso -joliet -default-volume-name cidata -o "$SEED/seed.iso" "$SEED/src"; ls -l "$SEED/seed.iso"; chmod 600 "$SEED/seed.iso"'
```

`ls "$SEED/src"` shows `meta-data` and `user-data` only; `seed.iso` is 921 600 bytes (the same as the earlier GPU run). The earlier
runs proved that this image's cloud-init reads such an ISO on a read-only virtio disk. Check the YAML parses before using it:
`/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; /usr/bin/ruby -ryaml -e "puts YAML.load_file(ARGV[0]).keys.inspect" "$SEED/src/user-data"'`
prints `["users", "ssh_pwauth", "write_files", "runcmd"]`.

### 5. Tools

Write these files into `$TOOLS` (paths printed by step 1), exactly, then `chmod 700 "$TOOLS"/*.sh`:

`$TOOLS/mkefi.swift`:

```swift
// usage: mkefi EFIVariables.fd MachineIdentifier
// Makes the two files the app's setup makes for a Linux machine: an empty EFI variable store and a generic machine identifier.
// It starts no virtual machine and needs no entitlement.
import Foundation
import Virtualization

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: mkefi EFIVariables.fd MachineIdentifier\n".utf8))
    exit(64)
}
_ = try VZEFIVariableStore(creatingVariableStoreAt: URL(filePath: arguments[1]), options: [])
try VZGenericMachineIdentifier().dataRepresentation.write(to: URL(filePath: arguments[2]))
```

`$TOOLS/ax.swift` (reads and presses buttons of **one process only**: it refuses any pid whose executable is not
`$VMR_APP/Contents/MacOS/VMRunner`, before it asks anything of it):

```swift
// A read-mostly Accessibility helper for one process: the scratch copy of the app that this run started.
// usage (VMR_APP names the scratch app bundle): ax trusted | ax windows|tree|text|press PID [depth | title]
import ApplicationServices
import Darwin
import Foundation

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
// `ax trusted` asks nothing of any process: it only says whether this program may use Accessibility at all.
if arguments.count == 2, arguments[1] == "trusted" {
    print(AXIsProcessTrusted())
    exit(0)
}
guard arguments.count >= 3, let pid = pid_t(arguments[2]) else { fail("usage: ax windows|tree|text|press PID [depth | title]", 64) }
let command = arguments[1]

// Only the process of the scratch app: any other pid is refused before anything is asked of it.
guard let appPath = ProcessInfo.processInfo.environment["VMR_APP"] else { fail("VMR_APP must name the scratch app bundle", 64) }
var buffer = [CChar](repeating: 0, count: 4096)
guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { fail("no process \(pid)", 69) }
let actual = URL(filePath: String(cString: buffer)).resolvingSymlinksInPath().path
let wanted = URL(filePath: appPath + "/Contents/MacOS/VMRunner").resolvingSymlinksInPath().path
guard actual == wanted else { fail("refused: pid \(pid) runs \(actual), not \(wanted)", 77) }

guard AXIsProcessTrusted() else { fail("this process is not trusted for Accessibility; nothing was asked", 3) }
let application = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attribute(element, name) else { return "" }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &result) ? result : nil
}

func size(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
}

func describe(_ element: AXUIElement) -> String {
    let parts = [
        string(element, kAXRoleAttribute as String), string(element, kAXSubroleAttribute as String),
        "title=" + string(element, kAXTitleAttribute as String), "desc=" + string(element, kAXDescriptionAttribute as String),
        "value=" + String(string(element, kAXValueAttribute as String).prefix(120)),
    ]
    return parts.joined(separator: " | ")
}

/// Every element below `root`, depth first, at most `limit` of them and `depth` levels down.
func walk(_ root: AXUIElement, depth: Int, limit: Int = 600, _ visit: (AXUIElement, Int) -> Void) {
    var seen = 0
    func step(_ element: AXUIElement, _ level: Int) {
        guard seen < limit, level <= depth else { return }
        seen += 1
        visit(element, level)
        for child in children(element) { step(child, level + 1) }
    }
    step(root, 0)
}

let windows = attribute(application, kAXWindowsAttribute as String) as? [AXUIElement] ?? []

switch command {
case "windows":
    for window in windows {
        let origin = point(window, kAXPositionAttribute as String)
        let extent = size(window, kAXSizeAttribute as String)
        print(
            "window title=\(string(window, kAXTitleAttribute as String)) main=\(string(window, kAXMainAttribute as String)) "
                + "focused=\(string(window, kAXFocusedAttribute as String)) minimized=\(string(window, kAXMinimizedAttribute as String)) "
                + "fullscreen=\(string(window, "AXFullScreen")) subrole=\(string(window, kAXSubroleAttribute as String)) "
                + "at=\(origin.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?") size=\(extent.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")
    }
case "tree":
    let depth = arguments.count > 3 ? Int(arguments[3]) ?? 10 : 10
    walk(application, depth: depth) { element, level in print(String(repeating: "  ", count: level) + describe(element)) }
case "text":
    // Alerts, sheets and every static text of every window: how an error shown by the app is read.
    for window in windows {
        walk(window, depth: 14) { element, _ in
            let role = string(element, kAXRoleAttribute as String)
            if role == "AXStaticText" || role == "AXTextArea" { print(string(element, kAXValueAttribute as String)) }
        }
    }
case "press":
    guard arguments.count > 3 else { fail("usage: ax press PID TITLE", 64) }
    let wantedTitle = arguments[3]
    var pressed = false
    for window in windows where !pressed {
        walk(window, depth: 14) { element, _ in
            guard !pressed, string(element, kAXRoleAttribute as String) == "AXButton" else { return }
            let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].map { string(element, $0 as String) }
            if names.contains(wantedTitle) {
                pressed = AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                print(pressed ? "pressed \(wantedTitle)" : "found \(wantedTitle) but AXPress failed")
            }
        }
    }
    if !pressed { fail("no button named \(wantedTitle)", 1) }
default:
    fail("unknown command \(command)", 64)
}
```

`$TOOLS/mkbundle.sh`:

```bash
#!/bin/bash
# usage: mkbundle.sh NAME GPU      GPU is custom or apple. DATA, DL, SEED, TOOLS and NOTES come from the run's env file.
# Makes <DATA>/Machines/<UUID>.vm the way the app's setup would leave a Linux machine that is ready to start:
# config.json, a clone of the downloaded disk, an EFI variable store and a machine identifier.
set -euo pipefail
name=$1
gpu=$2
id=$(uuidgen)
seed_id=$(uuidgen)
bundle="$DATA/Machines/$id.vm"
[ -d "$DATA/Machines" ] || mkdir -m 700 "$DATA/Machines"
mkdir -m 700 "$bundle"
cp -c "$DL/disk.raw" "$bundle/Disk.img"
"$TOOLS/mkefi" "$bundle/EFIVariables.fd" "$bundle/MachineIdentifier"
cat > "$bundle/config.json" <<JSON
{
  "id": "$id",
  "name": "$name",
  "guest": "linux",
  "isProvisioned": true,
  "cpuCount": 2,
  "memoryMiB": 2048,
  "diskGiB": 3,
  "networkMode": "nat",
  "serialConsole": true,
  "gpu": "$gpu",
  "sharesClipboard": false,
  "audioOutput": false,
  "maxRuntimeMinutes": 15,
  "extraDisks": [ { "id": "$seed_id", "path": "$SEED/seed.iso", "readOnly": true } ]
}
JSON
chmod 600 "$bundle/Disk.img" "$bundle/EFIVariables.fd" "$bundle/MachineIdentifier" "$bundle/config.json"
echo "$name $gpu $id" | tee -a "$NOTES/ids.txt"
```

`$TOOLS/sample.sh`:

```bash
#!/bin/bash
# usage: sample.sh OUTFILE APP_PID HELPER_PID_FILE MAX_SECONDS
# Read-only: every 5 seconds one `ps` line for the app and, once its pid is in HELPER_PID_FILE, for the framework's helper.
# Each line: epoch-seconds pid cpu-time %cpu rss-KiB. Ends at MAX_SECONDS, or when the file OUTFILE.stop exists.
out=$1
app=$2
helperfile=$3
end=$(( $(date +%s) + $4 ))
while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$out.stop" ]; do
  now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  pids=$app
  [ -s "$helperfile" ] && pids="$app,$(cat "$helperfile")"
  ps -o pid=,time=,%cpu=,rss= -p "$pids" | sed "s/^/$now /" >> "$out"
  sleep 5
done
```

`$TOOLS/cpu.awk`:

```awk
# input: lines of "epoch pid cpu-time %cpu rss-KiB" from sample.sh; output: the CPU use over each interval (cpu-time delta / wall delta)
{
  n = split($3, t, ":")
  seconds = (n == 3) ? t[1] * 3600 + t[2] * 60 + t[3] : t[1] * 60 + t[2]
  if ($2 in before) printf "%.0f pid=%s cpu%%=%.1f rss_KiB=%d\n", $1, $2, 100 * (seconds - before[$2]) / ($1 - when[$2]), $5
  before[$2] = seconds
  when[$2] = $1
}
```

`$TOOLS/launch.sh`:

```bash
#!/bin/bash
# usage: launch.sh RUN NAME    RUN is a label (A, B, C or D) and NAME the machine's name (cg-a, ...).
# Starts the console capture, the scratch app (which starts the machine itself, by --start), the sampler, and finds the
# framework's helper process for the machine. Every pid it starts is appended to $NOTES/pids.txt.
set -euo pipefail
. /tmp/vmr-customgpu-run.env
run=$1
name=$2
dir="$NOTES/$run"
mkdir -m 700 "$dir"
id=$(awk -v n="$name" '$1 == n { print $3 }' "$NOTES/ids.txt")
[ -n "$id" ] || { echo "no machine named $name"; exit 1; }
sock="$DATA/Machines/$id.vm/Console.sock"
[ "${#sock}" -le 103 ] || { echo "the console socket path is ${#sock} bytes, over 103"; exit 1; }
{ ps -ax -o pid=,command= | grep -F 'Virtualization.VirtualMachine' | grep -v grep | awk '{ print $1 }'; } > "$dir/helpers-before.txt" || true

# The console is a local socket, not a file: this keeps one client on it and writes what the guest prints to console.log,
# each line with the Mac's clock in front of it.
( until [ -S "$sock" ] || [ "$SECONDS" -gt 900 ]; do sleep 0.5; done
  /usr/bin/nc -d -U "$sock" | perl -MTime::HiRes=time -e '$| = 1; while (<STDIN>) { printf "%.3f %s", time, $_ }' ) > "$dir/console.log" 2>&1 &
echo "console $!" >> "$NOTES/pids.txt"

cd /
VMRUNNER_DATA_DIR="$DATA" "$APP/Contents/MacOS/VMRunner" --start "$name" --display-diagnostics > "$dir/app.log" 2>&1 &
app=$!
echo "app $app" >> "$NOTES/pids.txt"
echo "$app" > "$dir/app.pid"
date +%s > "$dir/launch.epoch"
: > "$dir/helper.pid"
bash "$TOOLS/sample.sh" "$dir/samples.txt" "$app" "$dir/helper.pid" 1500 > /dev/null 2>&1 &
echo "sampler $!" >> "$NOTES/pids.txt"

# The framework runs the guest in a helper process of its own, not a child of the app: it is the one that was not there before.
for _ in $(seq 1 60); do
  sleep 1
  kill -0 "$app" 2> /dev/null || { echo "the app exited within ${SECONDS}s; read $dir/app.log"; exit 2; }
  helper=$(ps -ax -o pid=,command= | grep -F 'Virtualization.VirtualMachine' | grep -v grep | awk '{ print $1 }' | grep -v -x -F -f "$dir/helpers-before.txt" | head -n 1 || true)
  if [ -n "$helper" ]; then
    echo "$helper" > "$dir/helper.pid"
    echo "helper $helper" >> "$NOTES/pids.txt"
    break
  fi
done
echo "run=$run machine=$name app=$app helper=$(cat "$dir/helper.pid") console=$sock"
```

`$TOOLS/waitfor.sh`:

```bash
#!/bin/bash
# usage: waitfor.sh RUN PATTERN SECONDS    Waits until the fixed string PATTERN is in the run's console log; stops early if the app is gone.
. /tmp/vmr-customgpu-run.env
dir="$NOTES/$1"
end=$(( $(date +%s) + $3 ))
until grep -a -F -q -- "$2" "$dir/console.log"; do
  [ "$(date +%s)" -ge "$end" ] && { echo "NOT SEEN within $3 s: $2"; exit 1; }
  kill -0 "$(cat "$dir/app.pid")" 2> /dev/null || { echo "the app is gone before: $2"; exit 2; }
  sleep 2
done
echo "seen: $2"
```

`$TOOLS/collect.sh`:

```bash
#!/bin/bash
# usage: collect.sh RUN LABEL    One read-only observation of the app's own windows, appended to $NOTES/RUN/observations.txt.
. /tmp/vmr-customgpu-run.env
run=$1
label=$2
dir="$NOTES/$run"
app=$(cat "$dir/app.pid")
{
  echo "== $label $(date '+%H:%M:%S') app $app alive: $(kill -0 "$app" 2> /dev/null && echo yes || echo NO)"
  VMR_APP="$APP" "$TOOLS/ax" windows "$app" 2>&1
  ps -o pid=,time=,%cpu=,rss= -p "$app$( [ -s "$dir/helper.pid" ] && echo ",$(cat "$dir/helper.pid")" )" 2>&1
} | tee -a "$dir/observations.txt"
```

`$TOOLS/digest.sh`:

```bash
#!/bin/bash
# usage: digest.sh RUN    After the guest powered off (or the run was stopped): turns the run's raw files into the tables the report needs.
. /tmp/vmr-customgpu-run.env
run=$1
dir="$NOTES/$run"
app=$(cat "$dir/app.pid")
touch "$dir/samples.txt.stop"
tr -d '\r' < "$dir/console.log" > "$dir/console.clean"
grep -a 'VMRUNNER-CG-' "$dir/console.clean" | grep -a -v 'VMRUNNER-CG-EV ' > "$dir/markers.txt"
grep -a 'VMRUNNER-CG-EV ' "$dir/console.clean" > "$dir/events.txt" || true
awk -f "$TOOLS/cpu.awk" "$dir/samples.txt" > "$dir/cpu.txt"
start=$(date -r "$(cat "$dir/launch.epoch")" '+%Y-%m-%d %H:%M:%S')
/usr/bin/log show --start "$start" --info --style compact --predicate "subsystem == \"$ID\" AND processID == $app" > "$dir/applog.txt" 2>&1 || true
ls -t "$HOME/Library/Logs/DiagnosticReports" | head -5 > "$dir/reports-after.txt"
echo "lines: console $(wc -l < "$dir/console.clean"), markers $(wc -l < "$dir/markers.txt"), events $(wc -l < "$dir/events.txt"), app log $(wc -l < "$dir/applog.txt")"
echo "--- phases"; grep -a 'VMRUNNER-CG-PHASE' "$dir/markers.txt"
echo "--- devices the reader opened"; grep -a 'VMRUNNER-CG-OPEN' "$dir/markers.txt"
echo "--- final tallies per device"; grep -a 'VMRUNNER-CG-SUM final' "$dir/markers.txt"
echo "--- event lines per device and type"; awk '{ print $5, $6 }' "$dir/events.txt" | sort | uniq -c
echo "--- first and last event line"; head -n 1 "$dir/events.txt"; tail -n 1 "$dir/events.txt"
echo "--- where the pointer rested"; grep -a 'VMRUNNER-CG-SETTLED' "$dir/markers.txt"
echo "--- reader problems"; grep -a -E 'OPEN-FAILED|READ-STOPPED|Traceback|Error' "$dir/markers.txt" || echo none
echo "--- the display, every 15 s"; grep -a 'VMRUNNER-CG-DRM' "$dir/markers.txt"
echo "--- the app's own log: resize, trouble, errors"; grep -E 'Display resize|Couldn|refused|isn.t reading|wrong length|error|fault' "$dir/applog.txt" | head -60
echo "--- the app's log at error and fault level"; /usr/bin/log show --start "$start" --style compact --predicate "subsystem == \"$ID\" AND processID == $app AND (messageType == error OR messageType == fault)" 2>&1 | head -40
echo "--- mean CPU of each process in each phase of the guest's script (phase 5 is the scroll load, phase 6 idle)"
awk 'NR == FNR { if ($2 == "VMRUNNER-CG-PHASE") { n++; start[n] = $1; name[n] = $3 } next }
     { split($2, q, "="); split($3, c, "="); k = 0; for (i = 1; i <= n; i++) if ($1 >= start[i]) k = i
       if (k > 0) { key = name[k] " " q[2]; sum[key] += c[2]; count[key]++ } }
     END { for (key in count) printf "phase %s: mean %.1f%% over %d samples\n", key, sum[key] / count[key], count[key] }' "$dir/markers.txt" "$dir/cpu.txt" | sort -n
echo "--- CPU per 5 s interval over the whole run: peak and mean"
awk '{ split($2, p, "="); split($3, c, "="); split($4, r, "="); n[p[2]]++; s[p[2]] += c[2]; if (c[2] > m[p[2]]) m[p[2]] = c[2]; if (r[2] > k[p[2]]) k[p[2]] = r[2] } END { for (q in n) printf "pid %s: samples %d mean %.1f%% peak %.1f%% peak RSS %d KiB\n", q, n[q], s[q] / n[q], m[q], k[q] }' "$dir/cpu.txt"
echo "--- crash reports now (newest five) versus before the run"; cat "$dir/reports-after.txt"
```

Compile the two programs (this starts nothing; `mkefi` makes two files, `ax` is run later):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; cd / && swiftc -O -o "$TOOLS/mkefi" "$TOOLS/mkefi.swift" && swiftc -O -o "$TOOLS/ax" "$TOOLS/ax.swift" && ls -l "$TOOLS/mkefi" "$TOOLS/ax"; VMR_APP="$APP" "$TOOLS/ax" windows $$; echo "ax refusal exit=$?"'
```

Expected: both binaries, then `refused: pid ... runs ..., not .../VMRunner` and `exit=77` (the safety check refusing the shell's own
pid: no Accessibility call was made). Also record whether Accessibility is available at all (it asks nothing of any app):
`/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; "$TOOLS/ax" trusted'` prints `true` or `false` (`false`: assumption 9).

### 6. The machines

One machine per sub-run, each with its own clone of the disk (cloud-init runs once per disk: a second boot of the same disk would
not run the user's files again). `cp -c` is an APFS clone: instant, no extra space until the guest writes.

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; export DATA DL SEED TOOLS NOTES; cd /; bash "$TOOLS/mkbundle.sh" cg-a custom && bash "$TOOLS/mkbundle.sh" cg-b custom && bash "$TOOLS/mkbundle.sh" cg-c apple; ls -l "$DATA/Machines"; ls -l "$DATA/Machines"/*.vm | head -20; ls "$DATA"'
```

Expected: three lines `cg-a custom <UUID>`, `cg-b custom <UUID>`, `cg-c apple <UUID>` (`cg-c` is used only by the optional sub-run C;
building it costs nothing), three `<UUID>.vm` folders (`drwx------`) each with `config.json`, `Disk.img`, `EFIVariables.fd`
(131 072 bytes), `MachineIdentifier` (70 bytes), all `-rw-------`; and **no** `Machines.approvals.json` in `$DATA` (the app makes it at its
first load and approves these paths then; do not make one). `config.json` of `cg-a`:

```json
{
  "id": "<UUID>",
  "name": "cg-a",
  "guest": "linux",
  "isProvisioned": true,
  "cpuCount": 2,
  "memoryMiB": 2048,
  "diskGiB": 3,
  "networkMode": "nat",
  "serialConsole": true,
  "gpu": "custom",
  "sharesClipboard": false,
  "audioOutput": false,
  "maxRuntimeMinutes": 15,
  "extraDisks": [ { "id": "<UUID>", "path": "<SEED>/seed.iso", "readOnly": true } ]
}
```

The 2 CPUs, 2048 MiB and 15-minute runtime limit are the card's caps. **The app rewrites `config.json` at the first start** (it
sets `hasBooted`, and remembers the display size); that is expected. The decode test of the evidence below ran on bundles made
by this exact script.

### 7. Baselines (read-only)

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; { echo "prefs-normal: $(stat -f "%z %m" "$HOME/Library/Preferences/$ID.plist" 2>&1)"; echo "override-domain: $(defaults read $DOMAIN 2>&1 | head -1)"; echo "savedState: $(ls -ld "$TMPDIR/$ID.savedState" 2>&1)"; } > "$NOTES/prefs-before.txt"; ls -t "$HOME/Library/Logs/DiagnosticReports" | head -5 > "$NOTES/reports-before.txt"; { ps -ax -o pid=,command= | grep -F Virtualization.VirtualMachine | grep -v grep; } > "$NOTES/helpers-all-before.txt"; cat "$NOTES/prefs-before.txt" "$NOTES/reports-before.txt"; wc -l "$NOTES/helpers-all-before.txt"'
```

Keep these files: the end of the run compares them. `prefs-normal` is the size and mtime of the owner's own
`com.example.VMRunner.plist`; it must be the same at the end.

## The sub-runs

Run **A first, then B**; C and D only if the owner agrees at the end of B (they are optional and each needs the owner for
about 10 minutes). One sub-run at a time; never two apps. The parameters:

| Sub-run | Machine | Setting before launch | What it answers |
|---|---|---|---|
| A | `cg-a` | key `CustomGPUInput` deleted (the default, `framework`) | the framework's input path on the custom GPU |
| B | `cg-b` | `defaults write "$DOMAIN" CustomGPUInput virtio` | the app's virtio input path |
| C (optional) | `cg-c` (`gpu: apple`) | key deleted | the framework's own graphics device: the cost baseline, same script |
| D (optional) | `cg-d` (custom, built in step D1) | `virtio` if B worked better than A, else deleted | a graphical session: cursor image and alpha |

### Procedure of one sub-run (X is A, B, C or D; NAME is its machine)

**X1. Set the default** (the app reads it once, at the machine's start; the app is not running now).
A, C: `/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; defaults delete "$DOMAIN" CustomGPUInput 2>&1; defaults read "$DOMAIN" CustomGPUInput 2>&1'`
(both may answer that the domain or pair does not exist: that is the default path). B (and D if virtio):
`/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; defaults write "$DOMAIN" CustomGPUInput virtio; defaults read "$DOMAIN" CustomGPUInput'` prints `virtio`.
Record which.

**X2. Ask the owner to be ready** at the Mac, with nothing else needed on screen except one other window of their own (for the
focus test). Say that the app's window will appear, probably behind other windows, and that **they** bring it to the front
(the agent never does), then that they wait for the guest's screen to say `PHASE 1`.

**X3. Launch** (starts the console reader, the scratch app with `--start NAME --display-diagnostics`, the sampler, and finds the
framework's helper process; every pid goes into `$NOTES/pids.txt`):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; export DATA NOTES TOOLS APP; cd /; bash "$TOOLS/launch.sh" X NAME'
```

(with X and NAME replaced). It prints `run=X machine=NAME app=<pid> helper=<pid> console=<socket path>` within a minute. If it prints
that the app exited, read `$NOTES/X/app.log`: that is a result (record it), STOP the sub-run and go to **X9**. If the harness kills
background processes when a call returns, run the same command again with the tool's run-in-background option instead; the scripts
do not change. Note the launch time.

If the app shows a dialog or an open panel or anything but the machine's window (an approval prompt, "not set up", a start
error): read it through Accessibility (`... "$TOOLS/ax" text <app pid>`), record the text, STOP the sub-run. Do not click it.

**X4. Start check** (if `--start` did not start the machine within 30 s of the launch and `ax windows` shows its window, press the
toolbar's Start button with `VMR_APP="$APP" "$TOOLS/ax" press <app pid> Start`, run in a `bash -c` that sources the env file; if the button is not
named Start, list the window with `... "$TOOLS/ax" tree <app pid> 12` and use the name shown; this is the only button the agent presses besides
Shut Down and Force Stop). Then:

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; export NOTES TOOLS APP; bash "$TOOLS/collect.sh" X started; bash "$TOOLS/waitfor.sh" X "VMRUNNER-CG-PHASE 1 " 300'
```

`collect.sh` appends the window's title, size, `main`/`focused`/`fullscreen` flags (Accessibility, read-only) and the `ps` lines of the app
and the helper to `$NOTES/X/observations.txt`. `waitfor.sh` prints `seen: VMRUNNER-CG-PHASE 1 ` when the guest has finished its probe
and started the reader, normally 45 to 120 s after the launch. **`NOT SEEN within 300 s` is a stop condition** (below): collect
what is there (`collect.sh`, `ax text`, the console log, the app log), do not retry.

**X5. No picture is taken.** The run takes no screenshot and no window capture (the owner's rule); what the guest's screen shows is what the owner says and what the guest itself prints (`VMRUNNER-CG-SCREEN` blocks, read from `/dev/vcs1`). Ask the owner, now, to say in words what the window shows: the `vmr@cgrun:~$` prompt of the autologin shell or the login prompt, the `==== PHASE 1 ... ====` banner, the picture's aspect, any black bars. Write the answer down verbatim.

**X6. Tell the owner to begin** ("PHASE 1 is on the guest's screen: start the script"), and do not touch anything. The guest's
phases run by its own clock; the owner's script is in the next section. The agent only watches:

- one observation 20 s into phases 3, 5 and 6, a separate call each, with N and LABEL replaced by `3` and `fullscreen`, then `5` and `load`,
  then `6` and `idle`: `/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; export NOTES TOOLS APP; bash "$TOOLS/waitfor.sh" X "VMRUNNER-CG-PHASE N " 600 && sleep 20 && bash "$TOOLS/collect.sh" X LABEL'`
  (the window reads `fullscreen=1` in the first one; ask the owner to say whether the picture and the keyboard worked in full screen, and
  when they left it);
- the 20-minute cap: if the sub-run is still going 20 minutes after the launch, do **X8** now.

**X7. The end.**

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; export NOTES TOOLS APP; bash "$TOOLS/waitfor.sh" X "VMRUNNER-CG-POWEROFF" 600; sleep 20; bash "$TOOLS/collect.sh" X stopped'
```

The guest powers itself off about 7 minutes after PHASE 1; the window then shows the stopped machine (its Start button back; the
`ps` line of the helper disappears). Ask the owner what the window shows. Then **X9**.

**X8. Backstop** (only at the 20-minute cap, or when a stop condition says stop the machine): if Accessibility is available,
`VMR_APP="$APP" "$TOOLS/ax" press <app pid> "Shut Down"`; wait 40 s (the guest has 30 s); then `... press <app pid> "Force Stop"`; wait
10 s. If Accessibility is not available, or the machine still runs, `kill -TERM <app pid>` (the recorded pid), wait 10 s, `kill -KILL`
if it still runs. Record which of these was needed.

**X9. Digest, then quit the app.**

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; export NOTES TOOLS APP ID; cd /; bash "$TOOLS/digest.sh" X'
```

Read its output into the report (section "What to record"). Then quit the scratch app by its recorded pid (it has no running machine,
so no quit alert appears): `kill -TERM $(cat "$NOTES/X/app.pid")`, wait until `kill -0` fails (up to 10 s, then `kill -KILL`), and check
`ps -ax | grep -F Virtualization.VirtualMachine` against `$NOTES/helpers-all-before.txt`: the run's helper is gone (it ends with the
machine; if it is still there 15 s after the app's exit, `kill -TERM` that recorded pid and say so). The files of `$NOTES/X/` (console, markers, applog,
observations, cpu) stay where they are until "Clean up"; the report quotes what it needs from them (200 lines of guest output at most).

### The owner's script (the same in every sub-run; times are from the guest's `PHASE 1` banner)

The window has the guest's screen. Click once in the picture to give it the keyboard if keys do nothing. Type **by the physical
key positions** of a US keyboard (the guest reads the keys, not the letters printed on yours). What the owner types lands in a shell
on tty1: it runs words as commands that do not exist; nothing in it matters. Do not press a modifier together with a function key.

| Guest phase and time | The owner |
|---|---|
| **PHASE 1, 0:00 to 1:55** | Keys, in this order, about a second between groups: the top letter row Q W E R T Y U I O P; the home row A S D F G H J K L; the bottom row Z X C V B N M; the number row 1 to 0; Space, Tab, Return, and the Delete (backspace) key twice; Left Shift held with A, then Right Shift held with A; the four arrows (Up, Down, Left, Right); Escape; Control, Option and Command each pressed alone once; then Command held while U is pressed and released, Command released, and a 3 s wait (Command chords may lose the key-up: say whether the guest kept printing `u`); Caps Lock on, A S D, Caps Lock off; hold J for two seconds; then a short sentence of ordinary words and Return. Then the pointer: move it slowly to the top-left corner of the guest's picture (not the black bars, if any) and hold still for 2 s; the same at the top-right, bottom-right, bottom-left, and the centre; click the left button once in the centre, the right button once, the middle button once if there is one (say if not); scroll up five notches and down five. |
| **PHASE 2, 2:00 to 3:25** | Resize the window by dragging an edge, clearly (about a fifth of its width or height), release, wait 20 s; resize it again, to a clearly different size. (Not the green button.) Say when each drag ended. |
| **PHASE 3, 3:30 to 4:15** | Enter full screen (green button or the View menu), wait 10 s, type a few letters, leave full screen. |
| **PHASE 4, 4:20 to 5:15** | Hold the K key. While holding it, click on a window of any other application of yours, keep holding for 3 s, release K there, click back on the VMRunner window and wait 5 s. Say whether the guest's screen kept printing `k` after you came back (a stuck key) and whether it stopped. |
| **PHASE 5, 5:20 to 5:50** | Hands off. Move the pointer off the VMRunner window. The guest scrolls its screen for 30 s (the cost test). |
| **PHASE 6, 5:50 to 6:50** | Hands off, pointer still off the window. The guest is idle. |
| Reader ends 7:00 | The guest powers off by itself about 10 s later. |

For each phase the owner also reports in words what they saw on the guest's screen and in the window: did the typed text appear,
did the pointer reach the corners, any lag, any beep, flicker or black frame, the picture's aspect after each resize, whether the
window kept up during the scroll. The agent writes these down with the time, verbatim.

### Sub-run C (optional): the framework's own graphics device

Same as A, machine `cg-c` (`gpu: apple`); the owner may do only phases 5 and 6 (hands off; the numbers compare with A and B) or the
whole script. Record the same rows. Do not write the device name "custom" for it in the report.

### Sub-run D (optional): a graphical session, for the cursor

D1. Make the seed and the machine: copy the folder and replace the two comment lines (only this change):

```
/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; export DATA DL SEED TOOLS NOTES; cd /; mkdir -m 700 "$SEED/src-x" && cp "$SEED/src/meta-data" "$SEED/src-x/" && perl -pe "s/^#VMR-X-UPDATE\$/package_update: true/; s/^#VMR-X-PACKAGES\$/packages: [xserver-xorg-core, xserver-xorg-input-libinput, xinit, xterm, twm]/" "$SEED/src/user-data" > "$SEED/src-x/user-data" && diff "$SEED/src/user-data" "$SEED/src-x/user-data"; hdiutil makehybrid -iso -joliet -default-volume-name cidata -o "$SEED/seed-x.iso" "$SEED/src-x" && sed -e "s#/seed.iso#/seed-x.iso#" -e "s#\"maxRuntimeMinutes\": 15#\"maxRuntimeMinutes\": 25#" "$TOOLS/mkbundle.sh" > "$TOOLS/mkbundle-x.sh" && chmod 600 "$SEED/seed-x.iso" && bash "$TOOLS/mkbundle-x.sh" cg-d custom'
```

The `diff` shows exactly two changed lines (`package_update: true` and the `packages:` list). Then the procedure above with `cg-d`; the
guest installs the packages over NAT first (a few minutes: `PHASE 1` appears later, allow **900 s** in the `waitfor` of X4; this machine has a 25-minute
runtime limit and this sub-run a 30-minute cap, and the owner does the whole script in one go), starts X on its own console
(`VMRUNNER-CG-XMODE`), and the phases appear in a window of the X session. The owner reports what the pointer looks like in X: its
shape, its edges (soft or hard), any black or white box around it, whether it follows the hand, whether it changes over the title
bar of a window. After the run, read `VMRUNNER-CG-XMODE` and, in the probe's last block, the `--- Xorg log` and `--- xinit log` parts (`(EE)` lines; if
there are none and no `XMODE` line, X did not start: record that and stop D).

## What to record (the report: `~/Developer/g-cqd/vmrunner-board/realguest-customgpu-report.md`)

Write the report in the style of the earlier GPU report: dated, "Seen = read from a log or file of this run. Inferred = my reading",
one table per area, a deviations section, a cleanup section. Every claim row has: the claim, **how observed** (the file or output it
comes from, quoted), **Basis** `SEEN` or `INFERRED`, and the verdict `YES` / `NO` / `NOT SEEN`. A claim the evidence does not reach is
NOT SEEN, never NO. Rows:

**Host and inputs.**
H1. `sw_vers`, `uname -m`, `hw.model`; the commit built (`rev-parse HEAD`) and whether it was `main` or the unmerged chain; build `exit=0`,
its time, `codesign` flags and entitlements; bundle identifier and `$DOMAIN`. H2. Download size, `SHA-512 OK`, no signature checked; the disk.
H3. The decode evidence (below) and that the machine was accepted by the app with no open panel and no approval prompt (the window showed
the machine). H4. The owner's authorising words and the times of each sub-run.

**Per sub-run (a column each for A, B and the optional C, D; for every row the quoted line).**
S1. The machine started: `launch.sh`'s line, `Starting display W×H px ...` in `applog.txt`, time from launch to `PHASE 1`, the helper pid,
no error dialog (`ax text`).
S2. The custom GPU was in use: `pci ... device=0x1050 class=0x038000 driver=virtio-pci`, the kernel's `virtio-gpu-pci detected` line,
`fb0 name=virtio_gpudrmfb`; `grep '"gpu"' config.json` of the machine after the run (A, B, D `custom`; C `apple`; for C the class
and features lines show the framework's device: record them as the difference).
S3. **The input devices the guest saw**: each `/proc/bus/input/devices` block (Name, Bus, Handlers, Phys), the `udev` lines
(`ID_INPUT_KEYBOARD`, `ID_INPUT_MOUSE`, `ID_INPUT_TABLET`, `ID_INPUT_ACCELEROMETER`...), the `pci` rows of virtio input (`device=0x1052`)
or the USB controller, and the `lsmod` lines. Expected A: a USB keyboard and a USB pointer; B: exactly two virtio devices with
non-text names (the static configuration), the keyboard having the `kbd` handler (the console reads it). Whether the keyboard also
looks like an accelerometer (the card's note in `VirtioInputStaticConfig.swift` expects it).
S4. **Events counted** per device and per type from the final `SUM` lines (`KEY`, `ABS`, `REL`, `SYN`, `MSC`), the event lines per device and
type (`digest.sh`), the first and last event timestamps (host clock, from the stamped console lines), the number of reader problems.
S5. **Keyboard completeness**: from the final `SUM` of the keyboard: the list `code:press/release/repeat` against the owner's script. Expected
Linux codes: Esc 1; digits 1 to 0 = 2 to 11; Backspace 14; Tab 15; Q to P = 16 to 25; Return 28; Left Control 29; A to L = 30 to 38; Left Shift 42;
Z to M = 44 to 50; Right Shift 54; Left Alt (Option) 56; Space 57; Caps Lock 58; Up 103; Left 105; Right 106; Down 108; Left Meta (Command) 125.
Missing codes, extra codes, keys with a press and no release (`down=[...]` at the end), repeats (value 2) for the held J, Caps Lock behaviour.
S6. **Typed text**: the `VMRUNNER-CG-SCREEN` block `after-typing`: the letters, digits and sentence as the guest drew them (the guest's US layout
applies); lines that are wrong are quoted.
S7. **Pointer accuracy**: the `VMRUNNER-CG-SETTLED` lines where the pointer rested: the values at the four corners and the centre against
the range (B expected 259 to 16384 on both axes; A: record the range the USB pointer reports in its `SUM` `axes`); an error of more than 2 % of
the range at a corner is a NO. Clicks: `KEY code=272/273/274` pairs. Scroll: `REL code=8` events, their count and sign for the five notches up and
five down (a trackpad's notch count is a guess in the app: record what arrived).
S8. **Stuck keys after focus loss and after a Command chord**: `down=[...]` of the keyboard at the end, the K presses and releases (code 37), the U presses and releases (code 22) of the Command+U chord and any `u` repeats (value 2) after it (a Mac does not always deliver the key-up of a key pressed while Command is held), the `after-focus-loss` screen block
(a row of `k`s after the owner returned), the owner's words.
S9. **Resize 1 and resize 2, separately**: from `applog.txt` the `Display resize:` lines of each drag (`asked for W×H px`, `guest responded` or
`did not respond`, `asking again`), and from the guest the `VMRUNNER-CG-DRM` lines before and after each drag (the first mode, `fb0` size, tty1 size) and the
`VMRUNNER-CG-DMESG` lines. Whether the guest asked for the display information again is **inferred** from a changed first mode and `guest
responded` (the app does not log the request itself). Also: seconds from the drag's end to the response; whether the console kept its text; whether a
second resize behaved like the first.
S10. **Full screen**: `fullscreen=1` in the `fullscreen` observation, the owner's words, whether the picture and the keys worked in it and after leaving it.
S11. **The scanout showed the guest**: the owner's words (X5), the `start` and later `SCREEN` blocks.
S12. **Cursor drawn and alpha correct**: NOT SEEN unless D ran; for D the owner's description in words.
S13. **Cost**: per sub-run the table `digest.sh` prints: mean CPU of the app and of the helper in phase 5 (load) and phase 6 (idle), peak CPU, peak RSS of
both; the same for C; the helper's pid identified as in X3. State the sampling method (`ps` cumulative CPU time over 5 s, not an instantaneous
reading).
S14. **Stability**: the app alive until the end (`observations.txt` lines `alive: yes`); no new `VMRunner*.ips` in `DiagnosticReports` (compare the
list in `reports-after.txt` with `$NOTES/reports-before.txt`); the error and fault lines of the app's log (none expected); the custom-device
trouble lines (`Couldn't ...`, `isn't reading events fast enough`, `wrong length`) and how many; the app's own `Display resize` lines.
S15. **Power-off and stop**: `VMRUNNER-CG-POWEROFF`, the window's stopped state, the helper gone.
S16. **Clipboard**: NOT TESTED (assumption 8).

**Decision questions** (answer each in one line, with the rows it rests on; the owner decides what to change):

Q1. Which input path works: A, B, both or neither (works means: the keyboard row S5 has every expected code with a press and a release, S6 shows the typed text,
S7 reaches the corners within 2 %, S8 has no stuck key)? Q2. Keyboard completeness of each path (which codes missing or extra, modifiers, Caps Lock, repeats).
Q3. Pointer accuracy at the corners, buttons and scroll of each path. Q4. Stuck keys after focus loss on each path. Q5. Resize 1 and resize 2 on the custom GPU: does the guest follow each, how
long, does the console survive. Q6. Is the cursor drawn with the right alpha (D only, else NOT SEEN). Q7. The cost of the custom GPU against the framework's device (C), idle and under the scroll
load, app and helper. Q8. Any crash, exception or error in the app. Q9. What the run could not answer, and what it would take.

## Stop conditions

- Not authorised; the host is below macOS 27; less than 15 GiB free; another VMRunner is running; any `/tmp/vmr-customgpu-run*` path exists; the domain
  `$DOMAIN` exists before the run; an organisation policy turns the custom GPU off; the chain is neither merged nor named by the owner.
- The download is over 1 GiB or its length is absent; the checksum does not match; the archive lists anything but `disk.raw`; the build or its verification fails.
- The app shows an open panel, an approval prompt, a setup screen or an error dialog at launch or start: record its text (`ax text`), then stop that sub-run (X8, X9).
  No retry with another configuration: a change is a code change for the owner.
- No `VMRUNNER-CG-PHASE 1` line 300 s after the launch (900 s for D): collect, record, stop that sub-run.
- The app exits or crashes (a result: record the new report's file name, never its content): stop the sub-run, go to X9 and **do not** start another sub-run.
- A step would need the agent to type, click, scroll, foreground a window or take any screenshot or capture; `ax` refuses a pid; Accessibility asks
  for a permission: ask the owner instead, change no permission.
- Anything would write to or read from the owner's library (`~/Library/Application Support/VMRunner`), one of the owner's machines, or signal a pid that this run did
  not record.
- Time: 20 minutes in one sub-run (30 for D), or 100 minutes in all: go to X8 and then the clean-up.

## Clean up (always, also after a stop)

1. Processes. The recorded pids are in `$NOTES/pids.txt` as `kind pid`. List what still runs, children first, and signal only those:
   `/bin/bash --noprofile --norc -c '. /tmp/vmr-customgpu-run.env; while read kind pid; do if kill -0 $pid 2>/dev/null; then echo "$kind $pid children: $(pgrep -P $pid | tr "\n" " ")"; fi; done < "$NOTES/pids.txt"'`,
   then `kill -TERM` each of those children and pids (the sampler and the console reader first, the app last), wait up to 10 s each, `kill -KILL` what remains, in a second
   pass. A helper pid of the framework that is still there 15 s after its app ended: `kill -TERM` that recorded pid. `pgrep -x VMRunner` prints nothing and `ps -ax | grep -F Virtualization.VirtualMachine`
   shows no process that is not in `$NOTES/helpers-all-before.txt`.
2. The override domain. With no app running: `defaults delete "$DOMAIN"`; then `ls -l "$HOME/Library/Preferences/$DOMAIN.plist"`. If the file is still there (the preferences
   daemon writes an empty one back; see `cards2/G04.md`), say so in the report as left (size and time), and do not try to remove it by hand.
3. The owner's own domain is unchanged: `stat -f "%z %m" "$HOME/Library/Preferences/$ID.plist"` equals the first line of `$NOTES/prefs-before.txt`
   (size and mtime). If not, record both and say what could have written it (the open panel and split-view autosave are known writers; this run opens neither). The `$TMPDIR/$ID.savedState` line of `prefs-before.txt` is
   unchanged (that folder is AppKit's; the card's runs do not use it).
4. Remove the run's folders and files. Print the variables once (`cat /tmp/vmr-customgpu-run.env`) and write the removal with the **literal paths it shows** (a
   removal through shell variables is refused by the agent's own safety check, and a typo there would be costly): `rm -rf` of exactly the five
   `/tmp/vmr-customgpu-run-<TS>`, `-dl`, `-seed`, `-tools` and `-notes`, then the worktree with `git -C ~/Developer/g-cqd/VMRunner worktree remove --force /tmp/vmr-customgpu-run-<TS>-src`
   and `git -C ~/Developer/g-cqd/VMRunner worktree prune` (if the tree came from a clone for the unmerged chain: `rm -rf` of that `-src` path instead), and last
   `rm -f /tmp/vmr-customgpu-run.env`. Copy nothing into the repository; the report quotes what it needs from the notes before this step. Then check:
   `ls -d /tmp/vmr-customgpu-run*` says `No such file`, `git -C ~/Developer/g-cqd/VMRunner worktree list` shows only the main checkout, and `git -C ~/Developer/g-cqd/VMRunner status --short`
   shows nothing new (the build wrote only into the worktree). `ls -t $TMPDIR/CFNetworkDownload_* 2>/dev/null` against the start: curl makes none.
5. Mounted images: `hdiutil info | grep -i vmr` prints nothing (the run mounts none). `df -g /tmp` is back near the first figure.
6. The report says what was removed and what was left (the defaults file if it stayed; the report itself).

## Verification of this card (done when it was written; no virtual machine started, no window opened)

Checked on a scratch copy of the chain tip (`ae136ef699bb3afab6648137bd50382efa6ca3ac`, built debug there, deleted afterwards):

- The three bundles that `mkbundle.sh` writes (with a 1 MiB placeholder disk and the real `seed.iso` made from this card's `user-data` and `meta-data`) load through the app's own library and
  loader, and an uncommitted test asserted: the folder name equals the id, Linux, `isProvisioned`, 2 CPUs and 2048 MiB, NAT, serial console, runtime limit 15, one read-only extra disk, no installer
  and no spec, `gpu` `custom` for `cg-a` and `cg-b` and `apple` for `cg-c`, the three bundle files exist, **no unapproved host path** (no approval prompt), the machine's storage devices are the disk and a
  read-only virtio seed disk, `--start cg-a` resolves to that machine, and (control) an approvals file that already exists and names nothing would leave the seed disk unapproved. Output:

```
􀟈  Test run started.
􀄵  Testing Library Version: 2084
􀄵  Target Platform: arm64e-apple-macos14.0
􀟈  Suite TempRunConfigTests started.
􀟈  Test anApprovalsFileThatAlreadyExistsWouldNotApprove() started.
􀟈  Test theGeneratedBundlesLoadAsTheRunNeedsThem() started.
TEMP control: unapproved = ["/tmp/tcards-F-doc/work/seed/seed.iso (extra disk, read-only)"]
TEMP cg-a id=DC4EF6A7-2558-4701-8DF5-398431355EA0 folder=DC4EF6A7-2558-4701-8DF5-398431355EA0.vm
TEMP cg-b id=876B5C45-C8F3-4BB0-8A1D-A9CDA46B226A folder=876B5C45-C8F3-4BB0-8A1D-A9CDA46B226A.vm
TEMP cg-c id=87F32B4A-686C-4ED9-BD07-76AF388FD271 folder=87F32B4A-686C-4ED9-BD07-76AF388FD271.vm
􁁛  Test theGeneratedBundlesLoadAsTheRunNeedsThem() passed after 0.082 seconds.
􁁛  Test anApprovalsFileThatAlreadyExistsWouldNotApprove() passed after 0.082 seconds.
􁁛  Suite TempRunConfigTests passed after 0.082 seconds.
􁁛  Test run with 2 tests in 1 suite passed after 0.083 seconds.
```

- `user-data` parses with Ruby's YAML (`["users", "ssh_pwauth", "write_files", "runcmd"]`; with the D replacement also `package_update` and `packages`); the three scripts extracted from it are
  byte-identical to the sources, `dash -n` accepts the shell ones and Python's `ast` the reader. The reader, run on the Mac against named pipes standing in for event devices, produced the
  expected lines (press, release and repeat counts, a held key listed as down, the rested pointer position, min and max of the axes, per-device summaries).
- `hdiutil makehybrid -iso -joliet -default-volume-name cidata` gave a 921 600-byte ISO that mounted read-only with `meta-data` and `user-data` identical to the sources.
- `ax` compiled without warnings and refuses a pid that is not the scratch app (exit 77), a missing pid (69) and a missing `VMR_APP` (64). `mkefi` made the 131 072-byte store and 70-byte identifier.
- `launch.sh`, `waitfor.sh`'s loop, `collect.sh`, `digest.sh`, `sample.sh` and `cpu.awk` were run against a stand-in app (a script that serves a console socket, prints marker lines and
  starts a process named like the framework's helper): the pids, the stamped console log, the helper discovery, the CPU table and the per-phase means came out as described.
- The commands of steps 1, 3 (the checksum and listing logic, against a locally made archive and sums, with a mismatch control), 4 (ISO), 5, 6, 7 and D1 were extracted from this card and run as written
  in a rehearsal with a 1 MiB placeholder disk, then everything the rehearsal made was removed; `waitfor.sh` was run for its three outcomes (seen, not seen within the time, app gone).
- The Debian URL still answers a `302` and then `200` with `Content-Length: 300023540`, and `SHA512SUMS` lists `debian-13-generic-arm64.tar.xz`. `/usr/bin/log show` with the card's predicate runs without privileges.

Not verified: anything that needs a guest or the built app (the guest's kernel, `python3` and the autologin in the image, X, the app's Accessibility tree, the `Start` button's accessibility name,
Screen Recording permission, the defaults write reaching the app, `defaults delete` removing the plist file).
