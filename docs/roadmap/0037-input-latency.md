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

1. **Debug build.** `swift run` builds without optimisation; every main-thread cycle of the app, which also handles the view's
   events, is slower. Compare with `vmr build-app` (release).
2. **App Nap and timer coalescing** throttle an app that the system thinks is idle. A running machine should hold a
   user-interactive, latency-critical activity assertion (with an energy cost that is stated in the settings help).
3. **Main-thread work during input.** The framework's view receives events on the main thread, so anything else on it delays
   them: SwiftUI re-evaluation, the display resizer, flow-log and activity publishing from the network stack (which can flood
   it), logging, observation churn, toolbar updates, the window reader.
4. **Device choice.** The Linux guest uses a USB keyboard and a USB absolute pointing device, whose polling interval can add
   milliseconds that no app code can remove; the macOS guest uses the paravirtual keyboard and trackpad. A "mouse" pointing
   device on a macOS guest also selects the USB device.
5. **The view and its container**: first-responder handling, an extra layer or overlay, layer-backed redraw policy, a
   scaled or resized view, system-key capture.
6. **Frame pacing**: display refresh, ProMotion behaviour, graphics device configuration, and the guest's own sync.
7. **Sanitizer or debug-info builds** being the ones the owner runs.

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
