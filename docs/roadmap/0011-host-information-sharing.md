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
The folder is removed when the machine stops, so its last facts do not travel with a copied bundle, and a start whose folder
cannot be emptied fails rather than serve what was left in it. Turning the share on or off drops a saved memory image.

Each file is rewritten in place (truncated, then written in one call), never replaced. A real Linux guest that read a
file every 0.1 s found it missing for about a second at a rewrite while the files were replaced by rename, most likely
because its virtio-fs entry cache still held the old file. A reader can still find a file empty for a moment, so a guest
reads a file that is empty or missing again a second later. That writing in place ends the gaps is owed to a real guest.

## Built

`VMConfig.hostInfo` (battery, power, thermal state, network path, time zone; all off by default), cleared by Isolated
and Hardened, counted in the posture and listed in the exposure summary; the share, the publisher, the editor section
with a preview of the files, and the help topic *Host information*.

## Owed

An authorised real-guest run on 2026-10-22 mounted the share in a Linux guest, read each file, found the share read-only
(creating, appending and removing were refused) and saw each rewrite without remounting; it found the gaps that the files
are now rewritten in place to close. Still owed: a macOS guest (`mount_virtiofs` with a custom tag), a fact that really
changes (a partial battery, on battery, Low Power Mode, a new path or time zone), Suspend with the share on, and a guest
that reads through a rewrite without a gap.
