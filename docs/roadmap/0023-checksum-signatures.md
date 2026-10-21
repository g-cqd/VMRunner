---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0023
---
# 0023 — Verify OpenPGP signatures of checksum files

Debian (netinst), Ubuntu Server, Fedora and Alpine Linux are verified against pinned vendor keys by an in-tree verifier
(ADR-0023, `Sources/VMRunner/Engine/PGP/`). The checksum file is the signed object for Debian, Ubuntu and Fedora; for Alpine
the ISO itself is, so its signature is checked after the download and its SHA-256 as well. A missing, malformed, wrongly made,
expired or tampered signature fails closed; every other provider says it is HTTPS only. Roadmap 0022 owns which of these
vendors are offered: today Ubuntu Server and Alpine Linux are, and Debian netinst and Fedora 44 are still candidates.

Remaining:

- AlmaLinux and Rocky Linux publish signatures too; each needs its key pinned and verified before it is registered as signed.
- Debian's netboot index is covered by the archive's signed Release file, which the app does not check.
- Fedora needs a new key pinned for every release it offers, and a release without one is refused. Fedora 45 is not pinned.
- Nothing has run the app's download path against a vendor's live servers; the resolve step was tested against the vendors'
  real files served in-process. Run it once on a Mac before relying on it.
- Pinned keys carry no expiry or revocation state; re-check each against the vendor's pages whenever the app is updated.
