---
date: 2026-10-22
question: "Can the system cryptography frameworks or swift-crypto carry the cryptographic work in the codebase?"
feeds: [ADR-0001, ADR-0023, roadmap 0005, roadmap 0016]
---
# Cryptography: system frameworks or swift-crypto

Study, not a decision record. Facts come from the repository at this date, Apple's CryptoKit documentation index and the
swift-crypto README. Items marked *unverified* were not confirmed.

## Short answer

- **The codebase already does all of its cryptography with Apple frameworks.** Digests are CryptoKit (`SHA256`, `SHA384`,
  `SHA512`, `Insecure.SHA1` for key fingerprints and legacy checksums); RSA signature verification is Security.framework
  (`SecKeyCreateWithData`, `SecKeyVerifySignature` with the PKCS#1 v1.5 digest algorithms). Nothing hand-rolls a hash, a
  cipher or a big-number operation.
- **swift-crypto would add nothing on macOS.** On Apple platforms it "compiles its entire API surface down to nothing and
  simply re-exports the API of CryptoKit". Its `CryptoExtras` product (the part that has what CryptoKit lacks) "bundles the
  BoringSSL/XKCP implementation ... no matter the platform". That is a vendored C crypto library in an app whose ADR-0001
  says it links system frameworks only, and a larger surface than `SecKey`. It exists for Linux and Windows hosts, and this
  product cannot run there because it is built on Virtualization.framework. Recommendation: do not add it.
- **CryptoKit has no RSA.** Its framework index lists hashes (SHA-2, SHA-3), HMAC, AES-GCM, ChaChaPoly, HKDF, ECDSA
  (P-256/384/521), Ed25519, X25519, HPKE, ML-KEM, X-Wing and ML-DSA, and no RSA. Every vendor key pinned for OpenPGP is
  RSA-4096, so `SecKey` stays the verifier for them. A vendor that moves to Ed25519 is covered by
  `Curve25519.Signing.PublicKey` without a new dependency.

## What is still written by hand, and whether a framework could replace it

| Code | What it does | Replaceable? |
|---|---|---|
| `PGP+Armor.swift` `crc24` | The CRC-24 of the armor checksum line. Not cryptographic. | No framework offers it. Keep. |
| `PGP+Armor.swift` `Base64` | A strict, canonical base64 decoder (leftover bits zero, padding only at the end). | Foundation's decoder is lenient. It could decode and the result be re-encoded and compared with the input to get the same strictness in fewer lines; optional simplification. |
| Packet and subpacket parsing, MPI handling | OpenPGP framing. | No system API parses OpenPGP. Keep, with the fuzzing it has. |
| Hex formatting of a digest in `Downloads.swift` and `AnalyzerInstaller.swift` | Two copies of the same `String(radix: 16)` map. | One shared helper over `Digest`; mechanical. |
| `Checksums.digest` SHA-1 and SHA-256 loops | The same chunked read for two algorithms. | A generic over CryptoKit's `HashFunction` merges them (roadmap 0019 already lists this, to be done only if throughput holds; the benchmark gate now measures it). |

## Where the frameworks could carry new work

- **Automation tokens (roadmap 0005).** Per-client capability tokens as HMAC-SHA256 over a client id and capability set with a
  Keychain-held `SymmetricKey`, compared with `HMAC.isValidAuthenticationCode` (constant time). No dependency.
- **Suspended state at rest.** `SavedState.vzvmsave` is the guest's RAM in plaintext (disclosed in the exposure summary);
  FileVault is the only control today. CryptoKit could seal it with AES-GCM in chunks (it has no streaming AEAD, so each chunk
  needs its own nonce and tag) under a random key wrapped by a Secure Enclave P-256 key through `SecKeyCreateEncryptedData`.
  Cost: an extra read-and-write pass over a multi-gigabyte file at every suspend and resume, and a failure mode if the wrapped
  key is lost. Worth a spike before a decision; *throughput on this hardware is unmeasured*.
- **Provisioning secrets (roadmap 0016, ADR-0012).** Secrets sent to a guest agent over vsock could use HPKE (CryptoKit) so a
  bundle copied off the Mac does not carry them in the clear. The vsock channel is local, so this matters only for secrets at
  rest.
- **Not worth it:** encrypting `Disk.img`. It would defeat APFS clones (ADR-0003); FileVault already covers the disk at rest.

## Limits and what was not checked

- The statement that CryptoKit has no RSA rests on its documentation index, not on compiling a probe.
- The swift-crypto README was read; its source was not. Its minimum Swift version is 6.2, which this package satisfies.
- The padding strictness of `SecKeyVerifySignature` is established by this repository's negative tests, not by reading the
  framework's source.
- No timing or throughput figure for chunked AES-GCM on saved state was taken.
