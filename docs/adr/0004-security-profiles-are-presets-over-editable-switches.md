---
status: accepted
date: 2026-10-21
---
# 0004 — Security profiles are presets over editable switches

## Context

Users want secure defaults and the ability to adjust one channel without leaving the preset. A single "secure" flag hides
what a guest can reach.

## Decision

1. Four presets: Standard, Contained, Isolated, Hardened. Choosing one sets individual switches; every switch stays
   editable; the profile reads "Custom" once the switches deviate.
2. A summary lists what the guest can reach on the host (network, clipboard, shared folders, devices, vsock, audio).
3. Presets narrow channels and never claim to make an untrusted guest safe.
4. Secure Boot is switched on by Isolated and Hardened only where the host supports it (macOS 27); the host capability
   gates it.
5. The entropy device is never removed: the guest needs it for randomness.
6. Hardened turns on disposable disks, turns off suspend (it writes RAM to disk), sets a runtime limit and removes shared
   folders.

## Consequences

Each new channel adds a switch, an exposure line and a help topic.

## What this does not decide

Host-side process sandboxing per machine; see the sandboxing study.
