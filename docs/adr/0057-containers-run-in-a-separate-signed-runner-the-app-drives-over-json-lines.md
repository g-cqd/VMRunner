---
status: accepted
date: 2026-10-25
---
# 0057 — Containers run in a separate signed runner that the app drives over JSON lines, and the app does not link the container package

This ADR amends [ADR-0017](0017-containers-use-apples-containerization-package.md), whose decision 1 adds the container
package to the app as an exact-pinned dependency. The rest of ADR-0017 stands: one lightweight virtual machine per container,
the `Workload` abstraction with capability flags, no macOS container, no code from a project whose licence forbids competing
use. It keeps [ADR-0001](0001-the-app-links-system-frameworks-only-and-tooling-pins-its-packages.md) as it is: the app still
links system frameworks and one package.

## Context

The first run (2026-10-22) showed the container package working under the virtualization entitlement alone, from a small
executable of its own, `ContainerRunner`, which lives in `Packages/Containers` with its own `Package.resolved`. The package
brings 28 other packages with it, 29 pins in all (a networking stack, an RPC stack, an HTTP client, TLS and crypto libraries,
a compression library, logging and tracing). Their licences have not been inventoried. Linking the package would put all 29
into the app's graph, into the process that holds the user's machines, and would change ADR-0001's description of the app from
two packages to about thirty. The app can run a container without that: the runner is already an executable, the work it does is
one run with a beginning and an end, and everything the app needs from it is a command line in and a stream of events out.

## Decision

1. **Containers ship now as a separate executable.** `vmr build-app` builds `ContainerRunner` from `Packages/Containers`, copies
   it to `VMRunner.app/Contents/Helpers/ContainerRunner` and signs it ad hoc with the hardened runtime and
   `Resources/ContainerRunner.entitlements` before it signs the app, so the app's signature seals it. The runner's entitlements
   are `com.apple.security.virtualization` and nothing else; the entitlement policy of `vmr` judges that file separately from the
   app's, before anything is built, and reads the signature back.
2. **The app drives it as a child process, never in process.** One runner per running container machine. The command line is the
   machine's scratch folder (in the machine's bundle, private), `--json`, and the image, the processor count, the memory, the
   network (`none` or `loopback`), one `--env NAME=value` per environment entry and one `--command` per command element; there
   is no shell. The runner answers with one JSON object per line on standard output: `phase`, `output` (a chunk of the
   container's output, at most 16384 bytes), `exited`, `error` and a last `finished` line; diagnostics go to standard error
   (by reading the code; not run against a guest).
   The runner inherits only the search path, the home folder and the temporary folder.
3. **A stop is a line, not a signal.** The app writes `stop` to the runner's standard input and closes it; the runner stops the
   container and exits with status 75 if its command had not ended. Closing standard input does the same, so a runner whose app
   died ends too. A runner that is still alive 10 seconds after the request gets SIGTERM, and SIGKILL 5 seconds later; when the
   app quits it stops every runner first and kills what remains (the status logic is tested; stopping a live container has not
   been run).
4. **The container's output is untrusted.** It passes through the console filter before the app shows it, and the app keeps at
   most 1 MiB of it, dropping the oldest and saying how much.
5. **The app does not link the container package or any of its pins.** The root `Package.swift` and `Package.resolved` do not
   name them (a test checks that). Linking the library into the app is deferred until two things have been done: an inventory of
   the licence of every pin (`docs/research/containers-2026-10.md`, "Licences to inventory before the app links the library"),
   and an access review of the kind ADR-0047 made for the network targets, of which parts of the library the app would call and
   what each part brings in. Either can end in a decision not to link.

## Consequences

What it costs, measured on 2026-10-25 unless said otherwise:

- **Size.** The debug runner is about 79 MB (79,120,864 bytes as bundled) and sits in the bundle next to the app. The release
  runner's size was not measured.
- **Build time.** `vmr build-app` builds the nested package first, from its pinned versions only. A debug `build-app` took about
  210 s, about 190 s of it for the package, with part of the package's scratch directory already built; the cold release build
  of the study took 695 s, the tool included. The scratch directory is shared with `vmr check build`.
- **A process that is not sandboxed.** The runner is an extra process that holds the virtualization entitlement, pulls an image
  from its registry over the network and downloads its kernel over HTTPS (against a pinned checksum). The image and what it
  prints are untrusted. The app's network policy does not reach it: `none` and `loopback` are the only networks, and the
  filtered network and the shared folders of a virtual machine do not apply. ADR-0016's helper-per-workload isolation is not
  applied to it yet; the runner has not been run under App Sandbox or a Seatbelt profile.
- **A cache per machine.** The runner's scratch folder holds the downloaded kernel and the image store, and it is the machine's
  own, so each container machine downloads its kernel once and keeps its images (532 MB after the study's first run, the 290 MB
  kernel archive included). Nothing in the app clears it while the machine exists.
- **A narrower interface.** The app sees a run, not the library: no exec into a running container, no copy in or out, no
  statistics, no per-container mounts. Each of those needs a new runner option and event, or the link this ADR defers.

The pinned package stays what ADR-0017 says: exact version 0.52.1, three library products, and the runner alone links it.

## What this does not decide

Whether the app links the library at all; running the runner under a sandbox helper; networking beyond `none` and `loopback`
(the user-mode stack in a container is ADR-0017's open point, not closed here); an image cache shared between machines and the
tools to clear it; a macOS container.

(Update 2026-10-25, after the first run from the app: a debug build of the app, started with a scratch data folder and driven
only through the control service, started two container machines of the Alpine image. Seen: a start reaches `running` (cold
about 63 s, the download of the runner's kernel archive, about 290 MB for each machine, and of the image included; warm 3 to
9 s); a container whose command ended is stopped by itself; a stopped container leaves no runner and no virtual machine
process; a forced stop answers in 0.44 s and the runner is gone at 0.60 s; ending the app with SIGTERM while a container ran
left no runner. Not seen: the container's output in the app's window (an app that was never activated shows no window to
automation), and the quit through the menu (the app stayed up behind a confirmation that could not be read). A stop that asks,
decision 3, took 72 s to reach `stopped`, where the decision gives 15 s at most; the cause is not known. The best-supported
candidate, unproven, is that macOS slows an app it thinks idle (no window shown, never active: App Nap) and so coalesces the
timers that carry the escalation. A running container therefore holds a user-initiated activity from the start of its runner
to its end, not latency-critical, so that the Mac still sleeps when idle; and the stop path logs each step with the runner's
process identifier (category `container`), so that the next run can show where the time went. The output of each run is now
also kept in `container-output.log` in the machine's folder, the most recent 1 MiB and one previous file, and a token with the
log capability can read its last 64 KiB through the control service (ADR-0056). None of this has been run on a real guest yet.)
