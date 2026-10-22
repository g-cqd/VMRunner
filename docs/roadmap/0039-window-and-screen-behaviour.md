---
status: in-progress
blocked-by: []
date: 2026-10-22
decision: ADR-0034
---
# 0039 — Resizing the window must realign, rescale and recenter the guest screen, and never corrupt it

**Priority: very high, with roadmaps 0037 and 0038.** The owner reports that resizing the window does not work: the shown
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

## Findings (2026-10-22, from the code, the documentation and unit tests; no guest was started)

The history of the display view is two commits: `adaf03f` (the SwiftUI interface) and `f619ee5` (the debounce on an injected
clock). No other commit touched it, so there is no later regression to find.

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| 1 | View and container | **Not established; two defects fixed** | `DisplayContainer` reported its size only from `layout()`, which AppKit calls when it decides to; it now also reports from `setFrameSize`. The framework's view letterboxes and centres the picture itself, which the documentation does not describe (nothing on layers, superviews or letterboxing): that part needs a guest |
| 2 | The two resize paths | **True, defects found and fixed** | (a) `updateNSView` wrote `automaticallyReconfiguresDisplay` and `capturesSystemKeys` on every SwiftUI update; they are now written only when the view's own value differs, which also repairs the property if the framework switched it off on one of two views of the same display (documented: "only one view respects the property"). (b) `try? display.reconfigure` swallowed a refusal, nothing retried it, and the next attempt waited for another layout. (c) `lastApplied` was never reset on a machine change or when the display moved by itself, so the same size could be skipped for good. (d) A view that laid out again and again at one size kept restarting the debounce and postponed the request without end. (e) The first request was made 150 ms after the first layout while the machine was still starting. All are covered by `DisplayFollowerTests` |
| 3 | The debounce | **Equivalent** | The diff of `f619ee5` replaces a cancellable `Task.sleep` with `Debouncer` and keeps the quiet period (150 ms), the captured size and the reading of scale and machine at fire time. The coordinator is the `DisplayResizer`, kept alive by SwiftUI for the life of the representable. The tests show the last size of a burst is the one requested |
| 4 | Window sizing and aspect ratio | **Refuted: there is none** | No `contentAspectRatio`, `resizeIncrements`, `contentMinSize` or style-mask code exists; only `WindowReader` reads the window, and `VMRunnerApp` sets a minimum size of 960 × 600. "The guest follows the window aspect ratio" in ADR-0002 means the guest's framebuffer, not a constraint on the window. A saved state or snapshot does not touch the window |
| 5 | Full screen | **A risk, unproven** | `ContentView` swaps the whole split view for a bare `MachineView(...).id(id)` when full screen starts and back when it ends, so SwiftUI makes a new `VZVirtualMachineView` and a new coordinator each time, for a machine that is running. The documentation says only one view per display honours `automaticallyReconfiguresDisplay`; which of two views keeps it is not documented, and the property is now read back and repaired. Whether the new view draws a stale frame needs a guest |
| 6 | Layer content and redraw | **Not decidable here** | The app sets no layer property on the framework's view |
| 7 | Recreation of the view | **See 5** | Besides full screen, `.id(id)` recreates the view when the selection changes; `updateNSView` does not recreate it |

### What is proven and what only a guest can show

Proven by unit tests (`DisplayFollowerTests`, `DisplayResizerChoiceTests`, `DisplayDiagnosticsTests`), on a test clock and a
fake display: a burst of sizes (a drag) is one request for the last size, after the quiet period; sizes under 64 points, `nan`
and infinity ask for nothing and a tiny view after a good one does not cancel the good request; a huge window is scaled down to
7680 × 4320 keeping its shape; a request is skipped only while neither the target nor the display's reported size changed, a
display that moved by itself is asked again, and a guest that ignores a request is not asked for the same size twice; a refused
request is logged and retried after 0.5, 1, 2, 4 and 8 seconds, then given up until the view changes, and a new size cancels a
pending retry; nothing is requested while the firmware holds, and a view made after the hold, restored, or for macOS is not held;
a sequence of start, drag, maximise, full screen in and out ends on the last window size; who resizes (framework, app, nobody)
and the pixels per point for the densities.

Only a real guest can show: whether the framework's view recentres and rescales after a live resize; what the firmware does with
the first display size it is given; whether a Linux guest's driver responds to a request at all (the documentation says it may
not, without an error); what a new `VZVirtualMachineView` draws when full screen swaps it in; and whether any of defects (a) to
(e) is the owner's symptom. None of them is demonstrated to be.

### Diagnostics

`open VMRunner.app --args --display-diagnostics` logs, under the `display` category, the sizes at each step: every layout and
frame change of the container (container and machine view points, window points, backing scale, full screen), each setting
written to the framework's view with the value it held, each request for a new size with the display's size before it, its
outcome or refusal, and the framework's own begin and end of a display reconfiguration (for macOS guests too). The starting
display is logged always. Read it with `log stream --level info --predicate 'category == "display"'`.

## Done when

1. The size and placement policy (which size the guest is asked for, how the picture is scaled and centred in the container,
   what happens when the guest refuses) is pure code with tests over realistic sequences: live resize, full screen in and out,
   start, restore, tiny and huge windows, a refused reconfiguration, both guest kinds, both densities. **Done for the size
   policy**; scaling and centring are the framework view's own and are not code of this app.
2. No failure is silent: a refused reconfiguration is logged and the bookkeeping is corrected so the next resize retries. **Done**.
3. The owner confirms on a macOS guest and a Linux guest: drag-resize, maximise, full screen in and out, and an external
   display; the picture stays aligned, scaled to the window and centred, with no stale or corrupted area. The sizes at each step
   (window points, scanout pixels) are in the diary. **Open.**

## Owner confirmation

Use the release app (`swift run vmr build-app`), once with a macOS guest and once with a Linux guest, and keep the log running:

```sh
open VMRunner.app --args --display-diagnostics
log stream --level info --predicate 'category == "display"'
```

For each step write down what you see (aligned, scaled to the window, centred; black bars; a stale or torn area; an offset
picture) and copy the log lines it produced. After each step wait two seconds so the quiet period has passed.

1. Start the machine; for Linux wait ten seconds after the boot starts (the display follows the window then).
2. Drag the window edge slowly to a larger and then to a smaller size, and a corner diagonally.
3. Maximise (green button), then restore the window to its earlier size.
4. Enter full screen (View menu, not ⌃⌘F) and leave it. This replaces the machine view; it is the step most worth watching.
5. Move the window to the external display and resize it there; then back.
6. With "Resize guest display with window" off (in the machine's Display section), resize the window: the picture should scale and stay centred.
7. Suspend, resume, and repeat step 2.

Report, per step: the window size in points and the scanout size in pixels (the log lines `container … pt`, `asked for … px`,
`framework finished reconfiguring the display; it is … px`), the backing scale, and any line that says `refused` or
`view.automaticallyReconfiguresDisplay was … now …`. If a step corrupts the picture, say which one first did.
