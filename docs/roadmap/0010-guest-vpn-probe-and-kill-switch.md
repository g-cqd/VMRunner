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

When the network card keeps its attachment after the kill switch takes it off (read back at once), VMRunner stops the
machine and says why. This fails closed and is the default until the owner chooses between stopping the machine and only
showing an error. A framework that refuses the change has not been seen; the unit test uses a card that refuses.

Whether the attachment can be taken off before the machine starts, so that a guest whose rule is broken never has a link
at all, belongs to the same real-guest run: today the card is cut just after the machine starts.

An authorised real-guest run on 2026-10-22, with no VPN on the Mac, saw the kill switch on NAT and on the filtered network:
with a VPN required the guest had no carrier and no lease, and with a VPN forbidden the guest got a lease and carried traffic.
The card was taken off with `attachment = nil`, and the framework accepted it with no error, no stop and nothing in the app's
log. The reconnection after that cut is inferred from the code and the unit tests, not seen: it came before the guest brought
its interface up. Each cut and reconnection is now logged with its reason, so the next run can follow them without a screen. Still owed: a real VPN
coming up or going down while the guest runs, the metered switch on a hotspot, and a cut the framework refuses. A changed
rule takes effect at the next start: the kill switch keeps the rules it started with.
