---
status: accepted
date: 2026-10-22
---
# 0029 — The host's own addresses are a floor under every policy

## Context

`blockPrivateRanges` was the only switch for every built-in range. A user who turned it off to let a guest reach a
printer or a NAS also opened the Mac's loopback interface (every service bound to localhost), `0.0.0.0`, link-local
addresses including the cloud metadata address `169.254.169.254`, and the NAT gateway range. Those are not other
people's networks; they are the machine the guest runs on, and an allow rule or a convenience switch is the wrong tool
to grant them. The range table also lacked `198.18.0.0/15`, where the user-mode network puts its own gateway and guest.

## Decision

1. The built-in ranges split in two. The **floor** is loopback (`127.0.0.0/8`, `::1`), unspecified (`0.0.0.0/8`, `::`),
   link-local (`169.254.0.0/16` with the metadata address, `fe80::/10`), the NAT gateway `192.168.64.0/24`, and
   `198.18.0.0/15`. Everything else the table lists (RFC 1918, carrier-grade NAT `100.64.0.0/10`, unique-local and
   site-local IPv6, multicast, the reserved blocks) is what `blockPrivateRanges` governs.
2. `NetworkPolicy.evaluate` denies a floor address whatever `blockPrivateRanges` says and whatever the allow lists say,
   for literals, for every address a name resolved to and for the IPv4 address embedded in mapped, NAT64, 6to4 and
   compatible IPv6 forms. The DNS proxy applies the same test, so those addresses are also removed from DNS answers.
3. There is no opt-out in the policy, the editor or the saved file. The only way past the floor is a set of kinds on the
   stack's own configuration (`UserNetConfig.exemptedFloorKinds`), empty in the app, which the integration tests use to
   reach servers on their loopback interface.
4. The exposure summary and the help say which addresses stay blocked.

## Consequences

A guest that must reach a service on the Mac itself can no longer be given that access with the private-range switch.
Policies saved before this change keep their meaning for every network they could reasonably reach; only a policy that
relied on loopback or link-local access through the switch stops working. A later change can add an explicit per-kind
opt-in (for example, "allow the Mac's loopback services" with its own exposure line); it is left out so that this
change adds no way to lift the floor.

## What this does not decide

The stack's own gateway `198.18.0.1` is not a policy question: the guest's subnet is on-link, only DNS is served there,
and a ping to the gateway is answered locally. IPv6 is not routed at all. Multicast and the reserved blocks stay under
`blockPrivateRanges`, though the stack drops multicast and broadcast traffic itself.
