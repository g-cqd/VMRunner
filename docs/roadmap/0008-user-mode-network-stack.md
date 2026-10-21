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

## Still owed

Validation against real macOS and Linux guests: DHCP and MTU handling, checksum offload, throughput through the framework.
