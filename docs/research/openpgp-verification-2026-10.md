---
date: 2026-10-21
question: "How should the app verify OpenPGP signatures over the checksum files Linux vendors publish?"
feeds: [roadmap 0023, ADR-0015]
---
# Verifying vendor OpenPGP signatures

Study, not a decision record. Facts come from the vendors' published files and pages as of 2026-10-21. Packet headers were
decoded by hand from the fetched armor; no signature was cryptographically verified and no `gpg --list-packets` was run.
Items marked *unverified* were not confirmed.

## Short answer

- Write a small in-tree verifier and pin the vendor keys in the repository. All four vendors use **version 4 signatures over
  RSA-4096**. The hash is SHA-256 for Debian and Fedora and SHA-512 for Ubuntu and Alpine. `SecKeyVerifySignature`
  (Security.framework) and CryptoKit cover this with no package.
- No fetched file uses Ed25519, ECDSA or version 6. Support for them is a later option; until then they fail closed.
- Fedora is cleartext-signed with a text-mode signature (CRLF canonicalisation). Alpine signs the ISO itself, not a checksum
  file, so the whole ISO must be hashed with SHA-512.
- No maintained Swift OpenPGP package fits: the candidates found were archived, licensed for non-commercial use only, tied
  to a C crypto library, iOS-only, or immature. Shelling out to `gpg` is not viable: a stock macOS has none.

## What the files look like

Each signature header decoded to: old-format signature packet (`0x89`), version 4, RSA, a 29-byte hashed area holding an
issuer-fingerprint and a creation-time subpacket, a 10-byte unhashed area holding only the issuer key ID, and one 4096-bit
MPI. No signature-expiry, key-flag or notation subpackets.

| Vendor | Signed object | Container | Type | Hash | Issuer fingerprint |
|---|---|---|---|---|---|
| Debian | `SHA256SUMS` (`.sign`) | armored detached | 0x00 | SHA-256 | DF9B9C49EAA9298432589D76DA87E80D6294BE9B |
| Ubuntu | `SHA256SUMS` (`.gpg`, armored despite the name) | armored detached | 0x00 | SHA-512 | 843938DF228D22F7B3742BC0D94AA3F0EFE21092 |
| Fedora | `*-CHECKSUM` | cleartext-signed | 0x01 text | SHA-256 | the release key, 36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6 for 44 |
| Alpine | the ISO (`.iso.asc`) | armored detached | 0x00 | SHA-512 | 0482D84022F52DF1C4E7CD43293ACD0907D9495A |

Sources: the vendors' `SHA256SUMS`, `.sign`, `.gpg`, `CHECKSUM` and `.asc` files in the release directories used by the
providers. All issuers are primary keys, so subkey binding signatures are not needed for these files today.

Keys and where they are published over https:
- Debian: the verification page `https://www.debian.org/CD/verify` links the key file; RSA-4096, created 2011, no expiry.
- Ubuntu: the page names the key but gives only an HKP address; the key was fetched over https from the Ubuntu keyserver;
  RSA-4096, created 2012, no expiry.
- Fedora: one RSA-4096 key per release, listed on `https://fedoraproject.org/security` and in `fedora.pgp`. **A new Fedora
  release needs a new pin.**
- Alpine: the signer is one maintainer's personal key (RSA-4096, 2014), not a dedicated release key; the downloads page links
  it. The `.sha256` and `.sha512` files beside an ISO are not signed.

## What a strict verifier does

- **Armor and framing.** Strip armor headers and the CRC line, decode, accept old and new packet formats for tag 2. For
  cleartext files, undo dash-escaping; the signed text excludes the last line break before the signature block, trailing
  whitespace is stripped per line and line endings are canonicalised to CRLF for type 0x01.
- **Gate.** Accept only version 4, type 0x00 or 0x01, public-key algorithm 1 (RSA), hash SHA-256 or SHA-512 (or SHA-384).
  Reject MD5, SHA-1, RIPEMD-160, version 3, version 6 and everything else.
- **Hash.** `data || [04, type, pkalgo, hashalgo, hashedLen(2)] || hashedSubpackets || 04 FF len32`.
- **Verify.** Build a PKCS#1 `RSAPublicKey` from the pinned `n` and `e`, create the key with `SecKeyCreateWithData`,
  left-pad the signature MPI to the modulus length, verify with the message variant for small files and the digest variant
  (precomputed digest) for the ISO, which is hashed incrementally. Check the 2-byte hash prefix as an early reject.
  *The digest variant's handling of a precomputed digest must be proven with a known vector; unverified.*
- **Trust only the hashed area.** Match the issuer by the hashed issuer-fingerprint subpacket against a pinned fingerprint;
  the key ID in the unhashed area is a hint only. Honour a signature expiry if one appears.
- **Bind the file name.** The verified list must contain the downloaded name exactly (the `*` binary marker, two-space and
  BSD forms each need a strict parser, as the checksum parsers already are).
- **Pinned keys.** Store `n`, `e` and the fingerprint per key; a test recomputes the version 4 fingerprint
  (`SHA1(0x99 || len || key body)`) from the stored material and compares it with the constant.

## Alternatives considered

| Option | Verdict |
|---|---|
| A Swift OpenPGP package with a non-commercial licence, tied to OpenSSL, no cleartext support, last release in 2024 | Rejected |
| An archived Swift implementation (2019) | Rejected |
| A new, iOS-only package with internal symbols and no releases | Rejected |
| Swift bindings to a C OpenPGP library built as a vendored framework | Rejected: heavy, not system-frameworks-only |
| A Rust verifier without Swift bindings | Not a Swift package |
| Shelling out to `gpg` | Rejected for shipping; usable as a cross-check in tests where installed |

## Threat model

Adds: a compromised mirror or CDN can no longer substitute an ISO and its checksum together. This matters because Fedora's
download host redirects to third-party mirrors and Alpine is served from a CDN.

Does not add:
- **Trust in the pinned key.** It is trust on first use at pin time; check each fingerprint against at least two independent
  official sources when pinning.
- **Rotation.** Fedora rotates per release; a new key needs an app update (or a key fetched over https and accepted only if
  its fingerprint is already pinned).
- **Revocation and expiry.** A pinned verifier cannot see them; re-check the vendors' pages when updating pins.
- **Downgrade.** A missing signature must be a hard failure, never a skip; a genuine but old signed list still verifies, so
  replay is limited only by the cached-installer re-verification and the release choice.
- **Safety.** A signature says the vendor signed the file, not that the file is safe.

## Decision input

Implement behind a `ChecksumTrust` protocol so that a missing, malformed or untrusted signature fails closed with a clear
message and the https-only path stays available for providers that publish no signature. Fuzz the parser. A new ADR
amends ADR-0015.

## Not verified

No signature was verified cryptographically, and the base64 CRC lines were not checked. The Ubuntu arm64 signature was seen
only by size; Debian arm64 and Alpine aarch64 only by header prefix. Key expiry came from keyserver listings and a lossy
summary of the Fedora key file; self-signature subpackets and signing-capable flags were not parsed. The current Fedora
release set could not be confirmed. The digest-variant semantics and the EdDSA "digest as message" rule are from memory.
The Alpine key file was not fetched. Several mirrors of the documentation were unreachable, so one Fedora mirror was used.
