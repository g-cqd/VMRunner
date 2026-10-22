---
status: pending
blocked-by: []
date: 2026-10-22
decision: ADR-0002
---
# 0039 — Resizing the window must realign, rescale and recenter the guest screen, and never corrupt it

**Priority: very high, with roadmap 0037 and 0038.** The owner reports that resizing the window does not work: the shown
guest screen does not realign, does not rescale, does not recenter, and the screen state ends up corrupted in the window.
ADR-0002 and roadmap 0002 describe the intended behaviour (the guest follows the window at its aspect ratio, a letterboxed
centred picture, full screen replaces the toolbar by the bare view). Roadmap 0002 was marked done without a real-guest check
of resizing, so this is treated as a defect until a guest shows otherwise.

## Hypotheses to test

1. **The view and its container.** The machine view sits in a container that hides its intrinsic size, with autoresizing and a
   SwiftUI frame; the layout pass, the view's own centring of a scaled picture, and the container's bounds can disagree.
2. **The two resize paths disagree.** A macOS guest relies on the framework's automatic reconfiguration; a Linux guest on this
   app's debounced reconfiguration at a fixed scale. Each is applied from `updateNSView`, which SwiftUI calls on every state
   change, and a failed reconfiguration is swallowed, leaving the bookkeeping of the last applied size wrong (a corrupted
   state that no later resize repairs).
3. **The debounce.** The display-resize debounce moved onto an injected clock earlier on the same day; the code reads as
   equivalent (the resizer is the view's coordinator, which SwiftUI keeps alive) but is unproven against a guest.
4. **Window sizing and aspect ratio** (the window's content aspect ratio, resize increments, the remembered window size,
   restoring from a saved state or a snapshot) fight the view's own scaling.
5. **Full screen and toolbar hiding** transitions leave the view with a stale size or layer contents.
6. **Layer content placement and redraw**: stale or mis-scaled layer contents after a live resize.
7. **Recreation of the view** when SwiftUI rebuilds the representable.

## Done when

1. The size and placement policy (which size the guest is asked for, how the picture is scaled and centred in the container,
   what happens when the guest refuses) is pure code with tests over realistic sequences: live resize, full screen in and out,
   start, restore, tiny and huge windows, a refused reconfiguration, both guest kinds, both densities.
2. No failure is silent: a refused reconfiguration is logged and the bookkeeping is corrected so the next resize retries.
3. The owner confirms on a macOS guest and a Linux guest: drag-resize, maximise, full screen in and out, and an external
   display; the picture stays aligned, scaled to the window and centred, with no stale or corrupted area. The sizes at each step
   (window points, scanout pixels) are in the diary.
