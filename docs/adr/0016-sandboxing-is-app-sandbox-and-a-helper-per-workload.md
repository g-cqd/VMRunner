---
status: accepted
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

A headless helper was built and booted for real on 2026-10-22 (the study's "Boot run results"): an Alpine aarch64 guest
started and reached its login prompt under no sandbox, under a generated Seatbelt profile and under App Sandbox, at both
levels, with the NAT attachment and with a file-handle NIC, and a NAT guest obtained a DHCP lease under all three. The
generated profile needed one kernel value beyond what the dry run found (`hw.pagesize_compat`); App Sandbox needed
nothing beyond its entitlements.

## Decision

1. Both primitives are offered, as two **exclusive engines** (`appSandbox`, `seatbelt`) plus `none`, chosen per workload
   with an app-wide default. The three are renderings of one set of grants (files to read, files to write, host sockets
   or not), derived once from the workload; a boot confirmed that both engines carry the same configurations.
2. The main app stays **unsandboxed** so that it can launch helpers of either kind. It is therefore not a Mac App Store
   build.
3. Per-workload isolation is one helper process per headless workload, signed with the entitlements its engine and level
   need. Graphical machines stay in the app, because a machine's view cannot be exported to another process with public API.
4. Depth comes from independent layers, shown to the user per workload: the hypervisor, Apple's per-VM sandboxed service,
   the chosen engine, and the network policy. No layer, and no combination, is described as guaranteeing full isolation.
5. The levels are `standard` and `strict`, and they differ in one thing only: whether the helper may open host sockets
   and resolve names (the user-mode stack's needs). `strict` leaves every outbound socket and the resolver refused, and a
   guest whose network arrives as a descriptor, or is provided by the framework's own service (NAT), boots at either level.
   A level promises "no host sockets", not identical behaviour across engines (App Sandbox still reads `/etc/hosts`; the
   generated profile does not).
6. Seatbelt profiles are generated from the workload's settings for the standard and strict levels; user-written profiles are
   `custom`, labelled advanced and unsupported.

## Consequences

The helper, its probes and the generator exist (`VMHelper`, `VMHelperCore`, `vmr sandbox`). The profile generator lists only
rules that a log line justified; a new rule needs the line and a test. A regression test that boots a workload at each level
must read the helper's events and its console, not the sandbox log, which undercounts. See
`docs/research/sandboxing-2026-10.md` and roadmap 0025.

## What this does not decide

Whether the user-mode network stack works unchanged when a helper hosts it: the helper's connect, send and resolve probes
pass under both engines at the standard level and `bind` is refused by both, but the stack lives in the app and was not
run in a helper. How an App Sandbox helper gets its files (per-workload signing with path exceptions works and is what
`vmr sandbox` uses; a bookmark or disks cloned into the helper's container were not tried). The `custom` level, which was
not exercised. Whether an ad-hoc re-signed helper bundle can be launched by a notarized app.
