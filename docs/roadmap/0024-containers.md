---
status: pending
blocked-by: []
date: 2026-10-21
decision: ADR-0017
---
# 0024 — Run OCI images with Apple's container primitives, and what a macOS container can mean

Study: `docs/research/containers-2026-10.md`. Decision: ADR-0017.

## Done when

An arm64 Alpine image is pulled from a registry and run from the app, `uname -a` prints `aarch64`, and the exit status
returns to the app. Then: container networking through the user-mode stack, and an OCI image store for macOS VMs.
