---
status: done
blocked-by: []
date: 2026-10-21
decision: ADR-0004
---
# 0003 — Standard, Contained, Isolated and Hardened presets over editable switches

Presets set individual switches; the profile reads Custom after a deviation; a summary lists what the guest can reach.

The attached Linux installer image is one of those channels: the guest reads the whole file, whatever it is. Isolated and
Hardened detach it, the posture and the exposure summary count it, and re-attaching it makes the profile Custom.

A configuration file is data, so the host paths it names (shared folders, extra disks, the installer image) are honoured
only for paths the user approved in this app; Start asks about the rest (ADR-0024).

Turning suspend off, or disposable on, deletes a saved memory image already on disk, because the exposure summary says no
memory snapshot is written.
