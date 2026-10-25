---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0014
---
# 0014 — Metal for macOS guests is on; a custom device for Linux is a spike

Study: `docs/research/gpu-acceleration-2026-10.md`. A virtio-gpu device (macOS 27) was the open question; the first real run
below answers it for a stock Linux guest. ADR-0058 decides where the code lives from here on.

## Built so far: a host-implemented virtio GPU for a feasibility study, 2026-10-25

- The code is in the root package (ADR-0058, which moved it out of a package of its own): `Sources/VirtioGPU` is the pure
  library, importing nothing, under `package` access; `Sources/VirtioGPURunner` is the executable, run by the owner only,
  with its command line in `Sources/VirtioGPURunnerCore`. The app does not link the runner and `vmr build-app` does not
  build it; layering tests keep it so, and the gate formats, lints, builds, tests and analyzes all of it.
- The machine: a headless Linux guest booted by EFI from a raw disk, an optional cloud-init seed as a read-only second
  disk, entropy, the serial console written to a file in a scratch directory, no network, no keyboard or pointer, none of
  the framework's graphics devices, and one custom virtio device: a GPU (device 16, display class) with a control and a
  cursor queue, version 1 and no optional feature (two-dimensional only), one scanout. At most 2 CPUs, 2048 MiB and an
  hour; the scratch directory is never the home folder or the Library. `--dry-run` validates and starts nothing.
- The two-dimensional command set, decoded from a single copy of each request with every guest length, count and offset
  checked: display information, create, release, attach and detach backing, transfer to the host, set the scanout,
  flush, the cursor requests; answers with the fence echoed. Resources live under limits (256 resources, 64 MiB each,
  256 MiB in all, 16 384 backing entries) and a transfer copies from guest memory without partial writes.
- The device wiring: each queue element read once, handled, answered when the guest left room and given back exactly
  once; a bounded record of the last 1024 requests and their times, written to `commands.log` at the end, which shows
  whether giving an element back notifies the guest; `--probe-config-change` sets the display event in the configuration
  space to see whether that notifies it too (the headers name no other way to signal the guest).
- The scanout: `--headless-dump` writes the newest picture to `scanout.png` in the scratch directory (at most once a
  second), `--window` shows it in the runner's own window.
- Checked on the host first: tests of the decoder, the store, the device state and the record with table-driven and seeded
  random hostile input, and `--dry-run` on macOS 27.0.1, where the framework accepted the configuration once the binary
  was signed with the virtualization entitlement. Then one real run, below.

## The first real-guest run, 2026-10-25

One run of the runner, headless, with `--probe-config-change 30`, 2 CPUs and 2048 MiB, on macOS 27.0.1 (a Mac15,12). The
guest was a stock Debian 13 arm64 image (kernel 6.12.113, not patched; its command line held only the root device). It
powered itself off after 189 s. What was seen, in the runner's log, in `commands.log` and in the guest's own probe:

- **The guest finds and binds the device.** The GPU enumerates as `1af4:1050`, class `0x038000`, on `virtio-pci`. The
  `virtio_gpu` driver binds by itself: `virtio-gpu-pci detected`, features `-virgl -edid -resource_blob -host_visible`, one
  scanout, a framebuffer console (`virtio_gpudrmfb`) of 1280 × 800 at 32 bits per pixel. No timeout, stall or error from the
  driver in the kernel log.
- **Giving an element back notifies the guest.** The display information was answered 1885 ms after the machine started
  and the guest's next request arrived 1 ms later: `returnToQueue` alone raises the used-buffer interrupt, there is no
  stall and no wait for the driver's five-second timeout.
- **A configuration update notifies the guest.** Setting the display event in the configuration space (the update took under
  1 ms) made the guest ask for the display information again 0 ms later. The guest's counters show one configuration-change
  interrupt in all, which is read as this update's. This is the signal a resize needs.
- **The command mix and the answers.** 4401 requests: 2197 transfers to the host and 2197 flushes, 3 scanout settings, 1
  create, 1 attach, 2 display-information requests. Every answer was OK; no request was oversized, no answer failed to fit
  the guest's buffer, no read or write of a queue element failed. The backing lists, read through the framework's guest
  memory mapping, gave transfers that were all answered OK and a picture with real console text.
- **The negotiated features** were subset 0 `805306368` (`0x30000000`, bits 28 and 29) and subset 1 `5` (bits 32 and 34),
  though the device offers `VIRTIO_F_VERSION_1` alone. By the standard numbering the extra bits are indirect descriptors,
  event index and packed rings. They come from the framework: the header of `VZCustomVirtioDeviceConfiguration` says that
  "a few feature bits are always set internally by default for optimal performance" among the optional features. A device
  must not assume that the negotiated set is the offered set.
- **The picture.** The first PNG was written 1.9 s after the start (1280 × 800, format `b8g8r8x8`); 184 were written in all
  (one a second at most). The last one shows the shutdown text of the guest, white on black, so the console reaches the
  scanout. The login prompt and a marker line printed earlier had scrolled away by then.
- **The cost.** The runner used a mean of 5.1 % CPU (peak 14.9 %, sampled every 5 s) and 56 MiB resident at most. The traffic
  is bursty: 11.6 transfer and flush pairs a second on average, about 640 requests a second while the shutdown text
  scrolled. The guest's 2048 MiB live in the framework's helper process, not in the runner: 100 % CPU while the guest
  booted, then 0.3 to 0.4 %, and 297 MiB resident at 1 s, 665 MiB at 61 s, 687 MiB at 182 s.
- **Limits of the run.** `commands.log` keeps the last 1024 requests, so the early ones are only in the runner's log with
  their times. A SIGTERM ends the runner without writing `commands.log` or the last picture. The guest's page size was not
  recorded (the Debian kernel is normally 4 KiB; unverified). Nothing of 3D was tried; the device offers none.

## Remaining

1. The app's side (ADR-0058): the pure core as a library of the root package, the queue serving shared by the app and the
   runner, the app's own adapter in the engine, and a Linux machine whose display is this device, shown in the machine's
   window. Everything behind macOS 27.
2. A bounded cost per request. A transfer copies a rectangle row by row, and the app would run the device on the main queue,
   so a large or hostile transfer must have a bounded cost in time as well as in bytes.
3. Resizing the display: the configuration update re-triggers the display-information request (measured above); the device
   must answer it with the new size, and the size limits are the library's.
4. The runner's follow-ups: a private temporary file for the scanout picture from the moment it is created, and an orderly end
   on SIGTERM and SIGINT that still writes the record and the last picture.
5. A keyboard and a pointer for such a machine: a virtio input device under the same rules as the GPU (ADR-0058 item 7).
6. A comparison with the framework's own graphics device: frame latency, CPU and memory per resource.
7. 3D acceleration is not in scope of this work.
