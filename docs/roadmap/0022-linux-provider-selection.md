---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0021
---
# 0022 — Choose which vendors to register

Owner decision (ADR-0015, item 3). Debian (netboot mini), CentOS Stream, Alpine Linux and Ubuntu Server 26.04 LTS are
offered (ADR-0021); the rest stay candidates in `LinuxCatalog.candidates`.

Remaining: AlmaLinux, Rocky Linux and Fedora each need their host added to `DownloadPolicy.allowedHosts` (exact names, ADR-0030) and a move
into `LinuxCatalog.images`. Debian netinst is blocked because its ISO download redirects to a third-party mirror, which the
redirect policy refuses. A new Ubuntu LTS needs a new catalog entry when it ships. Checksum signatures are roadmap 0023.
