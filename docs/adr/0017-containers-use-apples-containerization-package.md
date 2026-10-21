---
status: proposed
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

The first step is a small container runner that pulls and runs an arm64 Alpine image. It is written and waits for its first
run by the owner; until the result is in, the package is pinned at 0.52.1 for the runner only and the app does not link it. See
`docs/research/containers-2026-10.md` and roadmap 0024.

## What this does not decide

Whether containers can use the user-mode network stack through a custom interface; the first run must confirm it.
