---
status: accepted
date: 2026-10-21
---
# 0014 — 3d acceleration is metal for macos guests only

## Context

Users asked for 3D acceleration for every guest.

## Decision

1. macOS guests get Metal through the paravirtualized graphics device; the app enables it.
2. Linux guests have no 3D acceleration under this framework; the help says so, correcting an earlier claim that no guest
   had it.
3. A custom virtio-gpu device (macOS 27) is a spike, not a commitment.

## Consequences

Linux guests render in software. See `docs/research/gpu-acceleration-2026-10.md`.

## What this does not decide

Whether a custom device can be made to perform acceptably.

(Update 2026-10-25: item 3 has a feasibility study of its own, `Packages/VirtioGPU`, outside the app: a two-dimensional
virtio GPU implemented by the host through the macOS 27 custom virtio devices, tested on the host only. No guest has
booted with it yet; roadmap 0014 says what was built and what is left. The status is unchanged.)

(Update 2026-10-25, after the first real-guest run: a stock Debian 13 arm64 guest bound its `virtio_gpu` driver to the
device, carried 2197 transfer and flush pairs without an error and was notified both by giving a queue element back and by
a configuration update; this replaces "no guest has booted with it yet" above. Performance is measured for that one guest
only (the runner used a mean of 5.1 % CPU); it is not compared with the framework's own device. ADR-0058 moves the pure
part of the study into the root package so the app can use it. Item 3 stays "not a commitment", and the status is
unchanged.)
