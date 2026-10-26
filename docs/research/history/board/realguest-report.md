# Real-guest report, 2026-10-22 (session RG)

VMRunner `main` at `a98fd14` (clean; `.vscode/` was already untracked). Mac: `Mac15,12` (MacBook Air, M3, 8 cores, 16 GiB),
macOS Darwin 25.6.0, on AC power and wired Ethernet, 69 GiB free on `/`. Everything ran by hand, one guest at a time.

## How the app was driven without a screen

- App: `swift run vmr build-app` (release, ad-hoc signed, hardened runtime; `entitlements OK (audio-input, virtualization)`)
  → `build/VMRunner.app` inside the repository. Not copied anywhere else.
- Scratch: `/tmp/rg-scratch` (mode 0700): `data/` (the app's `VMRUNNER_DATA_DIR`), `dl/` (images), `scripts/`, `shots/`.
- Launch (no activation, own data dir, `--start`):
  `open -g -n --env VMRUNNER_DATA_DIR=/tmp/rg-scratch/data -a build/VMRunner.app --args --start rg-linux`,
  pid taken with `pgrep -n -f .../VMRunner.app/Contents/MacOS/VMRunner`, plus a watchdog that kills only that pid after
  15 to 18 min. Each machine also had `maxRuntimeMinutes = 15` (the app's own hard limit), `cpuCount 2`, `memoryMiB 2048`.
- Stop: `vmr guest exec <sock> -- poweroff` (guest powers off, the app's state goes `running -> stopped`), then `kill <pid>`.
- The machine was written by hand, as the app's setup would leave it: `Machines/5E1F0000-0000-4000-8000-00000000A001.vm/` with
  `config.json` (`isProvisioned: true`, `serialConsole: true`, `installerISO`, ...), a sparse 2 GiB `Disk.img`, and
  `EFIVariables.fd` + `MachineIdentifier` made by a 15-line Swift tool calling the same `VZEFIVariableStore(creatingVariableStoreAt:)`
  and `VZGenericMachineIdentifier()` as `Provisioner.provisionLinux`. The approvals file was absent, so the app grandfathered the
  installer path at load (`Machines.approvals.json` then listed it). Config edits were made only while the app was not running.
- Console: `.build/debug/vmr guest exec /tmp/rg-scratch/data/Machines/<id>.vm/Console.sock --timeout 60 -- '<cmd>'`
  (the socket sits in the bundle: the path is under 103 bytes).
- Window: only the app's own window, by number: a Swift tool lists `CGWindowListCopyWindowInfo` entries whose owner pid is the
  app's, then `screencapture -x -o -l <window number>`. Nothing else was captured or driven; no keystroke was sent anywhere.

### The app's Alpine path gives no console (first finding)

First start used the unmodified, verified `alpine-virt-3.24.2-aarch64.iso` (the release the app's `alpineVirt` provider would
pick: 3.24.3 has no `.asc` yet). `sha256 OK`; `gpg --verify` → `Good signature ... using RSA key 0482D84022F52DF1C4E7CD43293ACD0907D9495A`
(the pinned fingerprint). The guest booted to `localhost login:` on `tty1` (own-window capture), but the console socket stayed
silent: `vmr guest exec ... → error: timed out waiting for a prompt; the console sent nothing meanwhile` (status 124, twice,
at about 20 s and 60 s). The ISO's `boot/grub/grub.cfg` has `console=tty0 console=ttyAMA0`, `set timeout=1`: no `hvc0`, and the
live system's init did not add a getty on `hvc0`. So **with the app's own Alpine catalog image, `serialConsole` gives a socket
with nothing on it**; a user would have to edit the kernel line in GRUB within one second.

Workaround used for every later run (the app still boots it, through its own `ConfigurationBuilder`): a 160 MiB FAT32 image
(`mkfile -n`, `hdiutil attach -nomount` + `newfs_msdos -F 32`, `diskutil mount -mountPoint` in scratch, copy of the ISO's files,
detach) whose `boot/grub/grub.cfg` is the ISO's with `set timeout=0` and `console=tty0 console=hvc0`, the ISO's own
`efi/boot/bootaa64.efi`, kernel, initramfs, modloop and `apks/`. It is attached the app's way, as `installerISO`
(read-only USB mass storage). With it: `cat /proc/cmdline` → `... console=tty0 console=hvc0`, and `exec` logs in as root.

## (A) R7 battery and power: PARTIAL (matches, but at one point only)

This Mac is a laptop (`Mac15,12`). The figures come from the app itself: the files its `HostInfoPublisher` wrote into the
bundle's `HostInfo/` folder during run 1 (all five `hostInfo` switches on), read on the host at 18:58:39:

```
battery: percent=100            pmset -g batt: Now drawing from 'AC Power'
power:   source=ac               -InternalBattery-0 ... 100%; charged; 0:00 remaining present: true
         lowPowerMode=0          pmset -g: lowpowermode 0
thermal: state=nominal
network: status=satisfied / interface=ethernet / expensive=0 / constrained=0
timezone: identifier=Europe/Berlin
ioreg AppleSmartBattery: CurrentCapacity=100 MaxCapacity=100 ExternalConnected=Yes FullyCharged=Yes (StateOfCharge=99 internally)
```

The same text was read in the guest through the share (R2). Verdict PARTIAL: the app agrees with `pmset` and the menu bar
figure (100 %, AC), but only in the trivial full-and-plugged case. Not observed: a partial charge, on battery, Low Power Mode on
(each needs unplugging the Mac or `sudo pmset`, which this session must not do).

## (B) R2, R3, R5 in a guest started by the app: PASS, one defect in R2

All runs: Alpine 3.24.2 live (`6.18.52-0-virt`), NAT unless stated.

### R2 host information share: PASS for mount, read and read-only; DEFECT on rewrite

Run 2 (19:03), `hostInfo` all on:

```
modprobe virtiofs; mkdir -p /mnt/h; mount -t virtiofs vmrunner-host /mnt/h   → mount=0
/proc/mounts: vmrunner-host /mnt/h virtiofs rw,relatime 0 0
ls: battery network power thermal timezone (root 0644), contents as in (A)
touch /mnt/h/newfile        → touch: /mnt/h/newfile: Operation not permitted
echo x >> /mnt/h/battery    → -sh: can't create /mnt/h/battery: Permission denied
rm /mnt/h/power             → rm: can't remove '/mnt/h/power': Operation not permitted
```

Updates without remount: the files are rewritten every 60 s (host mtimes 19:03:06, ..., 19:06:10, 19:07:14, 19:08:18; the
guest's inode for `battery` went 8 → 10 → 12 and `stat` showed the new mtime without a remount). The Mac's facts did not change
during the run, so to see a content change I replaced the host file myself (`printf 'percent=42\n' > battery.tmp && mv`):
the guest read `cat: can't open '/mnt/h/battery': No such file or directory` right after, and `percent=100` again after the
app's next rewrite.

**Defect: a reader in the guest gets ENOENT for about a second at every rewrite.** A loop in the guest reading `battery` every
0.1 s for 75 s across one rewrite: `ok=687 bad=8`, all eight failures between 17:08:17 and 17:08:18 UTC, the rewrite's time.
Cause (suspected): `HostInfoPublisher.publish()` (`Sources/VMRunner/Engine/HostInfoPublisher.swift`, `Data(...).write(to:
file, options: .atomic)`) replaces each file by rename, so the name points at a new inode, and the guest's virtiofs entry cache
still holds the old one until it revalidates. A guest agent polling these files will see them vanish once a minute. Options:
write in place (truncate and write: a short, rare torn read instead of a missing file), or document that readers must retry.

Not observed: a real change of a fact (battery, power source, path, time zone) propagating; Suspend with host information on
(Suspend is reachable only from the window); a macOS guest (`mount_virtiofs`).

### R3 NVMe and disk serial: PASS

- Run 2, `diskInterface: nvme`: `/dev/nvme0`, `/dev/nvme0n1` (size 4194304 sectors = 2 GiB), `ls /dev/vd*` → none;
  `/sys/class/nvme/nvme0/model` = `Apple Virtual NVMe Controller`, serial `APPLEvNVME0000`. The guest booted with its disk on NVMe
  (the system itself ran from the USB image; nothing was installed on the disk).
- Run 3, `diskInterface: virtio`, `diskSerial: RGSERIAL0001`: `/dev/vda`, `/sys/block/vda/serial` = `RGSERIAL0001`,
  `/dev/disk/by-id/virtio-RGSERIAL0001 -> ../../vda`.

### R5 vendor prefixes on NAT: PASS

The app made each address at start (`macAddress` was removed from the config before each run; the app wrote the new one back):

| `macVendor` | address the app stored | guest `ip link` | DHCP on NAT | HTTP |
|---|---|---|---|---|
| apple | `00:03:93:7f:9c:69` | same | `lease of 192.168.64.25 obtained from 192.168.64.1` | `wget http://example.com` OK |
| intel | `00:1b:21:fa:41:5b` | same | `192.168.64.26` | OK |
| realtek | `00:e0:4c:c5:08:34` | same | `192.168.64.27` | OK |
| locallyAdministered | `d2:6b:5d:de:de:c8` (bit 1 set, bit 0 clear) | same | `192.168.64.28` (run 7) | OK |

Side observation, not the app's: ICMP from the guest gets no answer on the framework's NAT, even to the gateway
(`ping 192.168.64.1` and `ping 1.1.1.1`: 100 % loss) while the Mac itself pings 1.1.1.1. TCP and DNS work.

## (C) R1 kill switch: PASS for the cut and for the reattached card; the live rule change does not exist

Config: `networkCutsOnMeteredPath: false`, `networkPolicy.vpn` as below; no VPN on the Mac (`scutil --nc list`: no services).

| Run | Mode | `vpn` | Guest at ~20 s uptime after `ip link set eth0 up` | Toolbar (own-window capture) |
|---|---|---|---|---|
| 5 | NAT | required | `carrier` 0, `<NO-CARRIER,...,UP> state DOWN`, `udhcpc: no lease, failing`, `wget: bad address` | orange `wifi.slash` icon shown |
| 6 | NAT | forbidden | `carrier` 1, `LOWER_UP`, lease `192.168.64.28`, HTTP OK | no icon |
| 7 | NAT | ignore (relaxed while stopped, restarted) | `carrier` 1, lease, HTTP OK | not captured |
| 8 | filtered | required | `carrier` 0, NO-CARRIER, no lease, HTTP fail | captured, not inspected |
| 9 | filtered | forbidden | `carrier` 1, lease `198.18.0.2` from `198.18.0.1`, HTTP OK | captured, not inspected |

- `attachment = nil` was accepted: no error, no stop, nothing in the app's log; the guest just lost carrier.
- Reattach: with `forbidden`, the watcher cuts at once on the unknown first path (`NetworkCutoff.start` → `apply(HostNetworkPath())`)
  and reconnects when the first `NWPathMonitor` sample says no VPN, so runs 6 and 9 boot with the card cut and then given back the
  **same** attachment object (`detachedAttachment`); the guest then got a lease and carried traffic, on NAT and on the filtered stack.
  The cut-then-reconnect itself is inferred from the code and the unit tests: the app logs neither, and it happened before the
  guest brought its interface up, so it was not seen happening.
- Live relaxation: not supported, as the code says: `NetworkCutoff` keeps the `VMConfig` it got at start, and
  `VMController.networkPolicyDidChange` forwards the policy to the filtered stack only. The rule was relaxed by editing the config
  while stopped and restarting (run 7).
- Traffic before the first cut: none seen. The cut runs right after `machine.start()` returns (`booting -> running` 70 to 150 ms
  after `preparing`); at that point the guest is still in firmware. The guest saw `NO-CARRIER` the first time it brought `eth0`
  up. A continuous ping could not run: the cut comes before userspace, and ICMP does not work on this NAT anyway.
- Not observed: a VPN coming up or going down on the Mac while the guest runs (no VPN here; bringing one up would change the
  owner's network), the metered switch on a hotspot, reattachment after restoring a suspended machine.

## (D) Vendor downloads (D07): app's own path NOT RUN; independent check PASS

The app resolves a catalog image only inside setup (`Provisioner.resolveMedia` → `LinuxCatalog.resolve`), which starts from the
New Machine sheet or Resume Setup. `--start` refuses a machine that is not set up. No launch argument or command runs a
download or resolve on its own, so the app's own path could not be run without driving its window.

**This is not the app's path.** `curl` + `gpg` read the same URLs as `LinuxProviders.swift`, with keys fetched from the vendors'
sites, each checked against the fingerprint pinned in `PGP+PinnedKeys.swift`. Only small files were downloaded; the ISOs were
checked with `HEAD`.

| Vendor | Signed file | Signature | Newest ISO (≥ app floor) | Listed in signed file | ISO on server |
|---|---|---|---|---|---|
| AlmaLinux 10 | `CHECKSUM` (cleartext) | Good, `EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572` | `AlmaLinux-10.2-aarch64-boot.iso`, `-minimal.iso` | yes (SHA256 lines) | 1128263680 / 1657339904 bytes |
| Rocky Linux 10 | `CHECKSUM` + `CHECKSUM.asc` | Good, `FC226859C0860BF0DDB95B085B106C736FEDFC85` | `Rocky-10.2-aarch64-boot.iso`, `-minimal.iso` | yes | 1120931840 / 2397044736 |
| Fedora Server 43 | `Fedora-Server-43-1.6-aarch64-CHECKSUM` | Good, `C6E7F081CF80E13146676E88829B606631645531` | `Fedora-Server-netinst-aarch64-43-1.6.iso` | yes | 1198647296 |
| Fedora Server 44 | `Fedora-Server-44-1.7-aarch64-CHECKSUM` | Good, `36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6` | `Fedora-Server-netinst-aarch64-44-1.7.iso` | yes | 1257783296 |
| Debian stable netinst | `SHA256SUMS` + `.sign` | Good, `DF9B9C49EAA9298432589D76DA87E80D6294BE9B` | `debian-13.7.0-arm64-netinst.iso` | yes | 735358976 |
| Alpine (for B) | ISO `.asc` | Good, `0482D840...9495A` | `alpine-virt-3.24.2-aarch64.iso` (3.24.3 unsigned) | `.sha256` OK | downloaded, 93 MB |

Each pinned fingerprint was in the key file from the vendor's site. The AlmaLinux and Rocky `CHECKSUM` files are byte-identical
to chain D's captures in `cards2/fixtures/raw`. Debian netboot: skipped, not built. Not observed: the app's own listing parser,
its verifier and its version floors on live data. Those were matched by eye (10.2, 10.2, 43-1.6, 44-1.7, 13.7.0 are at or
above the floors in `LinuxProviders.swift`).

## (E) R4 and D16, macOS guest: NOT RUN

`df -h /`: 69 GiB available, under the 80 GiB the brief requires, so the condition fails whatever is cached. The owner's
library was not searched for a restore image.

## (F) R6 managed preferences: NOT RUN; `defaults` check PARTIAL

No profile was installed (`profiles` needs root). `/Library/Managed Preferences` exists on this Mac (other domains) but has none
for `com.example.VMRunner`. A Swift reader that only reads printed `UserDefaults(suiteName: "com.example.VMRunner")
.objectIsForced(forKey:)` for every key in the user domain:
8 keys (`NSWindow Frame ...`, `NSSplitView Subview Frames ...`, `ipswDeviceIdentifier`, ...), all `forced=false`. The managed key
names (`AllowSharedFolders`, `AllowHostInformation`, `RequireDisposableMachines`, `MaxRuntimeMinutes`, ...) were absent and not
forced. Those values were written into the user domain, which is where `defaults write` writes, so the result matches
`ManagedPreferences` treating only forced values as policy. Limits: no `defaults write` was run, because that would write into
the owner's `~/Library/Preferences`. The forced case, the locks and the clamp were not observed.

## Defects and gaps found

1. **Host-information files vanish for about 1 s at every rewrite** (R2): 8 of 695 guest reads failed with ENOENT during one
   rewrite. Suspected cause: the `.atomic` rename in `HostInfoPublisher.publish()` together with the guest's virtiofs entry cache.
2. **`serialConsole` is silent with the app's own Alpine image**: its kernel line is `console=tty0 console=ttyAMA0`, so there is
   no login on `hvc0`. Either document that the console needs `console=hvc0` added, or don't present Alpine + console as ready to
   use (`Catalogs.swift` alpine-virt entry; ADR-0052).
3. **The kill switch is invisible in the log**: a cut, a reconnect and a refused attachment change are not logged
   (`VZGuestMachine.setNetworkConnected`, `NetworkCutoff.apply`). The only evidence is the toolbar icon. Logging these (reason
   and time) would make R1 checkable headlessly. The doc comment of `setNetworkConnected` says a change the framework refuses
   "is reported to the delegate", but `VZGuestMachine` implements only `guestDidStop` and `didStopWithError`, not
   `virtualMachine(_:networkDevice:attachmentWasDisconnectedWithError:)`, so such a report would go nowhere (read from the
   code; no refusal happened in these runs).
4. Not the app's, but seen: the owner's `~/Library/Preferences` holds a few hundred 42-byte `vmrunner-test-<UUID>.plist` files,
   the newest from 18:34 (before this session; none were made during it). Some test leaves a defaults suite behind on each run.
   Worth a cleanup in the test support.

## Cleaned

- Removed `/tmp/rg-scratch`: the machine bundle (config, 2 GiB sparse disk, EFI store, identifier, HostInfo, socket), the
  approvals file, the Alpine ISO and its `.asc`/`.sha256`, the FAT boot image, the extracted ISO tree, the vendor files and keys,
  the two scratch GnuPG homes, the helper tools and scripts, the window captures and the log capture. Also removed `/tmp/rg-buildapp.log`.
- Stopped: the app (one process per run, nine runs, each ended by `poweroff` and then `kill`), the watchdogs, `log stream`,
  and the `gpg-agent`/`scdaemon` of the two scratch GnuPG homes (`gpgconf --kill all`). The owner's own `gpg-agent` (pid
  31339, a day old) was left alone.
- The FAT image's `/dev/disk4` was unmounted and detached. `hdiutil info` lists only system images.
- After cleanup, `ps` shows no VMRunner, VMHelper, `log stream` or scratch-gpg process. `ls /tmp` has no `rg-*` entry, and
  `$TMPDIR/VMRunner-console` was never created. The domain `com.example.VMRunner.data-directory-override` does not exist. The
  owner's `com.example.VMRunner.plist` is unchanged (mtime 12:51:17), and so are `Caches/` and `HTTPStorages/com.example.VMRunner`.
- Kept, as allowed: `build/VMRunner.app` (rebuilt) and `.build/` in the repository. `git status`: only the `.vscode/` that was
  already untracked; HEAD is still `a98fd14`.
