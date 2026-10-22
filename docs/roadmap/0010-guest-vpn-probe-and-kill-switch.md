---
status: in-progress
blocked-by: ["0009"]
date: 2026-10-21
---
# 0010 — Detect tunnels the heuristic cannot see, and cut the network on demand

An optional in-guest probe over vsock merged with the host-side state, a metered or constrained network guard, and a
kill switch that swaps the NIC attachment.

## Built

The kill switch. Each machine has a VPN rule (`NetworkPolicy.vpn`: required or forbidden on the Mac) and a switch for
metered or Low Data Mode paths (`networkCutsOnMeteredPath`), in every mode with a network card. `NetworkCutoff` follows
the Mac's network path and takes the attachment off the network card while a rule is broken, then puts the same one back;
an unknown VPN state breaks both VPN rules. The editor, the exposure summary, the help (*Kill switch*) and the toolbar
show it. The rules are not part of the security profiles: they close, they never open.

## Not built

The in-guest probe. It needs a program in the guest and a listener on the host's vsock device, a new guest-to-host
channel whose bytes the app would parse: it waits for a decision (an ADR) on its wire format and on who installs the
program in the guest.

## Owed

A real-guest run, with NAT and with the filtered network: the guest's link goes down when the attachment is taken off
and comes back when it is put back, and how long the guest takes to notice; the VPN rule against a real VPN; the metered
switch on a phone's hotspot.
