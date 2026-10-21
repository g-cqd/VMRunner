---
date: 2026-10-21
question: "How should the app verify OpenPGP signatures over the checksum files Linux vendors publish?"
feeds: [roadmap 0023, ADR-0015]
---
# Verifying vendor OpenPGP signatures

Study, not a decision record. Facts come from the vendors' published files and pages as of 2026-10-21. Packet headers were
decoded by hand from the fetched armor; when this study was written no signature had been cryptographically verified. The
implementation of roadmap 0023 later did so, and the "Not verified" section below says what it covered. Items marked
*unverified* were not confirmed.

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
- **Pinned keys.** For Debian, Ubuntu, Alpine and Fedora 44, the key's own file was fetched over HTTPS and its primary key
  was read by a script written for the purpose and by an OpenPGP command-line tool installed on the machine; both gave the
  same version 4 fingerprint, and it equals the fingerprint printed on the vendor's own HTTPS page (Debian's verification
  page, Ubuntu's verification tutorial, Alpine's downloads page, Fedora's security page). Each key is RSA-4096 with exponent
  65537. The constants in the source came from the script, and a test recomputes every fingerprint from them with the in-tree
  function.
- **Real signatures verify.** The in-tree verifier accepts Debian's `SHA256SUMS.sign`, Ubuntu's `SHA256SUMS.gpg` (26.04), the
  Fedora Server 44 CHECKSUM file, and Alpine's virt 3.24.2 `.asc` over the real 93 MB ISO, streamed through the SHA-512 path
  once by a throwaway test (the ISO is not a fixture, so the suite checks only the vetting of that signature). The first
  three files are committed as fixtures. The same signatures verified with that command-line tool. Observed hash
  algorithms: Debian SHA-256, Ubuntu SHA-512, Fedora SHA-256, Alpine SHA-512; all issuers are primary keys.
- **The digest variant.** `SecKeyVerifySignature` with the digest variant takes a precomputed digest and gives the same
  answer as the message variant over the message; a test signs with each and verifies with the other for SHA-256, SHA-384
  and SHA-512, and shows a wrong digest, a message in the digest's place and a wrong-sized digest fail. The verifier uses
  the digest variant for every file, in memory or streamed, so there is one path.
- **Armor checksums.** The CRC-24 of each real armor block is checked.

Still not verified:

- **Live use.** No run fetched a signature through the app: the resolve step and its failure cases ran against the real
  files served in-process, and the app and a VM were not started.
- **Key lifetime.** Key expiry, key flags and revocation were not parsed from the keys' self-signatures; a pinned verifier cannot
  see them. The Fedora key file also holds the 43, 45 and 46 keys, which are not pinned because no signature from them was
  available to check.
- **Other releases and vendors.** Only Ubuntu 26.04, Fedora 44, Debian's current netinst and Alpine 3.24.2 were seen. AlmaLinux
  and Rocky Linux signatures and keys were not examined.
- **Security.framework's padding check.** The verifier relies on `SecKeyVerifySignature` to check PKCS#1 v1.5 padding
  strictly; that was tested with wrong digests and altered signatures, not by reading its source.
- **EdDSA.** The "digest as message" rule for EdDSA is from memory; the verifier does not support it.
- Several mirrors of the documentation were unreachable, so one Fedora mirror was used.
