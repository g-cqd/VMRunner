---
status: in-progress
blocked-by: []
date: 2026-10-21
---
# 0011 — Per-machine, opt-in forwarding of battery, power, thermal, network path and time zone

One switch per category, delivered read-only (a share or vsock), listed in the security summary and explained in help.

## Delivery

A read-only virtio-fs share, tag `vmrunner-host`, not vsock: a guest reads it with `mount` and `cat`, with no agent to
install, and the app never parses anything the guest sends. The folder is `HostInfo` in the machine's bundle, removed and
made again, private, at each start, so nothing a copied bundle left there (a link included) is served. One `key=value`
file per category, written at the start, every minute, and when the Mac's network path changes.

Each file is rewritten in place (truncated, then written in one call), never replaced. A real Linux guest that read a
file every 0.1 s found it missing for about a second at a rewrite while the files were replaced by rename, most likely
because its virtio-fs entry cache still held the old file. A reader can still find a file empty for a moment, so a guest
reads a file that is empty or missing again a second later. That writing in place ends the gaps is owed to a real guest.

## Built

`VMConfig.hostInfo` (battery, power, thermal state, network path, time zone; all off by default), cleared by Isolated
and Hardened, counted in the posture and listed in the exposure summary; the share, the publisher, the editor section
with a preview of the files, and the help topic *Host information*.

## Owed

A real-guest run: mounting the share in a Linux and in a macOS guest (`mount_virtiofs` with a custom tag on macOS is
unverified), reading each file, and seeing a change without remounting.
