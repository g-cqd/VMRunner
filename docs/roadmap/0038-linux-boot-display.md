---
status: pending
blocked-by: []
date: 2026-10-22
decision: ADR-0002
---
# 0038 — The Linux boot display: firmware and boot loader text must be legible

**Priority: very high, right after roadmap 0037.** In a Linux guest the boot loader (GRUB) and the firmware screens appear tiny:
the glyphs are drawn at a fixed pixel size on a framebuffer that is far larger than the window shows comfortably, so the
text is unreadable on a Retina display. ADR-0002 already says the Linux starting width is capped at 1280 pixels so that
firmware text stays legible; the owner still sees tiny text, so either the cap is not reached on some path or the boot loader
picks its own mode.

## What can and cannot be promised

- **GPU acceleration cannot apply at this stage.** The firmware and the boot loader draw into a plain framebuffer
  (the firmware's graphics output) before any guest driver exists; there is no acceleration to enable. Linux guests get no 3D
  acceleration from the framework at all (ADR-0014; roadmap 0014 is blocked on a macOS 27 host). What can be fixed is the
  resolution and scale of that framebuffer, and the guest's own console font after boot.
- The boot loader's graphics mode is chosen inside the guest by its own configuration (GRUB's `GRUB_GFXMODE`,
  `GRUB_GFXPAYLOAD_LINUX`) and by what the firmware offers; this app controls only the scanout the firmware sees.

## Hypotheses to test, in order

1. **A remembered size overrides the cap.** The last display size is remembered per machine and `fitsWindowAtStart` applies at
   start; a size remembered from a large window (the guest follows the window once Linux runs) may be reused for the next
   boot, so the firmware starts on a framebuffer of several thousand pixels.
2. **The cap applies to width only on some paths** (a fixed preset, a saved machine state, a changed density setting, a
   restored snapshot or duplicate).
3. **`pixelsPerPoint` above 1** multiplies the scanout beyond the cap.
4. **The firmware offers several modes** and the boot loader picks the largest instead of the scanout's; the app cannot change
   that, but it can offer a mode list that makes the right one the largest.
5. **After boot the console font** is tiny because the kernel console sizes the font by pixel count; a guest-side setting
   (`fbcon=font:`) or a larger-pixel console is needed, which the help can say.

## Done when

1. The scanout size at start is computed by one pure function with tests covering the cap, the remembered size, the presets,
   density, snapshots, duplicates and saved states; the starting size for a Linux guest never exceeds the cap, whatever was
   remembered, and the guest still follows the window after boot.
2. The owner confirms on one Linux guest (the installer, the boot loader menu, the first console) that text is legible at a
   Retina display and at an external display, and the numbers (scanout size, window points) are in the diary.
3. The help says what is guest-side (boot loader mode, console font) with the exact settings, and what is not possible
   (acceleration before the guest's driver loads).
