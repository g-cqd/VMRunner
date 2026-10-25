---
status: proposed
date: 2026-10-21
---
# 0019 — Private API is confined to one module with fail-closed capabilities

## Context

Several use cases in the research notes cannot be done with public API: a Windows guest's PMU switch, reducing virtual-machine
tells, Seatbelt profile application, cross-process display. The owner wants the utmost security while using private API, and
has two own packages (an Objective-C-runtime interop layer and a compile-time string macro) that may be imported.

## Decision

1. One target, `PrivateInterfaces`, is the only code that touches private API. A lint test fails the build if the runtime
   lookup functions or the interop import appear anywhere else.
2. Every private call belongs to a **capability** with an id, an OS build range, a resolver, a validator that checks the real
   signature against the declared one, a fallback, and a kill switch. A capability that does not validate on the running OS
   build is off, and the interface says so.
3. The interop package is imported as the only dependency in this area, pinned by reviewed revision (it has no releases).
   The string macro package is not imported separately: the interop package already re-exports it.
4. Risky calls and the Seatbelt SPI run in the per-workload helper process.
5. The Hardened preset turns every private capability off; kill switches persist and can be forced by managed preferences;
   the security summary lists each capability as using unsupported API.
6. Nothing depends on a `com.apple.private.*` entitlement, on turning code-signing enforcement or SIP off, or on disabling
   library validation.
7. Obfuscating names is optional and never relied on.

## Consequences

Nothing is built. Contract tests against a golden file per OS build, a canary that fails on an OS beta, and a leak check run
locally. Upstream gaps (OS gating, per-feature switches, redacted logging, `dlsym` support, tags, contract tests against the
virtualization classes) are listed in `docs/research/private-apis-2026-10.md`.

## What this does not decide

Whether Windows support is revisited (ADR-0010 stands), and which capabilities ship first. The spike starts with the PMU
setter and the sandbox-apply call.

(Update 2026-10-25: [ADR-0059](0059-windows-on-arm-is-supported-with-its-one-private-interface-behind-a-fail-closed-module.md)
supersedes ADR-0010, so "ADR-0010 stands" above no longer holds, and starts the module with the PMU capability alone. It
differs from item 3: the module calls the Objective-C runtime itself and imports no interop package. The Seatbelt capability
is not part of that start.)
