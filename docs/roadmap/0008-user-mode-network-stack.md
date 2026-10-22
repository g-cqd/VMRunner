---
status: done
blocked-by: ["0007"]
date: 2026-10-21
decision: ADR-0006
---
# 0008 — Enforce the policy per connection on the host

ARP, DHCP, ICMP, UDP, TCP and a DNS proxy on a file-handle attachment, with a guest VPN detector, allocation-free packet
paths and path-change resets.

## Hardening after an adversarial review

A review of the stack with the guest as the attacker produced a series of fixes, each with a regression test:

- Every DNS answer is held to one byte budget (65,535 bytes over TCP, 512 over UDP), so an oversized answer is truncated
  instead of aborting the app.
- DNS resolution is a policy decision (ADR-0028): names, record types, answer records and addresses are checked, and the
  proxy no longer forwards what a guest merely asks for.
- The host's own addresses are a floor under every policy (ADR-0029): loopback, `0.0.0.0`, link-local and metadata, the
  NAT gateway and `198.18.0.0/15` are denied whatever `blockPrivateRanges` says.
- Refusals are published once per destination per five seconds with the rest counted ("x N"), log lines are coalesced the
  same way, and the stats count the events the reader had no room for.
- Opening UDP and ping flows is rate-limited and a full table makes room in batches, DNS over TCP buffers at most two
  queries in a ring (a longer length prefix resets the connection), and at most 32 DNS connections are open at once.
- DHCP is served only for datagrams from `0.0.0.0` or the leased address to the broadcast address or the gateway, and
  only a claimed client address equal to the lease is answered by unicast.

## Still owed

Validation against real macOS and Linux guests: DHCP and MTU handling, checksum offload, throughput through the framework.

Done since (roadmap 0034, item 4): a block rule for a name on some ports keeps holding for the addresses the proxy gave for
that name after the name table forgets them; lookups run on at most 32 resolver threads that take queued lookups in turn (256
wait at most, then SERVFAIL); the queue of frames waiting for the guest's socket is bounded in bytes (8 MiB) as well as
frames; repeated DNS answers are folded like refusals; a DNS-over-TCP answer that finds the guest-bound ring full resets the
session and is counted (`dnsAnswersLost`).

Left open on purpose:

- A block rule for a name on every port needs no derived block: the name is never resolved for the guest, so only an address
  the guest learned elsewhere reaches it, and that is judged by the address alone (ADR-0028).
- An explicit, separate opt-in for one kind of the floor (ADR-0029), should a guest ever need the Mac's loopback services.
