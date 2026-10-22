---
status: accepted
date: 2026-10-22
---
# 0034 — A Linux guest starts on a legible screen and follows the window after its firmware

## Context

ADR-0002 caps the width a Linux guest starts with at 1280 pixels so that UEFI and GRUB text stays legible, and has the guest
follow the window once Linux runs. The owner still saw tiny firmware and boot loader text on a Retina display. Reading the
paths that decide the screen the firmware sees (roadmap 0038) found three gaps between the decision and the code:

1. The cap applied to the "match window" size only. A preset or custom size (the editor offers 2560 × 1600 and 1920 × 1080)
   and the configured size used when no window size is known were handed to the firmware as they were.
2. The code that makes the guest follow the window asked for the window's full size 150 ms after the first layout, with no
   regard for the boot. A request that lands before the firmware has read its display replaces the capped starting size. A
   refused request was swallowed and never repeated.
3. ADR-0002 says that changing the size discards a saved state and that the UI says so. Neither is true: a suspended machine
   restores at the size remembered from its cold boot and ignores the settings until its state is discarded.

The remembered size was the first suspect and is not a cause: it is written once, by a cold boot, with the start size already
computed, and it is read only to restore. The size the guest follows the window to is never written back.

## Decision

1. The starting size is one pure function, `StartDisplay.size(for:window:restoring:)`. Its inputs are the guest, the window in
   points, the pixels per point (`displayScale`), the match-window and fixed-size settings, whether the guest follows the
   window, the remembered size and whether a saved state is being restored.
2. For a Linux guest that follows the window, a cold start never exceeds 1280 pixels wide, whether the size comes from the
   window or from a preset, a custom size or the configured fallback. The shape of the source is kept (the window's, or the
   fixed size's) and both sides are even. The remembered size plays no part in a cold start.
3. A saved state wins over the cap. It restores only into an identical configuration, so a restored machine starts with the
   remembered size, which is the start size of the run that was saved. The firmware has already run, so there is nothing left
   for the cap to protect. The editor and the help say that a suspended machine resumes at the size it started with.
4. A fixed size chosen together with "Resize guest display with window" switched off is kept as chosen: the guest stays on it
   for the whole run, and the help says that the firmware text is then small.
5. A Linux guest's display is left alone for ten seconds after a cold boot, and then follows the window. The policy (the quiet
   period of a live resize, sizes under 64 points ignored, huge windows scaled down, a refused request logged and retried with
   growing delays, no request while neither the target nor the display's reported size changed) is `DisplayFollower`, tested on
   a test clock. A view made later in the run, such as the one full screen swaps in, is not held.
6. macOS guests are unchanged: they follow the configured density and the framework's own resizing.
7. `automaticallyReconfiguresDisplay` stays off for Linux guests. The documentation says the display then reconfigures to
   match the host display environment; the code has assumed since the interface landed that this means Retina-scaled pixels
   for a Linux guest, which was not re-verified here. Either way the framework would reconfigure the display at the first
   layout, bypassing the cap and the hold. The documentation does not say what the firmware does with either.

## Consequences

The starting size of a Linux guest is the same number on every path and can be tested. A large fixed size no longer reaches
the firmware, and the guest moves to the window's size after boot. The first ten seconds of a cold boot show the window at the
capped size; a window resized during that time takes effect when the hold ends. Whether ten seconds is right, and whether the
firmware reads its display once, are not established without a guest and are listed in roadmap 0038 for the owner to confirm.

## What this does not decide

How the framework's firmware picks its screen mode, and what GRUB does with the modes it is offered; both are not documented.
The boot loader and console font settings, which are the guest's own (the help names them). Acceleration: nothing draws the
firmware's screens but the CPU, and Linux guests get no 3D acceleration from the framework (ADR-0014).
