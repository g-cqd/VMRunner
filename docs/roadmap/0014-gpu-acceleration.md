---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0014
---
# 0014 — Metal for macOS guests is on; a custom device for Linux is a spike

Study: `docs/research/gpu-acceleration-2026-10.md`. A virtio-gpu device (macOS 27) is the open question.

## Built so far: a host-implemented virtio GPU for a feasibility study, 2026-10-25

- `Packages/VirtioGPU`, a package of its own that the app never links or bundles (a layering test keeps the root manifest
  and the root sources free of it); the gate formats, lints, builds, tests and analyzes it. `VirtioGPURunnerCore` holds
  everything that can be tested without a machine; `VirtioGPURunner` is the executable, run by the owner only.
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
  once; a bounded record of the requests and their times, written to `commands.log` at the end, which shows whether
  giving an element back notifies the guest; `--probe-config-change` sets the display event in the configuration space
  to see whether that notifies it too (the headers name no other way to signal the guest).
- The scanout: `--headless-dump` writes the newest picture to `scanout.png` in the scratch directory (at most once a
  second), `--window` shows it in the runner's own window.
- Checked on the host only: tests of the decoder, the store, the device state and the record with table-driven and seeded
  random hostile input, and `--dry-run` on macOS 27.0.1, where the framework accepted the configuration once the binary
  was signed with the virtualization entitlement. No guest has booted with the device yet: whether a guest finds it,
  binds its driver and shows a console is not verified.

## Remaining

1. The authorised real-guest run: a stock Linux image with the GPU driver, the device's first boot, the command record,
   the picture of the console in `scanout.png`.
2. The notification question: whether giving an element back, or a change of the configuration space, reaches the guest.
3. Resizing the display, and the display event that tells the guest.
4. A comparison with the framework's own graphics device: frame latency, CPU and memory per resource.
5. 3D acceleration is not in scope of this work.
