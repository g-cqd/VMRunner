---
status: accepted
date: 2026-10-21
---
# 0023 — Pinned vendor keys vouch for installer checksums

This ADR amends [ADR-0015](0015-installers-come-from-the-vendors-over-https-with-pinned-hosts.md). Its decision 2 (an ISO is
verified against the mirror's checksum file) now has a stronger form for the vendors named below, and the gap its "What this
does not decide" left (OpenPGP signatures) is decided here. Decisions 1 and 3 of ADR-0015 stand, and ADR-0015 stays accepted.

## Context

ADR-0015 trusts a checksum because it came over HTTPS from the vendor's own host. That does not help when the host serves
a substituted installer and a matching checksum together, which matters most where the download lands on a third-party mirror
or a CDN. Several vendors also publish OpenPGP signatures. The
[study](../research/openpgp-verification-2026-10.md) found that the four it examined (Debian, Ubuntu, Fedora, Alpine) use version
4 signatures with RSA-4096 keys, made with SHA-256 or SHA-512, and that no maintained Swift package fits the app's dependency
rule (ADR-0001: a new dependency needs an ADR, and the SDK already holds what a verifier needs).

## Decision

1. **Signed providers.** A provider whose vendor publishes a signature and whose key the app pins checks that signature in
   addition to the checks of ADR-0015: Debian (`SHA256SUMS.sign`), Ubuntu Server (`SHA256SUMS.gpg`), Fedora (the CHECKSUM file
   is cleartext-signed, one key per release) and Alpine Linux (`<iso>.asc`, which signs the ISO itself). Every other provider
   says `HTTPSOnlyTrust` in its definition and in its trust note: its checksum is vouched for by HTTPS and the vendor's host
   alone. A provider is never both: a signed provider that cannot prove its signature stops the setup and does not fall back
   to HTTPS alone.
2. **A small verifier of our own.** It reads only version 4 RSA signatures of type binary or text with SHA-256, SHA-384 or
   SHA-512. It refuses every other version, algorithm, hash (MD5, SHA-1 and RIPEMD-160 included), signature type, trailing
   byte, partial or overflowing length, critical subpacket it does not know, creation time in the future and expired
   signature, and a file with more than one signature. It trusts only the hashed subpacket area: the signer is identified by
   the issuer fingerprint there, which must be a pinned key, and never by the unsigned key ID. The public-key operation is
   Security.framework's `SecKeyVerifySignature` over a digest CryptoKit computed, so a large installer is hashed in chunks.
3. **Pinned keys are constants in the source.** A key is pinned only after its fingerprint, recomputed from the constants,
   equals the fingerprint the vendor publishes on its own HTTPS site, and after a real signature from it verified. The app
   recomputes the fingerprint before using a constant and refuses one that does not match, and a test does the same for
   every key. Constants avoid bundling a resource file into the app. Fedora is pinned per release, and a release with no pin
   fails closed.
4. **What is signed is what is read.** For a signed checksum file only the signed text is read for digests, so unsigned text
   around a cleartext message is never used. Alpine's SHA-256 file is not signed, so its signature is checked against the
   downloaded ISO (streamed SHA-512) and the SHA-256 is checked as well; a cached installer is checked again before it is
   reused.
5. **Signature files** are fetched like any small document: HTTPS, an allow-listed host, redirects refused, and capped at 16 KiB.
6. **Failure is specific.** A missing, malformed, wrongly made, expired, future-dated or tampered signature produces an error
   that names the file and the reason.

## Consequences

A compromised mirror or CDN can no longer substitute an installer together with its checksum for these four vendors. The
pins are trust on first use: the fingerprint was compared with the vendor's own pages, so a compromised vendor site at pin
time would have been pinned. A key change at a vendor fails closed until the app is updated with the new key, so rotation
costs an app update (Fedora's every release). The app cannot see revocation or expiry of a pinned key, so each pin is
re-checked against the vendor's pages when the app is updated. Alpine's signer is one maintainer's personal key, so a change
of signer also fails closed. A signature says who signed a file, not which release it is or that the file is safe, so a
genuine older file would verify too. Each signed provider therefore names its release series (Ubuntu `26.04`, Fedora `44`) and
the oldest release it accepts, the one current when its key was pinned (Ubuntu 26.04.1, Alpine 3.24.2, Debian 13.7.0, Fedora
44-1.7), and refuses anything older with a message that says so. Where the signed object is a list of many images (Debian,
Ubuntu) the release is chosen from the signed text and not from the unsigned directory listing, which could hide the newest
one. These floors move up with app releases; a copy of the app that is not updated still accepts every newer release. Debian's netboot index, CentOS Stream, AlmaLinux and Rocky
Linux remain on HTTPS alone, and say so.

## What this does not decide

Support for Ed25519, ECDSA or version 6 signatures, which fail closed until a vendor needs them; signatures made by a subkey;
certificate chains, web of trust and revocation; fetching keys at run time; pinning AlmaLinux and Rocky Linux keys and the
Debian archive's signed Release file for the netboot index; and which Fedora releases beyond 44 the app offers.
