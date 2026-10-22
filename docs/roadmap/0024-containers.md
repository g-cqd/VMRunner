---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0017
---
# 0024 — Run OCI images with Apple's container primitives, and what a macOS container can mean

Study: `docs/research/containers-2026-10.md`. Decision: ADR-0017.

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

## Next

1. Extract the user-mode stack into its own module and run the container through it (the study's list of five points).
2. Link the container library from the app.
3. Follow-ups from the run: the kernel download should not leave `~/Library/Caches/ContainerRunner` behind (use a session
   without a cache); try the newer Kata kernel (3.26.0) before moving the pin; inventory the licences of the packages the
   library brings in before the app links any of them.
