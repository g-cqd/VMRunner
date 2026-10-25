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
  space to see whether that notifies it too (the headers name no other way to signal the guest). The rules of serving an
  element are in the library (`GPUDeviceState.serve`, over a `QueueElement` protocol each adapter conforms its framework's
  element to), tested with a fake element: one read, an oversized request refused after its header, an answer written only
  when it fits, the element given back exactly once on every path.
- The cost of a transfer is bounded by the backing's pieces, not the picture's rows: a rectangle as wide as its resource is one
  span, listed once and copied once per piece. A narrower one is read one span per row and is refused above 8192 rows, the
  height of the Linux driver's largest scanout, so a hostile resource cannot hold the main queue for millions of rows.
- The app's adapter (`Sources/VMRunner/Engine/CustomGPU`, macOS 27 only): the framework's delegates over the library, guest
  memory read through one bounds-checked copy, a configuration for the machine's `customVirtioDevices`, sinks for the
  scanout's pictures and the guest's cursor, and a request to resize the display, which writes the configuration space and
  answers the next display-information request with the new size. The size may be up to 8192 on a
  side as long as one picture fits a resource (64 MiB), so 4K and 5K are allowed and 8K is not; a cursor image above 256 on a
  side is treated as no cursor. A queue notification is served in turns of at most 32 elements: when a turn ends on its
  budget, another is scheduled on the main actor, because the guest does not notify again for the rest of a batch and the
  framework offers no look at the queue without taking an element (the library's `serveTurn`, tested with a fake queue).
- The builder: a Linux machine set to the custom GPU gets that device as its one custom virtio device and no framework
  graphics device; the USB keyboard and pointer stay on the framework path. The machine's factory makes the device on the main actor
  (`CustomGPUSession`: the device and the `CustomScreen` it draws on, seen by the rest of the app only as a
  `CustomDisplaySource`) and the machine object holds it, because the framework holds the device it makes weakly. Its
  display starts at the size the start chose, scaled down to the library's limits. A host older than macOS 27 refuses the
  machine with a message. It has not run against a guest: the host tests check the configuration the builder hands the
  framework and the library's behaviour.
- The machine's window: a layer-backed view whose layer contents are the newest picture, scaled to fit over black, with the
  guest's cursor as a layer above it, placed by the guest's position and hot spot. The screen (`CustomScreen`) hands the view
  one picture per 16 ms at most, the newest, and keeps no timer while nothing waits; the view makes one image per picture it
  is handed. The image reads the guest's bytes where they are (the bitmap description names where red, green and blue sit
  for each of the eight formats), so making it costs one copy of the bytes (4 MB at 1280 × 800, 33 MB at 4K), not a pass over
  the pixels. Full screen swaps the view; the new one draws the screen from its newest picture, and the device keeps
  running. The view takes the keyboard and passes every key, pointer and scroll event to the machine's input surface
  (`GuestInputSurface`); without a surface it swallows them.
- Input, the framework's path: a Linux machine on the custom GPU keeps the USB keyboard and screen-coordinate pointer, and
  its input surface is a `VZVirtualMachineView` that is never shown and has no graphics device to draw. It sits in the
  window's container below the picture's view, which stays on top and first responder and forwards each event to it, so it
  cannot hide the picture; its frame is the rectangle the picture occupies (`ScreenPlacement.pictureRect`), which is what
  makes a point of the view land on the guest pixel under it when bars surround the picture. The view does not resize the
  display (`automaticallyReconfiguresDisplay` is off) and takes `capturesSystemKeys` from the machine's setting. A developer
  default, `CustomGPUInput` (`framework`, the default, or `virtio`; any other value is `framework`), is read once when a
  machine is prepared, and names the path. Whether the framework's view takes events passed to it this way, from a view
  that is not the first responder, is unknown.
- Input, the virtio path: the app links `Sources/VirtioInput` and implements two custom virtio devices with it (ID 18, PCI
  class 9 subclass 0x80, an event and a status queue, version 1, the 136 bytes of the library's keyboard and tablet layouts,
  no save and restore), added to the machine's custom devices after the GPU; the machine then has **no** USB keyboard or
  pointer, so that the guest sees only virtio input and the two paths compare cleanly. The device keeps the buffers the
  guest posts on the event queue, without giving them back, and gives each back exactly once with one event in it (the
  library's queue pairs them, drops whole frames when full and gives back, unwritten, a buffer over its limit of 1024); the
  status queue is read once per element and decoded. A reset or a stop forgets the buffers held and gives none back, because
  the guest's queue is reset with the device and the framework raises an exception when an element is returned to a queue
  that no longer has it. The window's events are translated by the surface: keys through the library's table (a key it does
  not map is ignored, the guest repeats a held key itself), modifiers by the change of the flags and the key that changed,
  the pointer as a position over the rectangle the picture occupies (a point on the bars lands on the picture's edge), the
  left, right and middle buttons, and a vertical wheel only (16 points of a trackpad make a notch, a guess). When the window
  stops being key or the view stops being first responder, every key and button held is released. The shared parts of the
  two adapters are one configuration builder and the queue element wrappers; the host tests drive the queue rules with fake
  elements, the translation with fake events and the builder with the configuration the framework is handed, never a machine.
- Resizing follows the window like the framework's display does for a Linux guest: the same policy (`DisplayFollower`) drives an
  adapter (`CustomGPUResizableDisplay`) over the device. A request sets the size the next display-information answer reports
  and writes the configuration space twice, the display event cleared and then set, so that every write after the first
  differs from the one before it (the guest's write to `events_clear` never reaches the host's copy, so the event would
  otherwise stay set, and a second update with the same bytes might not interrupt the guest). The guest has answered when
  it flushes a picture of the size that was asked for; the display's size is that of the newest picture, so a guest that
  never draws at the new size is reported as ignoring the request and asked again, as with the framework's display. A size
  the device cannot report (zero, a side above 8192, a picture over one resource) is refused. None of this has run against
  a guest.
- The scanout: `--headless-dump` writes the newest picture to `scanout.png` in the scratch directory (at most once a
  second), `--window` shows it in the runner's own window. The picture goes through a temporary file created with mode 0600
  and renamed into place, so it is never readable by others, not even for a moment.
- The end of a run: the time limit, the guest stopping, SIGTERM and SIGINT all take the same orderly path, which writes
  `commands.log` and the last picture; a signal is received through a dispatch source on the main queue, with no code in
  signal context, and ends the process with 128 plus its number. A second signal while the machine is stopping ends the run
  at once.
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
  their times. A SIGTERM ended the runner of that run without writing `commands.log` or the last picture; the runner now
  ends orderly on a signal (see above), which no guest run has exercised yet. The guest's page size was not recorded (the
  Debian kernel is normally 4 KiB; unverified). Nothing of 3D was tried; the device offers none.

## Remaining

1. The cost of a flush: the library copies the scanout's rows once on each flush (about 4 MB at 1280 × 800) before the screen
   decides whether to draw it, and a scrolling console flushed over 300 times a second. A picture made only when the window
   asks would avoid that copy for the flushes it skips; it has not been measured in the app.
2. Resizing, against a guest: that the clear-then-set writes make a second and later resize re-trigger the display-information
   request (one update was measured above, 0 ms later), and what the Linux driver does with a new size (whether it keeps the
   console, how long it takes, whether it asks for a size above what one resource holds).
3. The input path: both exist (above) and neither has run against a guest. The real-guest run decides which one stays, by
   comparing them: whether the guest's driver binds the two virtio input devices, how it classifies them (the static
   configuration is a workaround for the missing callback for the guest's write of `select` and `subsel`: the guest reads one
   bitmap for every question the Linux driver asks, each layout is chosen so that a model of the driver's probe accepts it, and
   the side effects, such as the keyboard also looking like an accelerometer to the guest's device manager, were read from the
   sources of the guest's device manager and input library, never run), whether the framework's view takes events passed to it
   from another view, the latency of each, the system keyboard shortcuts (the framework's capture setting has no effect on the
   virtio path), the scroll steps, and whether a key stays stuck after the window loses the keyboard.
4. The guest's cursor image and its alpha: the cursor layer draws the guest's image with its alpha, tested with generated
   images only; a real guest's cursor has not been seen.
5. A comparison with the framework's own graphics device: frame latency, CPU and memory per resource.
6. 3D acceleration is not in scope of this work.
