---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0017
---
# 0024 — Run OCI images with Apple's container primitives, and what a macOS container can mean

Study: `docs/research/containers-2026-10.md`. Decision: ADR-0017, amended by ADR-0057.

## Done when

An arm64 Alpine image is pulled from a registry and run from the app, `uname -a` prints `aarch64`, and the exit status
returns to the app. Then: container networking through the user-mode stack, and an OCI image store for macOS VMs.

## Progress

The container runner (`ContainerRunner`, built and signed by `vmr container-sign`) is written, tested and has had its first
run (2026-10-22, results in the study's "First run results"). It pulls an arm64 Alpine image, boots its container and prints
`uname -a` with `aarch64` and an exit status of 0, on the first try: only the virtualization entitlement under an ad-hoc
signature, the pinned Kata kernel (Linux 6.12.28) with the init image 0.52.1, 13.2 to 13.5 s for the init image, about 3 s for
the pull, 0.27 to 0.29 s to boot and 0.05 s to run `uname -a`, cold, in a release build. The kernel download takes about 53 s once.
The second check (`--network loopback`) shows a file-handle interface delivering the guest's frames to the host and the guest
accepting its static address. The dependency is pinned at 0.52.1, the first release that fixes the digest advisory, and only
the runner links it, from a package of its own (`Packages/Containers`) so that the root graph stays small. The second check
ran against a socketpair, not the app's user-mode stack: the study says what a module split would take.

## Delivered since: the container as a machine of the app (2026-10-25), decided by ADR-0057

The app does not link the container library. It runs the runner as a separate signed process and drives it (ADR-0057).

- **The runner takes a job.** `--image`, `--command` (repeated, one argument each, no shell), `--cpus` (1 to 16), `--memory`
  (128 to 16384 MiB), `--env` (repeated `NAME=value`) and `--network none|loopback`, each checked with a clear refusal. With
  `--json` it writes one event per line on standard output (`phase`, `output`, `exited`, `error`, `finished`) and reads standard
  input: a line `stop`, or the end of the input, stops the container and the runner exits with status 75. Without the new
  flags it behaves as before.
- **The tooling.** `vmr container-run --boot` signs the runner and runs it on an image and a command (owner-authorised: it boots a
  virtual machine). `vmr build-app` builds the runner from `Packages/Containers` in the app's configuration and embeds it at
  `VMRunner.app/Contents/Helpers/ContainerRunner`, ad hoc signed with the hardened runtime and the virtualization entitlement
  only, before the app itself is signed; the entitlement policy judges the runner's file on its own.
- **The configuration.** A machine has a workload, a virtual machine or a container. A container machine stores its image,
  command, environment, processor count, memory and network (`none` or `loopback`), within the limits the runner enforces, and
  needs no disk. A configuration without these keys is a virtual machine.
- **Starting and stopping.** The controller starts a machine through a workload seam; a container machine's workload runs the
  bundled runner as a child process, with its working folder in the machine's bundle. The window shows the container's output
  (filtered as untrusted, bounded to 1 MiB with a note of what was dropped), the phase timings and how the run ended. Stop writes
  the stop line, with SIGTERM after 10 s and SIGKILL 5 s later; quitting the app stops every runner and kills what remains. A
  build without the runner (`swift run VMRunner`) refuses to start a container machine, with a clear message.
- **The New Machine sheet, the editor and the control service.** The New Machine sheet offers a container (image, command split
  on whitespace with double quotes, `NAME=value` lines, processors, memory, network) and the sidebar badges container machines.
  The editor shows the sections that apply to a container and a Container section, the help has a topic for containers, the
  security view lists a container's exposure (an unsandboxed helper with the virtualization entitlement, an image pulled from its
  registry over the network, untrusted, the app's network policy and shared folders not applying), and the managed preference
  `AllowContainers` governs whether containers may be used. The control service reports a machine's `workload` and starts and
  stops a container machine that has agent access on.

## Left

1. **The real-guest run from the app: done once, with gaps.** A debug build of the app, with a scratch data folder and driven
   through the control service, started two container machines (2026-10-25). Seen: a start reaches `running` (cold about 63 s,
   with a kernel archive of about 290 MB downloaded for each machine; warm 3 to 9 s); a stopped container leaves no runner and no
   virtual machine process; a forced stop took 0.6 s; ending the app with SIGTERM left no runner. Not seen: the container's
   output in the window, and the quit through the menu. The stop that asks took 72 s, not the 15 s at most that ADR-0057 gives.
   Added since, none of it run on a real guest: a running container holds an activity, the stop path logs each step, the output
   is kept in `container-output.log` in the machine's folder, and a token with the log capability can read its last 64 KiB
   (`machines.log`, `vmr control log`, the MCP tool `machines_log`).
2. **The stop timing, run again.** Measure a stop that asks, with the activity and the logs of the app in place, and read the log
   to see which step takes the time. The App Nap candidate (an app that is not active has its timers coalesced) is unproven; if
   the stop is still slow, the logs name the step.
3. **The quit through the menu.** With a container running, the app stayed up and showed a window that could not be read: the
   confirmation about running containers is out of reach of automation when the app was never activated. Whether the runners
   are stopped and killed on that path has not been seen; the quit by SIGTERM has.
4. **The app's descriptors.** The count of the app's open descriptors went from 44 at rest to 54 after a container ran and was
   stopped, and stayed there. The control listener closes every connection it accepts (a test now proves it); the growth of
   the app is not explained and no breakdown was taken.
5. **The placeholder bundle identifier.** The app's bundle identifier is a placeholder shared with an installed copy of the
   app, so both use the same defaults domain and the same data-directory override domain. A decision for the owner.
6. **Networking beyond `none` and `loopback`.** The user-mode stack is now library targets of the root package (ADR-0047), but
   the container's interface is not plugged into it, and the nested package cannot reach those targets yet (the study lists
   what that takes).
7. **Image cache management.** Each container machine's folder keeps its own kernel (a 290 MB archive) and image store; nothing
   clears them or shares them between machines. The kernel download should also not leave `~/Library/Caches/ContainerRunner`
   behind (use a session without a cache).
8. **Linking the library later**, if ever: the licence of each of the 29 pins inventoried (`docs/research/containers-2026-10.md`)
   and an access review of what the app would call (ADR-0057).
9. Older follow-ups: try the newer Kata kernel (3.26.0) before moving the pin; run the runner under a sandbox helper (ADR-0016);
   suspend; a command that needs the network from inside the guest; a pull with credentials.
