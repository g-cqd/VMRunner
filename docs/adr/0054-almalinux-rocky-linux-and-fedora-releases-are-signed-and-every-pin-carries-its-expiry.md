---
status: proposed
date: 2026-10-22
---
# 0054 — AlmaLinux, Rocky Linux and Fedora releases are signed, and every pin carries its key's expiry

This ADR amends [ADR-0023](0023-pinned-vendor-keys-vouch-for-installer-checksums.md), which left AlmaLinux and Rocky Linux on
HTTPS alone, did not decide which Fedora releases beyond 44 the app offers, and said the app cannot see a key's expiry; and
[ADR-0030](0030-download-hosts-are-named-exactly-and-ipsw-me-is-trusted-for-metadata-only.md), which left their hosts
unregistered. Everything else in both stands.

## Context

Both vendors sign what they publish. AlmaLinux signs one `CHECKSUM` list per major version inline, as a cleartext-signed
message (the shape Fedora uses); Rocky Linux signs one `CHECKSUM` list per major version with a detached `CHECKSUM.asc`, beside
unsigned per-ISO files. Read on 2026-10-22: the AlmaLinux 10 key (`EE6D B7B9 8F5B F5ED D9DA 0DE5 DEE5 C11C C2A1 E572`, published on
almalinux.org/security and in the AlmaLinux 10 release notes), the Rocky Linux 10 key (`FC22 6859 C086 0BF0 DDB9 5B08 5B10 6C73
6FED FC85`, published on rockylinux.org/keys; its key file is served by download.rockylinux.org) and the Fedora 43 key
(`C6E7 F081 CF80 E131 4667 6E88 829B 6066 3164 5531`, published on fedoraproject.org/security) are version 4 RSA-4096 keys with no
expiry, and each verified the vendor's real signed list. Fedora served releases 43 and 44; 45 was not released. The three hosts
served the ISOs with HTTP 200 and no redirect. A key's expiry is stated in the key's own self-signature, so it can be pinned
with the key: none of the keys pinned before this ADR states one, and Debian's archive key states 2035-03-28.

## Decision

1. **AlmaLinux 10** (boot and minimal ISOs) is a signed provider: its `CHECKSUM` list must be a cleartext message signed by the
   pinned AlmaLinux 10 key. The release is chosen from the signed list, never from the directory listing; the series is `10`
   and the oldest release accepted is `10.2`.
2. **Rocky Linux 10** (boot and minimal ISOs) is a signed provider: the directory's `CHECKSUM` list must carry a valid
   `CHECKSUM.asc` from the pinned Rocky Linux 10 key; the per-ISO checksum files are no longer read. The release is chosen from
   the signed list; series `10`, oldest `10.2`.
3. **Fedora Server** is offered for every release the vendor supports and the app pins a key for: 43 (oldest compose `43-1.6`)
   and 44 (`44-1.7`). A release without a pinned key is refused, as before. A new release needs its key, a real signed
   `CHECKSUM` as a test fixture and a catalog entry.
4. The allow-list gains exactly `repo.almalinux.org`, `download.rockylinux.org` and `dl.fedoraproject.org`, and the six
   images move from the candidates to the offered list.
5. **Every pinned key records the expiry its vendor states** (`PinnedKey.expires`, nil when there is none). The verifier refuses
   any signature from the second the pinned key expires, whatever the signature's date, so an expired key fails closed until an
   app update pins its successor. A test fails 90 days before any pinned key expires, and each release re-checks every pin
   against its vendor's page (CONTRIBUTING, "Releasing").

## Consequences

A compromised mirror or CDN can no longer substitute an AlmaLinux, Rocky Linux or Fedora 43 installer together with its
checksum. Each new major version of AlmaLinux or Rocky Linux and each Fedora release costs an app update, as Fedora 44 did. The
Rocky Linux fingerprint is published on one page of the vendor's site; the second source is the key file on its download host.
Revocation is still not seen: the release check is how a revoked key would be noticed.

## What this does not decide

The Debian netboot chain (the archive's signed `InRelease` lists the netboot index's checksum, but carries several signatures,
one of them by a subkey); AlmaLinux and Rocky Linux major versions other than 10; Fedora 45 until it is released; revocation.
