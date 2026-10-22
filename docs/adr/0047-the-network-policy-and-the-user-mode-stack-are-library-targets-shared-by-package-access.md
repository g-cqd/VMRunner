---
status: accepted
date: 2026-10-22
---
# 0047 — The network policy and the user-mode stack are library targets of the root package, shared by `package` access

## Context

The headless helper (ADR-0016) must host the user-mode network stack to run a real guest under test, and it must not link
the app. The policy (ADR-0005) and the stack (ADR-0006) were folders of the app target. Earlier commits cut the seams: the
policy references no app type, and the stack references five policy types, an injected logger and no Virtualization. The
study (`docs/research/modularization-2026-10.md`) weighed packages of their own, which would force a `public` surface of
hundreds of declarations, against targets in the root package, and recommended the second as the cheaper first stage.

## Decision

1. **Two library targets in the root package.** `NetPolicy` (rules, host and IP parsing, the gate) links the system
   frameworks only. `NetStack` links `NetPolicy` and the system frameworks. The app, the headless helper and the tests link
   them. They become packages of their own only when a consumer outside this repository exists.
2. **`package` access, never `public`.** A declaration is `package` when another target of this package uses it, and
   `package import` where such a signature exposes a type of another module. Everything else stays internal; the targets'
   own tests use `@testable import`. Nothing is `public` because nothing outside the package links them.
3. **The per-packet path stays inside `NetStack`.** The generic core, the flows and the wire parsers are internal, and the
   app drives the stack through `UserNetStack` alone. There is no `@inlinable` and no library evolution; `swift run vmr
   check bench` after the move holds the allocation counts (exact) and the instruction budget (3%).
4. **The layering is checked.** A test reads the manifest and the sources: the two targets depend on each other and the
   system frameworks only, the helper does not reach the app, and neither directory imports SwiftUI, AppKit, Observation
   or Virtualization.
5. **Adapters stay in the app.** The Virtualization attachment, the logger and the activity and flow-log models are the
   app's; the stack knows no framework that needs a display.

## Consequences

This amends ADR-0001: the app target also links two targets of its own package, which add no external dependency. The
shared settings block and the test-support exemption of ADR-0011 are unchanged; the new targets use the hardened settings.
A new use of the stack from another target adds a `package` keyword, which review sees.

## What this does not decide

Whether the helper runs the stack (it only links it), nested packages for the image trust code, and the renames of the test
support targets (ADR-0042).
