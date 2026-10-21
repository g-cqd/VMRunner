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

Linux guests render in software. See `docs/gpu-acceleration.md`.

## What this does not decide

Whether a custom device can be made to perform acceptably.
