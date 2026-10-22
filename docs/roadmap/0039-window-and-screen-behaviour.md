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
outcome or refusal, and the framework's own begin and end of a display reconfiguration (for macOS guests too). Two things are
logged always, without the argument: the starting display with the rule that chose it, and, for every request a Linux guest was
asked, whether the guest responded or did not within two seconds (`reconfigure(sizeInPixels:)` returns no error either way). Read
them as in "Reading the always-on lines" below.

## Done when

1. The size and placement policy (which size the guest is asked for, how the picture is scaled and centred in the container,
   what happens when the guest refuses) is pure code with tests over realistic sequences: live resize, full screen in and out,
   start, restore, tiny and huge windows, a refused reconfiguration, both guest kinds, both densities. **Done for the size
   policy**; scaling and centring are the framework view's own and are not code of this app.
2. No failure is silent: a refused reconfiguration is logged and the bookkeeping is corrected so the next resize retries. **Done**.
3. The owner confirms on a macOS guest and a Linux guest: drag-resize, maximise, full screen in and out, and an external
   display; the picture stays aligned, scaled to the window and centred, with no stale or corrupted area. The sizes at each step
   (window points, scanout pixels) are in the diary. **Partly**: a Linux guest on one display, windowed; a defect found and fixed; macOS, full screen and an external display remain (see "Verified on a real guest").

## Owner confirmation

Use the release app (`swift run vmr build-app`), once with a macOS guest and once with a Linux guest, and keep the log running.
The `Starting display` and `Display resize:` lines are logged without a launch argument; add `--display-diagnostics` (`open
VMRunner.app --args --display-diagnostics`) for the per-layout lines this list also asks for.

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
`framework finished reconfiguring the display; it is … px`), the backing scale, whether each request got `guest responded` or
`guest did not respond` (a macOS guest has none of these lines: the framework resizes it), and any line that says `refused` or
`view.automaticallyReconfiguresDisplay was … now …`. If a step corrupts the picture, say which one first did.

### Reading the always-on lines

These lines need no launch argument. They are notices, which the unified log keeps on disk, so they can be read after the fact
or while the app runs:

```sh
log show --last 10m --predicate 'category == "display"' --info
log stream --level info --predicate 'category == "display"'
```

Four kinds of line matter (sizes are pixels, window sizes are points; nothing identifies a machine or a path):

1. **`Starting display W×H px for a window of W×H pt; host screen scale S, guest pixels per point P; source …, width cap …,
   remembered size …; match window …, follows window …, restoring …`**: the scanout the firmware is given, and why. `source` is
   `window`, `fixed size`, `configured size, no usable window` or `saved state`. `width cap` is `applied` (the size was reduced
   to 1280 pixels wide), `in force, not needed` (already within it) or `does not apply` (macOS, a saved state, or a fixed size
   with following switched off). `remembered size` is `ignored` (a cold start never uses it), `used` (a saved state) or `none`.
   A second `Starting display` line in one run, with `restoring false`, means the restore failed or could not happen and the
   machine booted cold on the size a cold start has.
2. **`Display resize: guest responded: asked W×H px, the framework reports W×H px`**: the framework reported the end of the
   reconfiguration, so frames arrived at the requested size. The guest's driver used the size; a reported size that differs
   from the asked one means the guest settled on another.
3. **`Display resize: guest did not respond within 2.0 seconds: asked W×H px, the framework reports W×H px`**: the framework
   accepted the request (it returns no error either way) and no end of the reconfiguration came in two seconds. The guest did
   not use the size, and the machine view shows "The guest ignored the display resize (firmware and boot loader screens
   cannot follow the window)." until the next response. A `guest responded` line after it means the guest answered late. Expected
   while the firmware, the boot loader or the installer's early console is on screen; for a guest that has booted, it means
   its display driver does not act on the size, which is a finding to report. The size the framework reports is the display's
   size at that moment: for an ignored request it is normally still the size from before.
4. **`Display resize: asking again (repeat N) for W×H px: the guest has not answered`**: an ignored request is repeated after 2,
   4, 8 and 16 seconds and then every 30 seconds, because the guest's display driver may load after the firmware and the boot
   loader and only then answer. Each repeat is followed by `guest responded` (the repeats stop and the note in the machine view
   goes) or by another `guest did not respond`. The repeats also stop when the window gets another size (the count starts over),
   when the display shows the wanted size by itself (`display now shows W×H px, nothing left to ask`), and when the machine
   stops. If a booted guest answers the first repeat after the boot loader, the guest's driver was what was missing before.

A `refused` line (error level) is the framework rejecting the request; it is retried. No `Display resize` line after a window
change means nothing was asked: the first ten seconds of a cold boot, a view under 64 points, "Resize guest display with
window" off, a macOS guest (the framework resizes it and the follower does not take part), or the display already had the size
(`--display-diagnostics` shows which).

## Verified on a real guest (2026-10-22)

Same session and machine as roadmap 0038 (Alpine 3.24.2, Linux, NAT; release app, scratch data folder, only the app's window
captured and driven through the accessibility interface). No macOS guest and no full screen were tried: a macOS restore image is
a download of many gigabytes, and entering full screen would have taken over the owner's screen during a call.

**Defect found and fixed (hypothesis 1, the view and its container).** After the first layout the framework's view never
followed its container again. Pre-fix log, after the window went from 1396×1022 pt to 1100×700 pt:
`layout: container 786×648 pt, machine view 1396×1022 pt`. The guest had answered the 786×648 px request, so the framework scaled that
picture to the oversized view (a scale of 1022/648 = 1.577, text 12.6 pt per character instead of 8) and the window showed its
centre: cropped on the right (the `[ ok ]` column was gone), the top rows under the translucent toolbar, the picture offset by 78 pt.
That is the owner's "does not realign, rescale or recentre, and corrupts". Cause: the view switches off
`translatesAutoresizingMaskIntoConstraints` itself (printed by a probe), so the container's autoresizing mask did nothing once
SwiftUI sized the container with constraints; a probe with a container sized by constraints left the view at 0×0. The four edges are
now pinned. `DisplayContainerTests` sizes a container the way SwiftUI does and fails five of five sizes on the old code. After the
fix, every `frame:` line reads `container W×H pt, machine view W×H pt` with equal sizes (786×648, 1100×648, 1186×948, 1686×1148,
2246×1556).

**What the guest does with a resize (not a defect of the app).** The Linux text console keeps the framebuffer it made when the
system started: in the guest `fb0` stayed 1184×948 (`virtual_size`, console 59 rows × 148 columns) while the display was asked for
1096×648, 1686×1148 and 2246×1556, and the DRM connector listed 1096×648 as its preferred mode. Rebinding the console
(`echo 0 > …/vtcon1/bind`, then `1`) did not change it. Consequences, all seen on screen with the setting "Resize guest display
with window" on: a smaller display shows the top-left of the console at 1:1, cropped; a larger one shows the console scaled and
offset; the picture is never wrong with the setting off (screenshots at 1186×948, 1500×1000 and 980×640 pt: whole, centred,
letterboxed, scaled to the window, legible at every size). The help and the editor now say so. A guest whose display server
changes the mode (a desktop) was not available and is not claimed to follow; that is untested.

**Decision left to the owner.** For a console-only guest (an installer, a server) the setting should be off, because following
the window cannot work. Making it the default for new Linux machines is one line (`VMConfig.new`), but it reverses ADR-0034 item 5
for desktop guests, which could not be tested here, so it is not done. Existing machines keep their stored setting.

| Step | Window (pt) | Asked / answered | Picture |
|---|---|---|---|
| start | 1500×1000, view 1186×948 | nothing to ask | whole, 1:1 |
| drag smaller | 1100×700, view 786×648 | 786×648 px, 0.36 s | cropped (guest console, see above); with the setting off: whole, centred, scaled |
| sidebar hidden | view 1100×648 | 1100×648 px, 0.36 s | cropped |
| larger | 2000×1200, view 1686×1148 | 1686×1148 px, 0.80 s | scaled and offset (guest console) |
| zoom (Window menu) | 2560×1608, view 2246×1556 | 2246×1556 px, 0.80 s | scaled and offset (guest console) |

Launching the app was not reliable in the session: `open -n -a` opened a window on 3 of 7 tries (the four failures came late, after
several quits), and running the bundle's binary directly on 3 of 4 (the failure had a different preferences folder set). A process
without a window had no `Starting display` line and no windows in the accessibility tree; the cause was not found and is not known
to be in the app. The machine view also does not take the keyboard by itself: after a start, a click
in the view is needed before typing reaches the guest (a follow-up, not changed).

A real run showed a second cause of "the window state is wrong": a stale entry in the system's restoration store for the app's bundle id made every launch open no window (the log said the app had state to restore and then created nothing; a reopen event, or launching with the ignore-state default, opened it). The app has no documents to restore, so it now registers `ApplePersistenceIgnoreState` at every launch (in memory, never written), and never restores windows.
