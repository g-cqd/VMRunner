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

The container runner (`ContainerRunner`, built and signed by `vmr container-sign`) is written and tested without a guest;
the runner section of the study lists what was and was not verified. The dependency is pinned at 0.52.1, the first release
that fixes the digest advisory, and only the runner links it, from a package of its own (`Packages/Containers`) so that the
root graph stays small. The runner's second check ran against a socketpair, not the app's user-mode stack: the study says
what a module split would take.

## Blocked on

The owner's first run of the container runner, once, from the instructions in the study. It cannot be a `blocked-by`
entry, which names roadmap entries only. The result decides whether ADR-0017 stands, and the next steps follow from it:
extract the user-mode stack into its own module, then link the container library from the app.
