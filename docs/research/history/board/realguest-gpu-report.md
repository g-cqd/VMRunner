# Real-guest GPU run (Q-RUN): host-implemented virtio GPU on macOS 27.0.1

Date 2026-10-25. Seen = read from a log or file of this run. Inferred = my reading.

## Host and inputs (seen)
- macOS 27.0.1 (`sw_vers`), arm64, Mac15,12. `main` = 2974518 (chain Q's eight commits visible in `git log`). Free space 65 GB.
- Build: release, `exit=0`, 6.6 s, detached worktree, scratch path under `/tmp`. Ad hoc signature, hardened runtime, one entitlement. `--describe` matched the card (ID 16, class 3/128, 2 queues, VERSION_1, display event bit 1, config byte 9 = 01).
- Download: the HEAD request answers a 302 to a mirror (umu.se); with `-L` Content-Length 300023540 (286 MiB). Fetched with `--max-filesize 1073741824`, HTTPS only, vendor SHA512SUMS over HTTPS: `OK`. No signature checked.
- Seed: the 3-space indentation was stripped; user-data written with a quoted heredoc and parsed by Ruby YAML (four `runcmd` entries as expected). seed.iso 921600 bytes.
- Run: 2 CPUs, 2048 MiB, `--max-seconds 600 --headless-dump --probe-config-change 30`, no `--window`. Runner pid 71845. No screenshot, click or keystroke. The 660 s cap did not fire.

## Results table

| # | Claim | How observed | Verdict |
|---|---|---|---|
| 2 | Runner started the machine, no error; device created at 0.017 s, machine running 0.126 s | runner log | YES |
| 3 | Enumeration `0000:00:09.0 vendor=0x1af4 device=0x1050 class=0x038000 driver=virtio-pci` | guest probe | YES |
| 4 | DRIVER_OK at 1.885 s after start; features "subset0 805306368 subset1 5" | runner log | YES. Not VERSION_1 only (see deviations) |
| 5 | virtio_gpu bound: lsmod lists it; dmesg `[drm] pci: virtio-gpu-pci detected at 0000:00:09.0`, `features: -virgl -edid -resource_blob -host_visible`, `-context_init`, 1 scanout, `Initialized virtio_gpu 0.1.0`, `fb0: virtio_gpudrmfb`; card0 and renderD128 exist; `card0-Virtual-1 status=connected`, modes start `1280x800`; `fb0 name=virtio_gpudrmfb size=1280,800 bpp=32` | guest probe | YES |
| 6a | Notify via returnToQueue alone: first GET_DISPLAY_INFO answered at 1885 ms, next request at 1886 ms (runner: "the guest sent a request 1 ms after the display information was given back"). No stall, no 5 s wait | runner log, commands.log header | YES |
| 6b | /proc/interrupts, device `virtio4`: control vector 2380 (first probe) and 3002 (second); cursor 0 (no cursor commands); config vector 1 in both probes | guest probe | YES for used-buffer interrupts |
| 6c | Config update at 31895 ms (display event set, completed); `display info requested again after the update at: 31895 ms` (0 ms later); GET_DISPLAY_INFO count 2 in commands.log | runner log, commands.log | YES: the configuration update notifies the guest |
| 6d | `virtio_gpu` timeout, stall or error lines in dmesg | the probe's dmesg grep, 60-line tail | NOT SEEN (none) |
| 7 | scanout.png exists, 1280 x 800, 8-bit RGB | `file`, `sips` | YES |
| 8 | Command mix (4401 requests): GET_DISPLAY_INFO 0x100 x2, RESOURCE_CREATE_2D 0x101 x1, SET_SCANOUT 0x103 x3, TRANSFER_TO_HOST_2D 0x104 x2197, RESOURCE_FLUSH 0x105 x2197, RESOURCE_ATTACH_BACKING 0x106 x1. Responses: 0x1100 OK_NODATA 4399, 0x1101 OK_DISPLAY_INFO 2. No non-OK response, 0 oversized, 0 answers that did not fit, 0 failed reads or writes | commands.log | YES (all expected commands, no errors) |
| 9 | Cost, see below | runner log, stats | n/a |
| 10 | Guest powered itself off: "device stopping" at 189.342 s, "the guest stopped", exit well before the 600 s limit. I did not capture the runner's numeric exit status (my watcher only waited on the pid) | runner log | YES (status itself not seen) |

## Cost (seen)
- Times from runner start: DRIVER_OK 1.885 s; first command (GET_DISPLAY_INFO) 1.885 s; first SET_SCANOUT 1.886 s; first RESOURCE_FLUSH 1.888 s; first PNG written 1.913 s (format b8g8r8x8, 1280 x 800). 184 PNGs written in total (throttled to 1 per second).
- 2197 flush/transfer pairs in 189 s (mean 11.6 per s). They come in bursts: the last 1024 retained entries span 187738 to 189342 ms (about 640 requests per s) while the shutdown text scrolled.
- Runner (38 samples at 5 s): mean CPU 5.1 %, peak 14.9 %, peak RSS 56944 KiB.
- Framework helper (the Virtualization XPC service, pid 71847, parent 1; read only): CPU 100.4 % while booting (first sample, 1 s), then 0.3 to 0.4 %; RSS 297168 KiB at 1 s, about 665000 KiB at 61 s and 122 s, 686864 KiB at 182 s. The 2048 MiB guest lives in that helper, not in the runner. No other helper process was running before the run (ps showed none).
- The runner log and commands.log are from the runner. The log's two `[31.895]` lines show that the update itself took under 1 ms.

## Timing of the config probe against the guest probe (seen)
The update (runner time 31.9 s) came before the first guest probe (guest uptime 121.6 s, about 120 s after the run began; cloud-init's final stage ran late, as the review expected). So the two `/proc/interrupts` snapshots cannot separate it (config vector reads 1 in both). Per the card, commands.log decides: the re-request at 31895 ms is YES. Inferred: the single config-vector interrupt is the one from this update, since nothing else raised the config vector.

## Scanout (seen, read as a file)
`scanout.png` (1280 x 800) shows the final picture only: the systemd shutdown text ("Reached target poweroff.target", kernel lines `[188.3...] systemd-shutdown`, "reboot: Power down"), white on black. It does not show the tty1 login prompt or the `VMRUNNER GPU SCANOUT TEST` marker, because the final picture was taken after the guest scrolled them away. So the marker line and login prompt are NOT SEEN in the image. The fbdev console does reach the scanout (inferred from the shutdown text in it and from 2197 flushes with correct 1280 x 800 geometry). Console log has a `gpurun login:` prompt on the serial console, not a tty1 proof. Copy kept: `~/Developer/g-cqd/vmrunner-board/realguest-gpu-scanout.png`.

## Guest
Debian 13 generic arm64, kernel `6.12.113+deb13-arm64`, stock; cmdline only `root=PARTUUID=... ro`. virtio devices: 0x1043 class 0x078000 is the console, 0x1042 x2 are block (disk and seed), 0x1044 is entropy, 0x1050 is the GPU (device ids read as virtio ids 3, 2, 4, 16). All `virtio-pci`. No patched kernel.

## Comparison with the third-party reports (inferred)
- Not needed here: a patched guest kernel (stock Debian kernel bound `virtio_gpu` by device id), a newer host release (27.0.1, not 27.2), a newer Mac (Mac15,12). 4 KiB pages: I did not check the guest page size (not recorded; the Debian arm64 generic kernel is normally 4 KiB, unverified).
- Match: device creation, DRIVER_OK, queue notifications, guest-memory mapping (backing read worked: 2197 OK transfers with no error, and the PNG shows real console text).
- Not tested: any 3D claim (virgl, blob, context init are all off in this device).
- I cannot confirm that anything differs from the reports, since I only know them second hand.

## Deviations and defects
1. The Content-Length check on the first URL fails as written (302 redirect); with `-L` the size is 300023540. I proceeded; the download itself was capped at 1 GiB.
2. The first `curl` command failed under fish (`=https` glob); rerun under bash as the card says. No harm.
3. The negotiated features are not "VERSION_1 only": subset0 = 0x30000000 (bits 28 and 29) and subset1 = 5 (bits 32 and 34). Inferred: indirect descriptors, event index, VERSION_1 and one more high bit (34, packed ring, if the numbering is the standard one). Nothing broke.
4. commands.log keeps only the last 1024 requests, so the card's "first 40 entries" are not available; the header counts and the runner log's first-command lines (to the millisecond) cover the early timing instead.
5. The final scanout.png cannot answer question 3 (marker and login prompt) because it is the last picture. An earlier picture would need a different dump option (a code change, not done).
6. Runner exit status not recorded (watcher design gap, mine).
7. Several `device reset` lines (6 before DRIVER_OK: firmware, bootloader and kernel probing) are normal reset events, no error.
8. Nothing written to `~/Library`: `com.example.VMRunner.plist` size and mtime unchanged (2575 bytes, 1792786038) before and after.

## Cleanup (seen)
Removed: `/tmp/vmr-gpurun`, `-dl` (download and disk.raw), `-seed`, `-bin`, `-build`, `-pids.txt`, `-stats.txt`, `-build.log`, `-runner.log`, plus my extras `-progress.txt` and `-helpers-before.txt`; the worktree `VMRunner-chains/q-run` (removed and pruned; `git worktree list` shows only main); no VirtioGPURunner process and no framework helper left; no CFNetworkDownload leftovers (curl makes none; none before or after); no savedState folders. Kept: this report and `realguest-gpu-scanout.png`. The `VMRunner-chains` directory is empty or was not touched beyond the worktree.
