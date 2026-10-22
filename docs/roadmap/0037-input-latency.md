---
status: in-progress
blocked-by: []
date: 2026-10-22
---
# 0037 — Input latency: keyboard and mouse must reach the guest with no delay we can remove

**Priority: highest. This comes before every other item in roadmap 0036.** The owner perceives a clear delay between a key or
mouse event on the Mac and the guest reacting; the aim is that no delay under our control remains, and that every remaining
millisecond is measured and attributed to a named stage. Nothing here may be guessed: each cause is shown by a measurement
before a fix is called done.

## What can and cannot be promised

Input-to-pixel latency has parts this app does not own: the guest's own scheduling and compositor, the display refresh
(a 60 Hz frame is 16.7 ms, a 120 Hz frame 8.3 ms), and Virtualization.framework's internal delivery. The target is therefore
stated per stage:

| Stage | Owner of the code | Target |
|---|---|---|
| Event arrives in the app until the framework's view has handed it on | this app | under 0.2 ms, and no main-thread stall above 1 ms while a machine runs |
| Framework delivery to the virtual device | the framework | measured and reported, not changeable |
| Virtual device model (USB HID polling for Linux, paravirtual keyboard and trackpad for macOS) | the framework, chosen by this app | chosen to be the lowest-latency option available, measured |
| Guest handling and display | the guest | measured with a guest-side timestamp, reported |

## Hypotheses to test, in order of likelihood

The order below follows the audit in [the input latency study](../research/input-latency-2026-10.md), which also holds the
evidence for and against each item and the owner's measurement protocol. The owner runs the bundled release app
(`swift run vmr build-app`), so the debug build is demoted; the app's own path to the framework is a direct view on the main
thread with nothing else on it, so the stages outside the app move up. Nothing has been measured yet.

1. **The stages the app does not own**: the framework's delivery to the machine's process, the virtual USB device model (Linux
   guests, and a macOS guest with the "Mouse" pointer; the API offers no polling or virtio input option), the cursor the guest draws
   for an absolute pointer, and the guest's own scheduling. Measure with the guest-side timestamp of the protocol; compare Trackpad
   with Mouse on macOS.
2. **Main-thread work during input.** The framework's view receives events on the main thread, so anything else on it delays them.
   One flood path was found and fixed: filtered networking published one main-actor job per flow event (now batched). The latency
   monitor reports any other stall with the work inside it.
3. **App Nap and timer coalescing.** A running machine now holds a latency-critical activity assertion (a setting, on by default,
   with the energy cost stated in help). Its effect is to be measured with the setting on and off.
4. **The view and its container**: first-responder handling, an extra layer or overlay, layer-backed redraw policy, a scaled or
   resized view, system-key capture, and the translucent window chrome. No overlay or extra layer was found while a machine runs;
   compare windowed with full screen. The display code is changed by other work.
5. **Frame pacing and power**: display refresh, ProMotion behaviour, graphics device configuration, the guest's own sync, battery and
   Low Power Mode.
6. **The hardened profile** (`vmr build-app release --hardened`) changes the heap allocator; which profile the owner runs is not known.
7. **Debug, sanitizer or debug-info builds**: excluded for the bundled release (`-c release`, no unsafe flags, sanitizers only in the
   `vmr check --full` build directories); revisit only if the bundle carries `get-task-allow`.

## Done when

1. A latency monitor (enabled by a launch argument, free when off) records: the time from the event's timestamp to the
   moment the view receives it; main run-loop iteration times and stalls above a threshold with the work that caused them;
   signposts around the input path for Instruments. Its pure parts are unit tested on the test clock.
2. A written, owner-run measurement protocol exists (release build; Instruments System Trace and Points of Interest; a
   guest-side timestamp of the event's arrival compared with the host's send time; what to report) and its results are in the
   diary, per stage, for one macOS and one Linux guest.
3. Every avoidable cause that is found is fixed with a regression test (for example the activity assertion, moving work off
   the main thread, bounding event publishing), and each fix is shown to reduce the measured number.
4. What remains is listed with its owner (framework, guest, display) and a number.
