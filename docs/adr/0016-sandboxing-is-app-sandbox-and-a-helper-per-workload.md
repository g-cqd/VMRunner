---
status: proposed
date: 2026-10-21
---
# 0016 — Sandboxing offers App Sandbox and Seatbelt as two engines, one per workload helper

## Context

The owner wants both App Sandbox (driven by entitlements) and `sandbox-exec` Seatbelt profiles, usable for virtual
machines and containers, for the whole app or per workload, as a second primitive for stronger isolation.

On macOS 26.7.1 the two cannot be stacked on one process: an App Sandbox app launched under `sandbox-exec` aborts, and
`sandbox-exec` run from inside an App Sandbox app fails with `sandbox_apply: Operation not permitted`. A plain executable
under `sandbox-exec` works. Seatbelt is deprecated and undocumented for third parties but works. Virtualization.framework
already isolates each VM in its own sandboxed service.

## Decision

1. Both primitives are offered, as two **exclusive engines** (`appSandbox`, `seatbelt`) plus `none`, chosen per workload
   with an app-wide default.
2. The main app stays **unsandboxed** so that it can launch helpers of either kind. It is therefore not a Mac App Store
   build.
3. Per-workload isolation is one helper process per headless workload, signed with the entitlements its engine and level
   need. Graphical machines stay in the app, because a machine's view cannot be exported to another process with public API.
4. Depth comes from independent layers, shown to the user per workload: the hypervisor, Apple's per-VM sandboxed service,
   the chosen engine, and the network policy. No layer, and no combination, is described as guaranteeing full isolation.
5. Seatbelt profiles are generated from the workload's settings for the standard and strict levels; user-written profiles are
   `custom`, labelled advanced and unsupported.

## Consequences

Nothing is built. The first step is a prototype helper for one Linux workload, signed with the virtualization entitlement
only, then wrapped in each engine in turn. See `docs/sandboxing.md`.

## What this does not decide

Whether a virtual machine can run inside a Seatbelt-wrapped helper (which Mach services the profile must allow), and whether
the user-mode network stack works unchanged under App Sandbox; the prototype checks both.
