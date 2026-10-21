---
date: 2026-10-22
question: "How can the app, the codebase and the project be attacked, and what has been done about each finding?"
feeds: [roadmap 0034, ADR-0006, ADR-0015]
---
# Adversarial reviews, October 2026

Study, not a decision record. Five read-only reviews and one review of the signature code, each acting as an attacker. Nothing
was executed against a running app or guest; confirmed means the code path is unambiguous or was reproduced in a test.
Status is at the date above; roadmap 0034 tracks what is open.

## Network stack and policy (attacker: a malicious guest)

| Finding | Severity | Status |
|---|---|---|
| A DNS answer over 64 KiB aborts the host app (narrowing conversion in the TCP framing and record count) | high | in flight |
| The DNS proxy resolves any name and record type in every mode and discloses the host's private zones | high | in flight |
| One switch (`blockPrivateRanges`) is all that stops loopback, link-local and metadata access | medium | in flight |
| Denial events and log lines are unthrottled | medium | in flight |
| Per-datagram socket churn and linear eviction at capacity; quadratic DNS-over-TCP inbox | medium | in flight |
| Resolver answers trusted for names; query name not re-checked after a policy change | medium | in flight |
| DHCP is served before the source check | low | in flight |
| Domain deny rules lapse when the name table expires; a thread per lookup; unbounded transmit queue | low | open |

Held up: bounds-safe parsers, no stored byte views, spoofing and fragments, on-link isolation, no rebinding window, spelling
tricks, deny-beats-allow, flow-token hygiene, policy-change ordering, bounded tables.

## Configuration, storage, profiles (attackers: a copied bundle, a guest, a local process)

Fixed and merged: the installer image was a host-file channel invisible to the profile, posture and exposure summary; host
paths in a copied config were honoured without consent (now approvals kept outside the bundle); `--start` resolved duplicate
names arbitrarily; malformed numbers, huge files and deep nesting crashed or exhausted; the saved memory image outlived the
promise that none is written; snapshot identity came from file content; bundle files were world-readable behind a private
folder; host paths were logged publicly; a prefix check deleted a user's file outside the cache.

## Downloads and installers (attacker: a compromised mirror, catalog or network)

In flight: the catalog was trusted for both location and hash under suffix-wide host rules; the installer was attached from a
shared mutable cache after being verified once; no size cap on large downloads; listing parsing on the main actor; resume state
keyed by file name; non-ASCII lookalikes and canonical equivalence in name matching; help text claimed more than the code checks.

## Tooling and supply chain (attacker: a malicious contributor)

Fixed and merged: an executable committed under `.tools/` was trusted and run by the gate; entitlement verification compared a
signature with the file it was signed from; the code-owners file and bundle identifier were placeholders a release could ship;
documents misstated the app's dependencies; the release checksum travelled with the artifact and attestation was skipped on
private repositories; lock values were unvalidated; the gate could be relaxed without a word (now a policy step). Also fixed: a
workflow condition used a context property that does not exist (`github.repository_visibility`), so the public-only workflows
would never have run.

## Memory safety, concurrency, hardening

ADR-0011 holds for the app: `unsafe` is confined to a few audited files. The signed build carries only the two intended
entitlements. The DNS framing abort and the loopback exposure were found here as well.

## The signature code (review of the new verifier)

Held up: type confusion, text before or after the signed block, verified-versus-parsed bytes, hash header agreement, fail-closed
paths, key identity, RSA encoding, parser robustness. Found: an older genuinely signed release can be installed because the
unsigned listing chooses the file and nothing binds it to the provider's release or a floor (queued); the RSA exponent is not
required to be 65537; several tests assert only that something throws.

## Not verified

No finding was run against a live app or guest. The framework's PKCS#1 padding strictness is established by negative tests,
not by reading its source. Key expiry and revocation are not modelled.
