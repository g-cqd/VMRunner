---
status: accepted
date: 2026-10-21
---
# 0015 — Installers come from the vendors over https with pinned hosts

## Context

An installer or restore image that is tampered with in transit becomes the guest's root of trust.

## Decision

1. Downloads are https only, from a named set of host suffixes, with redirects refused, file names and identifiers
   validated, and sizes capped.
2. IPSW files are verified against the SHA-256 ipsw.me publishes; ISOs against the mirror's checksum file. A cached
   installer is re-verified before it is reused.
3. Providers are limited to a short list of trustworthy vendors; the rest stay unregistered candidates until chosen.

## Consequences

Checksums are fetched from the same vendor over https, so they do not defend against a compromised vendor.

## What this does not decide

OpenPGP signature verification of checksum files, which needs a keyring and a decision on whose keys to trust.
