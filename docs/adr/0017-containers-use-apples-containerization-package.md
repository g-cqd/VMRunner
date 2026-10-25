---
status: accepted
date: 2026-10-21
---
# 0017 — Containers use Apple's containerization package

## Context

The owner wants OCI images from various sources to run in the app, containers and virtual machines to offer the same
features, and, ideally, macOS containers.

## Decision

1. Linux containers run on Apple's containerization package (one lightweight virtual machine per container), added as an
   exact-pinned dependency of the app, using only its image, ext4 and OCI libraries. The command line is driven only for
   Dockerfile builds.
2. Containers and virtual machines share a `Workload` abstraction; what a kind lacks is a capability flag, not a stub.
3. There is no macOS container. The nearest honest thing is a macOS VM cloned from an image pulled as an OCI artifact and
   restored from a saved state, within the two-VM limit and the macOS licence.
4. No code from a project whose licence forbids competing use is copied or linked.

## Consequences

The first step, a small container runner that pulls and runs an arm64 Alpine image, ran on 2026-10-22: a container started
with only the virtualization entitlement under an ad-hoc signature, `uname -a` printed `aarch64` and the exit status came
back, with the exact-pinned package at 0.52.1 and the Kata 3.17.0 kernel (Linux 6.12.28). The package stays pinned for the
runner only and the app does not link it yet. See `docs/research/containers-2026-10.md` and roadmap 0024.

## What this does not decide

Whether containers can use the real user-mode network stack: a custom interface on a file-handle attachment delivers the
guest's frames and the guest accepts the static address (shown on a socketpair), but the stack itself lives in the app target
and was not plugged in. Also open: the newer kernel the package's examples use, the licences of the packages the library brings
in, and how the app links the library without growing the root dependency graph.

(Update 2026-10-25: decision 1 is amended by [ADR-0057](0057-containers-run-in-a-separate-signed-runner-the-app-drives-over-json-lines.md).
Containers ship now as a separate signed runner inside the app bundle, driven over JSON lines, and the app does not link the
package until the licences of its pins are inventoried and the access is reviewed.)
