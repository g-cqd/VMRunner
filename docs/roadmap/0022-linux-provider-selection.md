---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0021
---
# 0022 — Choose which vendors to register

Owner decision (ADR-0015, item 3). Debian (netboot mini), CentOS Stream, Alpine Linux and Ubuntu Server 26.04 LTS are
offered (ADR-0021); the rest stay candidates in `LinuxCatalog.candidates`. Alpine takes the newest release that has a published
signature, and the setup says when it passed over a newer one (roadmap 0023).

AlmaLinux 10, Rocky Linux 10 and Fedora Server 43 and 44 are offered as signed providers (ADR-0054). Remaining: Debian netinst
is blocked because its ISO download redirects to a third-party mirror, which the redirect policy refuses. A new Ubuntu LTS, a
new AlmaLinux or Rocky Linux major version and each new Fedora release need a catalog entry and a pinned key. Checksum signatures are roadmap 0023.
