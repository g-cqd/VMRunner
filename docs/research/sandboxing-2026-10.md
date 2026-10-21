---
date: 2026-10-21
question: "How can App Sandbox and Seatbelt isolate VMs and containers, per app or per workload?"
feeds: [roadmap 0025, ADR-0016]
---
# Sandboxing virtual machines, containers and helpers

Study, not a decision record. Host: macOS 26.7.1; SDK: macOS 27. Items marked *unverified* were not run or could not be
confirmed from a primary source.

## Short answer

- Offer **both** primitives: App Sandbox driven by entitlements (supported), and Seatbelt profiles through `sandbox-exec`
  (works today; undocumented and unsupported for third parties).
- **They cannot be stacked on one process** (tested below, in both orders). They are alternative *engines* for a workload.
  Isolation in depth comes from separate layers instead: the hypervisor boundary, Apple's own sandboxed per-VM service, a
  helper process under one of the two engines, and the network policy in the user-mode stack.
- **Neither engine, nor all of them together, guarantees full isolation.** A sandbox narrows what a process may touch; the
  kernel, the entitlements it keeps and the profile's own mistakes remain the attack surface. The help must not say
  otherwise.
- The boundary that matters most is **one helper process per workload**.
- **Hard limit:** a virtual machine's display view is an in-process `NSView`; no public API exports its framebuffer to
  another process. Headless workloads (containers, server guests) can live in helpers; GUI machines stay in the app.

## What is public and what is not

| Layer | Status | Evidence |
|---|---|---|
| App Sandbox (`com.apple.security.app-sandbox`, `~/Library/Containers`) | Public, supported | Apple's Security documentation |
| `sandbox-exec(1)` | Man page: "DEPRECATED"; tells developers to adopt App Sandbox | `/usr/share/man/man1/sandbox-exec.1` |
| `<sandbox.h>` | Header says it "is deprecated and may be removed in a future release"; `sandbox_init` is marked no longer supported; a profile is ignored if the process is already sandboxed | `usr/include/sandbox.h` in the macOS 27 SDK |
| `sandbox_init_with_parameters`, `sandbox_apply_bytecode`, `sandbox_extension_*`, `sandbox_check*` | Exported by libsystem_sandbox, not declared publicly (SPI) | `usr/lib/system/libsystem_sandbox.tbd` |
| SBPL, the profile language | Not documented for third parties | Apple Developer Technical Support, forum threads 661939 and 777509 |
| Hardened runtime | Public; code-signing hardening, not an access-control sandbox | Apple documentation |
| Enhanced Security entitlements | Public; memory and runtime hardening, not a resource sandbox | Apple documentation |
| Endpoint Security | Public API but needs a restricted entitlement; macOS 27 adds a client that sees only a process's descendants | `ESClient.h` in the SDK |

Apple's engineers have said that building a product on custom SBPL "would be unwise". A request to the containerization
project for a deprecation timeline and a replacement is open and unanswered.

## What was run on this host

`sandbox-exec` is present and **still works on macOS 26.7.1**, with no deprecation notice printed.

| Profile | Command | Result |
|---|---|---|
| `(deny default)(allow process-exec*)` | `/usr/bin/true` | Aborts, exit 134: `dyld` cannot read the system libraries under deny-default |
| `(allow default)(deny file-read* (subpath "/private/etc"))` | `/bin/cat /etc/hosts` | `Operation not permitted`, exit 1 |
| `(allow default)(deny network-outbound)` | `curl http://example.com` | `Could not resolve host`, exit 6 (the resolver is blocked too) |
| deny outbound, allow `(remote ip "*:443")` | `curl https://example.com` | Same resolver failure, exit 6 |

The last two matter for design: a profile that restricts the network must also let the process reach the system resolver
(the `mDNSResponder` socket and its Mach service), or name lookups fail before any connection is attempted. Apple's
diagnosing article lists the same failure.

## Can the two be combined? Tested

On macOS 26.7.1, with tiny programs in `/tmp`, packaged as minimal apps and signed ad hoc with the
`com.apple.security.app-sandbox` entitlement (a bare executable with that entitlement traps, because it needs a bundle
identifier from an embedded Info.plist):

| Setup | Result |
|---|---|
| App Sandbox app, run directly | Works. `HOME` becomes `~/Library/Containers/<id>/Data`; writing under `/tmp` is denied; reading `/etc/hosts` is still allowed |
| Plain executable under `sandbox-exec` with a write deny | Works. The write is denied; everything else is unchanged |
| App Sandbox app launched **under** `sandbox-exec` (even `allow default`) | **Aborts**, exit 133 |
| `sandbox-exec` run **from inside** an App Sandbox app | **Fails**: `sandbox_apply: Operation not permitted` |

So a process gets one sandbox. An App Sandbox app cannot launch a Seatbelt-wrapped child, and a Seatbelt-wrapped process
cannot become an App Sandbox app. This matches `sandbox.h`: a profile is ignored when the process is already sandboxed.

Consequences for the design:

- The **main app stays unsandboxed** (Developer ID or ad-hoc distribution, not the Mac App Store), so it can launch helpers of
  either kind. An App Sandboxed main app could not launch Seatbelt helpers.
- Each workload's helper uses **one** engine: an App Sandbox helper bundle with its own entitlements, or a plain
  helper launched through `sandbox-exec -f profile.sb` (or applying the profile itself at start-up with the SPI call).
- Running a virtual machine inside a `sandbox-exec` helper is **unverified**: the profile must allow the Mach services the
  framework uses, and the helper still needs the virtualization entitlement. That is the first thing the prototype checks.

## Facts that decide the design

**What Apple already does for a virtual machine.**
- Each VM runs in its own `com.apple.Virtualization.VirtualMachine` XPC service instance. It is not App Sandboxed; it runs
  a bundled Seatbelt profile that denies by default, denies reads under `/Users`, allows a short Mach-lookup list and gates
  each device capability on a per-feature sandbox extension (`com.apple.virtualization.extension.*`: bridged networking,
  USB passthrough, audio in and out, paravirtualized graphics, Linux GPU acceleration, Rosetta share).
- File access reaches that service as `com.apple.app-sandbox.read` and `.read-write` extensions.
- *Inference, not documented:* the framework issues exactly the extensions your `VZVirtualMachineConfiguration` implies, so
  the helper already follows least privilege, and the app cannot add rules to it.

**How Apple's container tooling does it.** Its runtime helpers are signed with only `com.apple.security.virtualization`,
run one per container, and are not App Sandboxed. Isolation comes from the per-container virtual machine and the process
split.

**Entitlement requirements in the SDK headers.**
- Bridged networking: restricted `com.apple.vm.networking`; avoid.
- Network block device storage: `com.apple.security.network.client`.
- Loading a macOS restore image: `com.apple.security.virtualization`.
- A vmnet network can only be used by the process that created it, and creating one needs an entitlement.
- Every call on a `VZVirtualMachine` must run on its queue (the main queue by default; a custom serial queue from macOS 26).

**What Seatbelt can enforce.** Path rules (literal, subpath, regex), Mach lookups, `sysctl` names, IOKit opens, process
exec, signals, ioctls, and network by remote address and port pattern, but **never by domain name**. File rules apply when
a file is opened: a descriptor opened before the profile applies keeps working, which is why passing descriptors into a
helper is workable. A child inherits its parent's sandbox. Apple's system profiles are marked as private and subject to
change.

## Feasibility

| Scope | App Sandbox | Seatbelt via `sandbox_init_with_parameters` (SPI) | `sandbox-exec` (deprecated) | Separate process / XPC |
|---|---|---|---|---|
| Whole app | Feasible, public. Needs `app-sandbox`, `virtualization`, user-selected file access with security-scoped bookmarks, `network.client` for downloads and the user-mode stack's host sockets. Avoid `com.apple.vm.networking`. | Not worth it | Cannot wrap an already-running GUI app | – |
| One VM, in the app | Partial. The sandbox is per process, so no per-VM difference; Apple already sandboxes the per-VM service | No | No | Partial |
| One VM, in its own helper | Feasible for headless VMs | Partial; SPI | Partial | Feasible. A GUI VM is not feasible across processes with public API |
| One Linux container | Feasible as an extra layer around the runtime helper (untested) | Partial; SPI | Partial | Feasible; matches Apple's one-helper-per-container model |
| A cloned macOS VM | Same as one VM | – | – | Same as one VM |
| A macOS process, as a "container" | No: needs a signed, entitled executable | Feasible, unsupported: a deny-default profile per workload | Feasible, unsupported: `-f profile.sb -D key=value command` | Partial: macOS 27's descendants client needs a restricted entitlement |
| A helper process | Feasible, public; a helper inherits the sandbox with `com.apple.security.inherit`, or is signed separately with its own entitlements | Feasible; cannot be applied twice | Feasible | Feasible, public |

## Settings model

One setting with an app-wide default and a per-workload override:

`SandboxEngine`: `none`, `appSandbox`, `seatbelt`.
`SandboxLevel`: `standard`, `strict`, `custom` (what the engine is asked to allow).

- `none`: in the app, or in a helper signed with the virtualization entitlement only (Apple's own container setup).
- `appSandbox` + `standard`: a helper bundle with `app-sandbox`, `virtualization` and `network.client`; file access only from
  descriptors and bookmarks handed over by the app.
- `appSandbox` + `strict`: as above without network entitlements; the guest's network comes from the user-mode stack through
  a file-handle attachment, so the helper never opens a socket of its own.
- `seatbelt` + `standard` or `strict`: a generated deny-default profile per workload (paths it may read or write, Mach
  services, address and port patterns for the network), applied with `sandbox-exec -f` or at start-up in the helper.
- `seatbelt` + `custom`: a user-supplied SBPL template with parameters, labelled advanced and unsupported.

Engines are exclusive per workload; the interface says so and explains why. Defence in depth is shown as the list of layers
that apply to that workload: hypervisor, Apple's per-VM service, the chosen engine, the network policy.

Order of operations in a helper: spawn it, apply the sandbox before it touches guest data, receive descriptors over XPC,
then create the `VZVirtualMachine` on the helper's own queue. The network policy remains the domain-level control; the
sandbox is a coarse backstop (address and port patterns, Mach-lookup allow-list).

Debugging: Console filtered on subsystem `com.apple.sandbox.reporting`; the unified log for the `Sandbox` sender
(*predicate unverified*); the sandbox daemon's reports.

## Plan

1. **Prototype (days):** a headless helper for one Linux VM or container, signed with only the virtualization entitlement.
   Pass the disk and share descriptors over XPC. Measure boot time and count sandbox denials in the log.
2. **Two engines on that helper:** (a) as an App Sandbox bundle (`app-sandbox`, `virtualization`, optionally
   `network.client`); (b) as a plain helper under a generated Seatbelt profile. For each, check NAT, shared folders and the
   user-mode stack, and name resolution first. Record which Mach services the profile needs.
3. **Settings model, per-workload override and interface.** Keep GUI machines in the app.
4. **Seatbelt for macOS process-level containers** (native binaries, no virtual machine), outside the App Store build.

## Risks

- Offering Seatbelt means the app is not a Mac App Store build: the store requires App Sandbox on the main app, and a
  sandboxed main app cannot launch Seatbelt helpers (tested). SPI use would likely be rejected anyway (*inference*), and the
  restricted networking entitlement needs Apple's approval.
- No deprecation timeline exists for `sandbox-exec`; profile maintenance is ours.
- Helper sandboxes can break when macOS changes its allowed Mach lookups. Keep a regression test that boots a workload at
  each level.

## Not verified

The behaviour of the user-mode stack under App Sandbox, whether the framework issues extensions as inferred, the exact
unified-log predicate, and the wording of a later Apple engineer comment about the macOS 27 descendants client.
