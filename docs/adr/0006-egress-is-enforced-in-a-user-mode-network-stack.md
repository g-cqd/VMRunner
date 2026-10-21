---
status: accepted
date: 2026-10-21
---
# 0006 — Egress is enforced in a user mode network stack

## Context

The framework's NAT attachment is a black box: it cannot be told to refuse a connection, report a flow or follow a changed
host route. A guest-side firewall is not trustworthy against the guest.

## Decision

1. Filtered mode gives the guest a file-handle network attachment that carries raw Ethernet frames. A user-mode stack on
   the host answers ARP, DHCP, ICMP, UDP and TCP, runs a DNS proxy against the host resolver, and opens host sockets.
2. A guest SYN is judged by the policy first; the host connect is opened only if allowed, and the guest SYN-ACK is sent
   only after it succeeds. A denial gets a reset, or is dropped by configuration.
3. DNS answers feed a bounded address-to-name table the policy uses to judge later connections.
4. The core is a synchronous state machine with an injected clock; one thread owns it with a kqueue, the host sockets and
   a socketpair to the guest. The per-packet paths for ARP, DHCP, ICMP, UDP and TCP data allocate nothing.
5. Policy changes re-judge open flows; a change of the host's network path resets them so guests reconnect over the new
   path. A VPN detector classifies guest tunnels (WireGuard, OpenVPN, IKE/IPsec, L2TP, PPTP) from their traffic.

## Evidence

427 tests passed at the time of the change, including integration tests over a real socketpair against loopback servers;
no sanitizer reported a problem after a race in the command inbox was fixed. Throughput on loopback in a release build
was about 820 MiB/s guest-to-host at MTU 1500.

## Consequences

Not provided: IPv6, fragment reassembly, path-MTU discovery, ESP/AH/GRE passthrough (IPsec and PPTP inside the guest
cannot pass, but are detected), SACK and congestion control. DoH, DoT and QUIC-based DNS cannot be intercepted.

## What this does not decide

Behaviour against real macOS and Linux guests: DHCP and MTU handling, checksum offload on the framework's NIC and
throughput through the framework were not verified, because CI cannot start a VM.
