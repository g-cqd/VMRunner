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

## Verified on a real guest (2026-10-22)

Same session and machine as roadmap 0038 (Alpine, Linux, 2 CPUs, 2048 MiB, release app, ad hoc signed, no `get-task-allow`; the
"Keep input responsive" setting at its default, on), with `--input-latency` and a summary file. Synthetic key and pointer events
were posted to the app's process only with `CGEventPostToPid`, for 60 seconds each, while the guest ran `ping` every 0.2 s and a
loop of `wget` to two web sites. The host was busy with other work (a video call and builds), which matters for the figures below.

| Run | Key age p50 / p90 / p99 / max, per 10 s | `main busy` p50 / p99 / max, per 10 s |
|---|---|---|
| NAT, guest idle at the login prompt (events from a private source) | 3.7–5.8 / 12.6–14.7 / 16.2–17.0 / 17.0 ms | 0.06–0.20 / 0.79–0.98 / 1.0–1.15 ms, once 47 ms and once 30 ms (both with 29–37 ms of `wake`) |
| NAT, guest network active | 6.3–7.9 / 14.7–15.7 / 16.8–17.5 / 17.5 ms | 0.10–0.13 / 1.3–1.4 / 1.7–1.8 ms |
| Filtered (default policy), guest network active | 4.2–7.3 / 13.6–16.8 / 16.7–18.9 / 22.9 ms | 0.04–0.12 / 0.36–1.31 / 0.46–1.78 ms, once 20 ms (`wake` 20 ms), once 5.4 ms |
| Sparse typing, one key every 150–200 ms (the first interval of two runs, 78 and 33 keys) | 0.5 and 0.8 / 1.3 and 13.6 / – / – ms | – |

- **The key age is not the app's.** Under a steady stream of events the age spreads evenly from 0 to about 17 ms, a 60 Hz
  frame, and the main thread was free (`main busy` at most 1.8 ms) while events waited: the delay is in how the events were
  delivered to the process (`CGEventPostToPid` and the window server), not in work on the app's main thread. Sparse events, which
  do not queue behind each other, arrive in 0.5–0.8 ms at the median. Whether events from the keyboard hardware behave like the
  sparse ones was not measured.
- **Stalls the app owns.** With the guest's network running in the Filtered runs, `flow log batch` appears once among the stall
  attributions, at 0.017 ms. Five stalls of 62–98 ms (98, 84, 75, 73 and 62 ms) and one of 161 ms (92 ms of it `wake`) appeared in the Filtered session,
  around the start of the guest's network activity and once in a quiet interval; their attributed work was empty (`wake` of a few
  hundredths of a millisecond, three or four passes), so the cause is not in the instrumented work. They are not seen in the 60 s
  posting runs that followed. The start of a machine itself stalls the main thread for 300 ms, 160 ms and 144 ms (the
  configuration is built on the main actor, listed in the study as a start-up cost, not input). Intervals of 20–47 ms whose time is
  all `wake` are scheduling delays on a loaded machine.
- **What the monitor missed.** While a pointer button was held in the view (a drag), 550 key presses reached the guest and the
  monitor counted none: events consumed inside the view's own tracking loop do not pass `sendEvent`. Pointer moves posted to the
  process (2 700 a minute) were not counted either (`pointer n=0`), so no pointer figure was obtained.
- **Cannot be measured this way.** The framework's delivery to the virtual machine, the virtual USB device, the guest's handling
  and the display are not seen by the app-side monitor, and the setting for App Nap was not compared on and off. The input
  to pixel latency was not measured at all.
