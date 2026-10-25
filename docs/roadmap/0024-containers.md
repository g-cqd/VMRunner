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

1. **The real-guest run from the app.** The pieces that start a runner are tested with fake runners, the rest by pure tests;
   nothing has started a container from the app yet. The owner-authorised run: build the app, make a container machine, start it,
   read the log, stop it, quit with it running, and look for the runner and for anything outside the machine's bundle afterwards.
2. **Networking beyond `none` and `loopback`.** The user-mode stack is now library targets of the root package (ADR-0047), but
   the container's interface is not plugged into it, and the nested package cannot reach those targets yet (the study lists
   what that takes).
3. **Image cache management.** Each container machine's folder keeps its own kernel (a 290 MB archive) and image store; nothing
   clears them or shares them between machines. The kernel download should also not leave `~/Library/Caches/ContainerRunner`
   behind (use a session without a cache).
4. **Linking the library later**, if ever: the licence of each of the 29 pins inventoried (`docs/research/containers-2026-10.md`)
   and an access review of what the app would call (ADR-0057).
5. Older follow-ups: try the newer Kata kernel (3.26.0) before moving the pin; run the runner under a sandbox helper (ADR-0016);
   suspend; a command that needs the network from inside the guest; a pull with credentials.
