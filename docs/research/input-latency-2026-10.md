---
date: 2026-10-22
question: "Where can a delay between input on the Mac and the guest come from, which parts can this app change, and how does the owner measure each?"
feeds: [roadmap 0037]
---
# Input latency: audit, instruments, and the owner's measurement protocol

**Status: audited and instrumented; nothing measured.** No virtual machine or app was started to write this (agents never
start them). Everything below is read from the code and the documentation, or is a plan for a measurement the owner runs.
Line numbers are those of base commit `ba74604`, before the changes of this study. The owner runs the bundled release app
(`swift run vmr build-app`), not `swift run`, which demotes the debug-build hypothesis (see the table).

## What the app can and cannot change

| Stage | Who owns it | Can this app change it? |
|---|---|---|
| Hardware event to the app (WindowServer delivery, the app's main thread being free) | the system, and this app's main thread | **Partly.** The app can keep its main thread free and keep macOS from throttling it. It cannot speed up the delivery. |
| The framework's view receives the event and hands it to the virtual machine | Virtualization.framework | **No.** `VZVirtualMachineView` is Apple's view, and the virtual machine runs in a separate process the framework starts, so every event crosses a process boundary. The app can only measure up to the moment it sees the event. |
| The virtual device (USB keyboard and pointer for Linux, paravirtual keyboard and trackpad for macOS) | the framework, **chosen** by this app | **Only the choice.** The public API offers two keyboard and two pointing configurations (below); there is no polling interval, no virtio input device and no other knob. |
| The guest handles the event and draws (the guest draws its own cursor) | the guest | **No.** |
| The frame reaches the screen (scanout copy, compositing, display refresh) | the framework, the system, the display | **No.** A 60 Hz frame is 16.7 ms, a 120 Hz frame 8.3 ms. |

The roadmap's target for the first row ("event arrives in the app until the framework's view has handed it on: under
0.2 ms, and no main-thread stall above 1 ms") is the only one this app can be held to. Every other row is measured and
reported, not fixed.

## The path an event takes, and what sits on it

1. The window server posts the event to the app. The app's main run loop wakes, AppKit takes the event off its queue and
   calls `NSApplication.sendEvent`, which sends it to the window and then to the first responder or the hit view.
2. The view is a `VZVirtualMachineView` in a container (`Views/Machine/VMDisplay.swift:11-21` builds it,
   `:69-93` is the container, which only forwards its size to `DisplayResizer`). The container has no event handling of its
   own. SwiftUI hosts it through `NSViewRepresentable` in the detail pane (`Views/Machine/MachineView.swift:48-52`).
3. The view hands the event to the framework, which forwards it to the virtual machine's process.

**Nothing in the app sits between steps 1 and 3 except the main thread itself**: anything else the main thread is doing
when the event arrives delays it by exactly that long. That is why the audit is a search for main-thread work.

## Audit

### The view and its container

- One `VZVirtualMachineView`, direct subview of an `NSView` with autoresizing (`VMDisplay.swift:78`), no overlay when the
  machine runs: the only overlay is the "Paused" badge, drawn only while paused (`MachineView.swift:50-52`). No gesture
  recogniser, no `onTapGesture`, no `allowsHitTesting` in the running pane.
- `updateNSView` runs whenever SwiftUI re-evaluates `MachinePane.body` and sets `capturesSystemKeys` and
  `automaticallyReconfiguresDisplay` each time (`VMDisplay.swift:20-30`). Setting a property to the value it has is very
  likely free, but nothing here shows it. It is not changed in this study; the monitor's signpost lets the owner see
  how often it runs (`display update` is a name the display owner can add with `InputPath.begin`).
- `DisplayResizer` debounces live resize by 150 ms (`:43`) and calls `display.reconfigure` at the end (`:65`): it runs only
  while the user resizes the window, not while they type.
- `DisplayContainer.layout()` (`:89`) calls back into the resizer on every layout pass: cheap, and a pass happens only on
  a size change.
- The whole window is a `NavigationSplitView` with a toolbar (`Views/ContentView.swift:21-30, 60-90`). In macOS 26 the
  toolbar and sidebar are translucent; a guest view below translucent chrome might cost the compositor extra work. This is
  a **hypothesis with no evidence**; full screen with the toolbar hidden (`ContentView.swift:12`) removes the chrome, so
  comparing the two attributes it without any code change.
- `WindowReader` (`ContentView.swift:92-110`) only reports the window in `viewDidMoveToWindow`; it never runs per event.

### What the main thread does while a machine runs

Observed state that changes while a machine runs, and who reads it:

| State | Changes when | Read by |
|---|---|---|
| `VMController.state` (KVO, `VMController.swift:234-243`) | the machine changes state | the toolbar, the sidebar dot, `MachinePane` |
| `VMController.deadline` | once at start | the toolbar timer label (`MachineToolbar.swift:28-30`: a SwiftUI timer text, redrawn by SwiftUI about once a second) |
| `NetworkActivity.flows`, `allowedCount`, `deniedCount` | **every flow event** (before this study) | only the open Network popover (`NetworkActivityPanel.swift:26, 56-59`); the toolbar button reads `vpn.symbol`, which does not change with flows |
| `NetworkActivity.guestVPN`, `VPNMonitor.state` | a verdict changes, or the Mac's network path changes | the toolbar button symbol |
| `VMLibrary.machines` | a setting is edited, the first boot, `library.update` | `MachineModel.phase` and so `VMDisplay` |

There is **no timer, no polling loop and no `Task.sleep` on a main-actor path that runs while a machine runs** except the
runtime limit's single sleep (`Model/RuntimeLimit.swift`) and the debouncers (idle unless used). There is no synchronous
file, JSON, regular-expression, hashing or clone call reachable from the toolbar or the running pane: `hasSavedState`
(a file check) is guarded by `model.isRunning ||` (`MachineToolbar.swift:52`). Two synchronous things on the main actor are
reachable, neither per input:

1. `ConfigPersistence.flush()` encodes and writes a machine's `config.json` on the main actor, 400 ms after the last settings
   change (`Model/ConfigPersistence.swift`). While a machine runs it fires after `recordFirstBoot` and when the network policy
   is edited. The monitor now signposts it as `config write`.
2. `VMController.start` builds the whole configuration on the main actor (`VMController.swift:59`: `ConfigurationBuilder.build`
   reads the hardware model and identifier files, validates, and for a disposable machine `prepareEphemeral` clones with
   APFS at `:57`). This is start-up only and not input, but the window is unresponsive during it. Not changed here.

The one flood path is **filtered networking**. The stack runs on its own thread (`Network/UserNetStack.swift:216-227`, quality of
service `userInitiated`, not the main thread) and publishes a `FlowEvent` per connection, lookup and denial into an
`AsyncStream` that keeps the newest 4096 (`:149`). Before this study `NetworkActivity` read it one event at a time on the main
actor and, for each, built a `FlowLogEntry` (string formatting), inserted at the front of an array and changed three observed
properties. A guest looking up names or opening connections by the thousand turned that into thousands of main-thread jobs
(`Engine/NetworkActivity.swift`, the `for await event in events` task and `record(_:)`). In NAT or "none" modes there is no such
stream. Logging on the stack's thread (`UserNetBridge.swift:222-232`, one `Log.network.info` per denial or failure) is off the main
thread and does not matter here.

Other `Log` calls: none on a path that runs per frame or per event (`grep` of `Log.` finds only start, stop, load, save and
download failures).

### Observation and SwiftUI

`VMController`, `MachineModel`, `NetworkActivity`, `VPNMonitor` and `VMLibrary` are `@Observable`. `MachinePane` reads
`model.phase`, which reads `library.jobs`, `config`, the controller's machine and builds a `DisplaySettings` value
(`MachineModel.swift:49-60`); `VMDisplay.updateNSView` therefore runs only when one of those changes. `MachineToolbar`'s
`runningControls` reads `isPaused`, `deadline`, `networkActivity` and `canSuspend`. None changes per input or per frame.

### Devices per guest (`Engine/ConfigurationBuilder.swift`)

| Guest | Keyboard | Pointer | Lines |
|---|---|---|---|
| macOS | `VZMacKeyboardConfiguration` | `VZMacTrackpadConfiguration` for "Trackpad"; **`VZUSBScreenCoordinatePointingDeviceConfiguration` for "Mouse"** | `:106-111` |
| Linux | `VZUSBKeyboardConfiguration` | `VZUSBScreenCoordinatePointingDeviceConfiguration` | `:143-144` |

The documentation's "Keyboards and pointing devices" collection (`virtualization/keyboards-and-pointing-devices`) lists exactly
these: `VZKeyboardConfiguration` with `VZMacKeyboardConfiguration` and `VZUSBKeyboardConfiguration`, and
`VZPointingDeviceConfiguration` with `VZMacTrackpadConfiguration` and `VZUSBScreenCoordinatePointingDeviceConfiguration`. There is
no virtio input device, no HID polling interval, no report-rate option. `VZMacTrackpadConfiguration` is recognised by macOS 13 and
later guests only. `VZVirtualMachineView` has three public properties: `virtualMachine`, `automaticallyReconfiguresDisplay` and
`capturesSystemKeys` (and, from macOS 27, `adaptor`, a `Sendable` wrapper around the machine for strict concurrency);
none affects event delivery or presentation timing. `capturesSystemKeys` only decides whether system shortcuts go to the guest.

macOS 27 adds custom Virtio devices for Linux guests (`VZCustomVirtioDevice` and the queue classes in
`virtualization/custom-drivers`). In principle an app could implement a virtio-input device and inject events itself, which
would replace the framework's USB HID model for Linux. That is a large design (the app would capture and translate events
instead of the framework's view, and the guest needs the virtio-input driver, which stock kernels have) and it is **not
justified until a measurement shows the USB model is the dominant stage**. Listed, not started.

### Process, thread and power state

- No activity assertion existed (`grep` for `beginActivity` found nothing). `Resources/Info.plist` has no
  `NSAppSleepDisabled` or related key. The main thread runs at the default user-interactive quality of service.
- The virtual machine does not run in the app's process: Virtualization.framework hosts it in a helper process. An activity
  held by the app therefore keeps *the app* from being throttled; whether the framework's process shares that treatment is
  **not known** and is a reason the assertion's effect has to be measured, not assumed.
- Mouse-moved events are coalesced by AppKit by default (`NSEvent.isMouseCoalescingEnabled`), which lowers the event rate when
  the app is busy but does not delay an event. Not touched.

### Build and signing

- `vmr build-app` compiles with `swift build -c release` by default (`Sources/DevTools/App/AppBundler.swift:48`, the default
  configuration is `.release`, `:12`) and signs ad hoc with the hardened runtime (`:37`). `Package.swift` has no
  `unsafeFlags`, no sanitizer and no `-Onone` setting; its flags (`treatAllWarnings(as: .error)`, strict memory safety, upcoming
  features) do not change code generation. A release build is therefore optimised, and sanitizers exist only in the
  `.build-asan` family that `vmr check --full` makes. `build-app` refuses `get-task-allow` in a release build.
- The owner can confirm they run a release bundle: `codesign -d --entitlements - build/VMRunner.app` shows no `get-task-allow`
  (a debug build carries it).
- `swift run vmr build-app release --hardened` adds the Enhanced Security entitlements (`hardened-process`, `hardened-heap`,
  `dyld-ro`, platform restrictions; `Resources/VMRunner.hardened.entitlements`). The hardened heap changes the allocator, which can
  make allocation-heavy paths slower. Whether the owner runs this profile is **unknown**; it is a variable in the protocol.

## Hypotheses, ranked

Ranking is by how well the evidence fits a *clear* delay (tens of milliseconds) in a release build, then by how cheap the test is.
"Fixed here" means a change shipped with this study that removes a possible cause; none is shown to reduce a measured number yet.

| # | Hypothesis | For | Against | Status |
|---|---|---|---|---|
| 1 | **The stages the app does not own**: the framework's delivery across a process boundary, the virtual USB device model (Linux, and macOS with "Mouse"), the guest's own scheduling, the cursor the guest draws, and the frame path | the app's own path is a direct view on the main thread with nothing else on it (above); the API offers no other device; an absolute pointer is drawn by the guest, so the cursor lags by at least a guest frame even if events were instant | no measurement; the macOS paravirtual devices are expected to be better and "Trackpad" vs "Mouse" tests exactly that | **Most likely; not ours to fix.** Measure with the protocol |
| 2 | **Main-thread work during input** | one real flood path existed: filtered networking published one main-actor job and several observed changes per flow event | nothing else found that runs per input; in NAT mode there is no such stream; SwiftUI re-evaluation is state-driven and no state changes per input | **Fixed here** for the flood path (batching, 200 ms or 1024 events). The monitor reports any remaining stall with the work inside it |
| 3 | **App Nap and timer coalescing** | no activity assertion existed; Foundation's header says an activity makes the system "disable some or all" of its battery heuristics for responsiveness | the header also says an activity is not needed for work done synchronously inside an event callback on the main thread, which is what input handling is; a visible, frontmost app being typed into is normally exempt; the input path uses no timers; user preferences may override an activity; the machine runs in another process the assertion may not cover; the header reserves latency-critical for audio and video recording | **Assertion added** (setting, default on). Effect unmeasured; A/B with the setting |
| 4 | **The view, the container and the window chrome** | translucent toolbar and sidebar over the guest view (macOS 26) could cost compositing time | no overlay while running; no extra event layer; autoresizing container | **Open.** A/B windowed vs full screen with the toolbar hidden. The display code belongs to another change |
| 5 | **Frame pacing** (refresh rate, ProMotion, the scanout path, the guest's sync) | the roadmap lists it; a 60 Hz frame alone is 16.7 ms | nothing in the app controls it | **Not ours.** Record the refresh rate; A/B 60 Hz vs 120 Hz |
| 6 | **Power state** (battery, Low Power Mode, thermal) | macOS lowers clocks and coalesces more on battery and in Low Power Mode | none | New. Record it; A/B on AC |
| 7 | **The hardened profile** (`--hardened`) | changes the heap allocator | only matters for allocation-heavy main-thread work, which the audit did not find | New. Record which profile; A/B once |
| 8 | **Debug build** | it was the first suspect | the owner runs the bundled release; `build-app` builds `-c release` with no unsafe flags | **Demoted:** excluded unless `get-task-allow` shows up in the bundle |
| 9 | **Sanitizer or debug-info builds** | none | sanitizer builds live in `.build-asan` etc. and never reach `build-app` | **Excluded** the same way |
| 10 | **Start-up blocking** (`ConfigurationBuilder.build` and the ephemeral clone on the main actor) | real, synchronous, on the main actor | not input, only start | Listed as a follow-up; unrelated to the reported delay |

## What was changed, and what was not

1. **`--input-latency`** (below) measures the app's stage and attributes stalls. Off by default; off, nothing is installed.
2. **"Keep input responsive while a machine runs"** (Settings, default on) holds
   `[.userInitiatedAllowingIdleSystemSleep, .latencyCritical]` while at least one machine runs. The roadmap named
   `.userInitiated`, but in Foundation that value includes `idleSystemSleepDisabled` (it stops the Mac sleeping when idle), a side
   effect nobody asked for; `.userInitiatedAllowingIdleSystemSleep` is the same minus that. It is an app setting rather than a field
   of the machine: App Nap belongs to the process and the activity is shared by every running machine. Cost: more wake-ups and
   less deep rest while a machine runs, so more battery use on a laptop; the help topic says so.
3. **Flow events reach the main actor in batches** (200 ms or 1024 events, only the newest 200 are formatted).

Not done, because each needs a measurement: setting `VZVirtualMachineView` properties only when they change; any change to the
container or the window chrome; `NSEvent.isMouseCoalescingEnabled`; a custom virtio input device; moving `ConfigurationBuilder.build`
off the main actor.

## The instrumentation

Turn it on with `--input-latency` or `VMR_INPUT_LATENCY=1`. Other settings: `--input-latency-threshold-ms N` (default 1),
`--input-latency-interval N` seconds (default 10), `--input-latency-file /absolute/path` (also `~/`). Environment equivalents:
`VMR_INPUT_LATENCY_THRESHOLD_MS`, `VMR_INPUT_LATENCY_INTERVAL`, `VMR_INPUT_LATENCY_FILE`. An argument beats the environment. A bad value
is ignored with a warning in the log.

It only observes. A local event monitor sees key, pointer, scroll and gesture events of windows that hold a machine's view and returns each
unchanged; three run-loop observers (after waking, before sources, before sleeping) time the main thread; `InputPath` marks the pieces of
main-thread work that the app knows about (today `config write` and `flow log batch`).

### What the numbers mean

A summary line looks like this (one line in the log, in the file, and once more when the app quits as `total`):

```
input latency [last 10.0 seconds, over 1.000ms]: key n=42 p50=0.110ms p90=0.180ms p99=0.350ms max=0.400ms over=0;
pointer n=1203 p50=0.090ms ... over=2; scroll n=0; main busy n=5120 p50=0.020ms p90=0.080ms p99=0.400ms max=3.100ms over=4
| worst: 3.100ms (wake 0.050ms, 3 passes, flow log batch 2.900ms)
```

- **`key`, `pointer`, `scroll`: event age.** The time between the event's own timestamp (when the hardware event was
  generated, in seconds since boot) and the moment the app's event monitor sees it, just before AppKit dispatches it. It includes the
  window server's delivery and any time the event waited behind main-thread work. It stops *before* the view handles the event, so it
  excludes everything after: the view, the framework, the guest. Percentiles are exact to about 12 % (logarithmic buckets, eight per
  doubling); `max` and `over=` (strictly above the threshold) are exact.
- **`main busy`: how long the main thread stays awake.** From the run loop waking to it going back to sleep, with the first observer
  to run when it wakes and the last one before it sleeps, so AppKit's and Core Animation's own layout, display and commit count as
  busy. The run loop may go round several times without sleeping; `passes` counts them and `wake` is the part before the first look at
  sources (timers, wake-up messages, queued main-actor jobs). Events are dispatched *between* two runs of the loop, which is why
  only sleeping counts as idle.
- **`worst:`** the three longest busy stretches of the window, with the instrumented work inside each. Nested work overlaps, so shares can add
  up to more than the stretch; what they do not cover is work that nobody has instrumented, and Time Profiler shows it.

How to read them together:

| Pattern | Meaning |
|---|---|
| event age p99 below 0.2 ms, `main busy` max below 1 ms | the app's stage is within the target; the delay is in a stage the app does not own |
| event age high at the same time as a long busy stretch | main-thread work delayed the event; read `worst:` |
| event age high, `main busy` low | the thread was free but the event arrived late: window server, scheduling, App Nap, a loaded CPU; compare with the setting off and on, and watch Instruments' thread states |
| `main busy` over the threshold with an empty work list | uninstrumented work; take a Time Profiler trace of that moment |

Signposts: subsystem of `Log.swift` (the bundle identifier), category `input`, **and the same events again under the Points of
Interest category** (Instruments' Points of Interest instrument only shows that one). Intervals: `main busy` (every busy stretch),
`config write`, `flow log batch`. Events: `input event` with the kind and the age in microseconds, and `main stall` with the duration.

## Owner measurement protocol

Agents do not run any of this. Everything is a command or a click; nothing needs a code change.

### 0. Prepare

1. `git rev-parse --short HEAD` and note it. `swift run vmr build-app` (a release build, ad-hoc signed, verified). Confirm it is
   release: `codesign -d --entitlements - build/VMRunner.app` must **not** list `get-task-allow`.
2. Quit the app. Close other heavy apps. Note the host's macOS version, chip, **display refresh rate** (System Settings, Displays),
   and **power mode** (AC or battery; Low Power Mode on or off; High Power mode if offered).
3. Start the app with the monitor and a file per run:

   ```sh
   open -n build/VMRunner.app --args --input-latency --input-latency-file ~/Desktop/latency-RUNNAME.txt
   ```

   (Add `--start "Machine name"` to boot a machine at launch.) Without `open`: run `build/VMRunner.app/Contents/MacOS/VMRunner
   --input-latency ...` from Terminal. Watch the log live: `log stream --level info --predicate 'category == "input"'`.
4. In the window: use the default "Keep input responsive while a machine runs" (on) for the first runs. Windowed, the guest
   display at its default size.

### 1. Runs

Each run is one row; run them in this order, each in a fresh app launch, 60 s of activity after the guest has been idle for a minute:

| Run | Guest | Pointing device | Network | Notes |
|---|---|---|---|---|
| A1 | macOS | Trackpad | NAT | baseline |
| A2 | macOS | Mouse | NAT | USB pointer on a macOS guest |
| A3 | macOS | Trackpad | Filtered, idle | |
| A4 | macOS | Trackpad | Filtered, busy | guest loop below |
| B1 | Linux | (USB, fixed) | NAT | baseline |
| B2 | Linux | (USB, fixed) | Filtered, idle | |
| B3 | Linux | (USB, fixed) | Filtered, busy | guest loop below |

A busy guest network: in a macOS guest `while true; do dscacheutil -q host -a name example.com >/dev/null; done`; in a Linux
guest `while true; do getent hosts example.com >/dev/null; done`. Check the Network popover shows a growing count. (Do not run it
with the popover open in A4/B3 unless you want to see the popover's own cost.)

Then the **A/B runs** on A1 and B1 only, changing one thing each and repeating the 60 s activity:
Settings, "Keep input responsive" **off**; window vs **full screen** (View, Enter Full Screen: no toolbar, no sidebar); refresh rate
60 Hz vs the display's highest; on AC vs on battery; "Capture system keyboard shortcuts" on vs off; `build-app release --hardened`
vs the default.

### 2. What to do in the guest during the 60 s

Same sequence every time: (1) 20 s of steady typing of a sentence at a normal pace in a text editor; (2) 20 s of slow, then fast,
circles with the mouse or trackpad over a plain background; (3) 10 s with one key held down (auto-repeat); (4) 10 s of scrolling.
Do not touch anything else on the Mac. Quit with Cmd-Q at the end (a one-line `total` goes to the log and the file).

### 3. Instruments (once per guest type, on A1 and B1)

1. Xcode, Open Developer Tool, Instruments. Template **System Trace**; add **Points of Interest** and **Time Profiler**
   (Library, drag in).
2. Choose the target **All Processes**, not "VMRunner.app": a hardened-runtime release build without `get-task-allow` cannot be
   attached to or launched by Instruments, and signposts are system-wide anyway. Instruments asks for an administrator password.
3. Press record, run the 60 s activity in the guest (the app launched with `--input-latency` as above), stop.
4. In the trace: filter the process to VMRunner. In **Points of Interest** read the `main busy` intervals and the `main stall` events
   (select one and note its duration); `input event` events carry the age. In **System Trace** select the Main Thread of VMRunner and
   look at the thread-state graph around a stall: *Running* is app work (Time Profiler shows the stack), *Runnable* is scheduling
   delay (CPU contention), *Blocked* is waiting (a lock, IO). Save the trace.
5. Time Profiler: select the time range of the three longest `main busy` intervals and read the heaviest stack; report the
   top five frames.

### 4. A guest-side timestamp, compared with the host's

What is comparable: the **host** time of an event is the event's own timestamp; the **guest** time is when the guest's input stack
reports it. The two clocks are different clocks, and that decides what can be claimed.

- **Host event time.** Each `input event` signpost carries the event's age at the app. With signposts in the log
  (`log stream --signpost --level info --predicate 'category == "input"'`, or `log show --signpost --info --last 5m ...`), the host
  wall-clock time of the hardware event is *(log timestamp) minus (age)*. That is a host wall clock, in microseconds.
- **Linux guest.** `sudo evtest` (pick the keyboard and the pointer devices in the menu) prints every event with the guest's
  `CLOCK_REALTIME` time, `Event: time 1729550000.123456, type 4 ...`. `sudo libinput debug-events --show-keycodes` prints the
  device-reported time since it started, which is not wall-clock; use `evtest` for comparison and `libinput` to see
  what the compositor's input stack gets. `evtest` shows when the guest *kernel* received the event, which is before any guest
  compositor or application, so it isolates the framework and the virtual device from the rest of the guest.
- **macOS guest.** There is no `evtest`. Compile this in the guest (`swiftc tap.swift -o tap`) and run `./tap` in Terminal, granting
  it Input Monitoring in the guest's System Settings. It prints the guest wall-clock time at which each key or pointer event reaches
  the session event tap:

  ```swift
  import CoreGraphics
  import Foundation

  let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.mouseMoved.rawValue)
  let callback: CGEventTapCallBack = { _, type, event, _ in
      let now = Date().timeIntervalSince1970
      let line = String(format: "%.6f %@ %lld\n", now, type == .keyDown ? "key" : "move", event.getIntegerValueField(.keyboardEventKeycode))
      FileHandle.standardOutput.write(Data(line.utf8))
      return Unmanaged.passUnretained(event)
  }
  guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: mask, callback: callback, userInfo: nil)
  else { FileHandle.standardError.write(Data("no event tap\n".utf8)); exit(1) }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)
  CFRunLoopRun()
  ```

  This is later than the kernel-level reading `evtest` gives: it includes the guest's HID stack and the tap's own scheduling.
  Say so when reporting; do not compare the two guest types' absolute numbers with each other.
- **Relating the clocks.** Guest and host wall clocks differ by an unknown offset (both may be set from the network, which is
  good to a few milliseconds, not to microseconds). Measure the offset with repeated round trips between the host and the guest over
  the NAT address (a small UDP echo that returns the guest's time): for each exchange, offset = guest time minus the midpoint of the host
  send and receive times; keep the exchange with the **smallest round trip**; its uncertainty is half that round trip (expect a few
  hundred microseconds on the virtual network, **not verified**). Repeat before and after the run to see drift.
- **What is and is not comparable.**
  - *Not comparable to better than the offset uncertainty:* the absolute one-way latency, *(guest time) minus offset minus (host event
    time)*. Report it with its uncertainty, not as a bare number.
  - *Comparable without any offset:* the **spread** of that difference (p99 minus p50, the jitter); the **gaps between consecutive events**
    on each side (a held key repeats at a fixed host cadence; a USB model that polls shows guest gaps that cluster at multiples of its
    polling interval); and whether any events arrive in a burst (two events with almost the same guest time that were far apart on the host).
  - *Never comparable:* the guest's `CLOCK_MONOTONIC` with anything on the host.
- **Beyond the guest kernel:** the time until the pixel changes cannot be read by software at all. A phone camera at 240 frames per second
  filming the keyboard (or a key-press LED) and the screen together, counting frames between the key and the first changed pixel, gives the
  whole chain to about 4 ms. Optional, and the only way to see the display's share.

### 5. Report back

For each run (A1 to B3 and each A/B):

1. **Context:** commit hash; release or debug; default or `--hardened`; host macOS version and chip; guest OS and version; pointing
   device; network mode (and busy or idle); display refresh rate; power mode (AC, battery, Low Power Mode); the "Keep input
   responsive" setting; windowed or full screen; guest display size and scale; machine CPUs and memory.
2. **Host, from the summary file:** for each of `key`, `pointer`, `scroll` the `n`, p50, p90, p99, max and `over=`; for `main busy` the
   same and the `worst:` lines with their attribution; the final `total` line.
3. **Instruments (A1, B1):** the longest `main busy` interval, the three heaviest Time Profiler frames inside it, and whether the Main
   Thread was Running, Runnable or Blocked there.
4. **Guest, from `evtest` (Linux) or `tap` (macOS):** the number of events matched; the offset you measured and its uncertainty; the
   distribution of the offset-corrected difference (p50, p90, p99, max) and the jitter (p99 minus p50); the histogram of gaps between
   consecutive events for the held key.
5. **Per stage, the number you would put in the roadmap's table:** app (event age and main-thread stall), framework and virtual device
   (guest kernel time minus host time, with its uncertainty), guest (macOS `tap` time minus Linux-style kernel time is not available:
   report what you have), display (camera, if done).
6. Whether the delay is *visible* in each run, in your words, and which activity shows it most (typing, circles, held key, scrolling).

### Reading the answers

- App stage within target and the guest-kernel difference large and clustered at a fixed interval: the **virtual device model** (USB polling
  or the framework's delivery). The only available moves are the pointer choice on macOS, and, after a decision, a custom virtio input
  device for Linux (macOS 27 API; a design of its own).
- App stage within target, guest-kernel difference small, but the delay visible: the **guest** or the **display** (cursor drawn by the guest,
  compositor, refresh). Not this app.
- Event age or busy stretches over the threshold only in filtered-busy runs: the flow path; compare with the 200 ms batching and
  open an issue with the `worst:` lines.
- Event age over the threshold with the thread idle: system scheduling or throttling; compare the setting off and on, battery and AC, Low
  Power Mode.

## What was not verified

- Nothing ran: no application, no virtual machine, and so no AppKit hook (the event monitor, the run-loop observers, the
  signposts, the activity) has executed. They compile and the pure parts are unit tested; their behaviour is read from documentation.
  In particular that `log stream --signpost` shows the events, that Instruments lists them under Points of Interest, and that Instruments
  records all processes of a hardened-runtime build without extra steps, are expectations.
- That batching moves the work off the main thread is read from the library source (the chunking sequence aggregates in its own
  `next()`, which is not main-actor isolated) and tested only for results, not for which thread ran.
- That an activity held by the app also reaches the framework's virtual machine process is unknown.
- That the translucent chrome costs anything, that the pointer lag is the guest's cursor, and that USB polling adds milliseconds are
  hypotheses.
- The offset uncertainty of a few hundred microseconds is an expectation.
