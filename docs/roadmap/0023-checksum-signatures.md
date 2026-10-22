---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0023
---
# 0023 — Verify OpenPGP signatures of checksum files

Debian (netinst), Ubuntu Server, Fedora, AlmaLinux, Rocky Linux and Alpine Linux are verified against pinned vendor keys by an in-tree verifier
(ADR-0023, `Sources/VMRunner/Engine/PGP/`). The checksum file is the signed object for Debian, Ubuntu and Fedora; for Alpine
the ISO itself is, so its signature is checked after the download and its SHA-256 as well. A missing, malformed, wrongly made,
expired or tampered signature fails closed (except that Alpine, which signs each ISO after publishing it, falls back from a release
whose signature answers 404 to the newest one that has one, never below its floor, and tells the user); every other provider says it is HTTPS only. Roadmap 0022 owns which of these
vendors are offered: today Ubuntu Server, Alpine Linux, AlmaLinux 10, Rocky Linux 10 and Fedora Server 43 and 44 are
(ADR-0054), and Debian netinst is still a candidate.

Remaining:

- Debian's netboot index is covered by the archive's signed Release file, which the app does not check yet (board item F4,
  waiting for the owner).
- Fedora needs a new key pinned for every release it offers, and a release without one is refused. Fedora 45 is not pinned.
- Nothing has run the app's download path against a vendor's live servers; the resolve step was tested against the vendors'
  real files served in-process. Run it once on a Mac before relying on it.
- Pinned keys carry their expiry (ADR-0054) but not their revocation state; re-check each against the vendor's pages at each
  release.
