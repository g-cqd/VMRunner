---
status: done
blocked-by: []
date: 2026-10-21
---
# 0001 — Run macOS and Linux guests from a SwiftUI app

The app creates, installs and runs macOS guests (images from ipsw.me or a local `.ipsw`) and Linux guests (official
installers or any arm64 UEFI ISO), with CPU, memory, disks, audio, shared folders, suspend/resume, snapshots and
duplicate, all editable in the app.

## Still owed

Real-hardware runs for every guest and feature combination are recorded by hand; CI cannot start a VM.
