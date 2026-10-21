---
status: accepted
date: 2026-10-21
---
# 0002 — The guest display follows the window aspect ratio

## Context

A guest that starts at the window's exact pixel size draws UEFI and GRUB text at fixed glyph sizes, which is tiny on a
large window. A saved machine state restores only into an identical device configuration; changing the display size or
the MAC address between runs made restore fail with "invalid argument".

## Decision

1. The guest starts at the window's aspect ratio at one pixel per point. For Linux the starting width is capped at 1280
   so firmware text stays legible, and the view scales it. Once Linux is running the display follows the window.
2. macOS follows the configured pixel density. A fixed preset can replace the automatic size.
3. The NAT MAC address and the starting display size are pinned in the machine's settings so a saved state restores.
4. There is exactly one display: the framework supports one scanout per graphics device, and two are rejected.
5. In full screen the toolbar and sidebar are replaced by the bare machine view, because collapsing the split view left a
   gap.

## Consequences

The last display size is remembered per machine, and changing it discards a saved state, which the UI says.

## What this does not decide

Multiple displays, which would need a second graphics device the framework does not offer for these guests.
