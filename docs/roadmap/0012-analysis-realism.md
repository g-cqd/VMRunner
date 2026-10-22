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

## Owed

A real-guest run: a disposable macOS guest started with a new identifier, a Linux guest moved from virtio to NVMe, the
serial number as the guest sees it, and an address with each vendor prefix on NAT. The three prefixes match the public IEEE
registry of manufacturer prefixes.
