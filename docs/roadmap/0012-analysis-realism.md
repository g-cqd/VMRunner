---
status: in-progress
blocked-by: []
date: 2026-10-21
---
# 0012 — Fewer virtual-machine tells, for sandbox analysis and privacy use

Study: `docs/research/analysis-sandbox-2026-10.md`. NVMe disk and serial identifiers, a MAC vendor prefix, a fresh identity on each
disposable start, and honest help on what a guest can still tell.

## Built

A vendor prefix for the addresses VMRunner makes (`MACVendor`: none, Apple, Intel, Realtek); an NVMe disk for Linux
guests and a serial number for the virtio disk; a fresh MAC address and machine identifier at each start of a disposable
machine (the identifier lives beside the disposable disk and goes with it); and the help topic *Guest identity*, which
says what a guest can still tell. These settings are not part of the security profiles: they neither open nor close a
channel between guest and host.
Changing the disk's interface or serial number drops a saved memory image, which could not be restored into the changed
machine, and the editor keeps a serial number to printable ASCII without spaces.

## Owed

An authorised real-guest run on 2026-10-22 saw a Linux guest's disk on NVMe, the serial number of a virtio disk as the
guest reads it, and an address with each vendor prefix (and a locally administered one) get a DHCP lease and carry HTTP
on NAT. Still owed: a disposable macOS guest started with a new identifier (done 2026-10-22, see the diary entry 2026-10-22-07). The three prefixes match the public IEEE
registry of manufacturer prefixes.

2026-10-22: a real run showed a disposable run's address saved into the machine; fixed: it is used for the run only.
