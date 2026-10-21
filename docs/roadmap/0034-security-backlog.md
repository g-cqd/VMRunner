---
status: in-progress
blocked-by: []
date: 2026-10-22
---
# 0034 — Security and hardening backlog from the adversarial reviews

Study: `docs/research/adversarial-review-2026-10.md` (five reviews and one review of the signature code, with the status of
each finding). Fixed or merged: the tooling and CI findings, the configuration and storage findings. In flight: the network
stack findings and the download findings (including the rollback through the unsigned listing).

## Open

1. A per-provider version floor and version binding so an older genuinely signed release cannot be installed (queued).
2. The image's Secure Boot capability is never read: Isolated and Hardened turn Secure Boot on, which Alpine cannot boot.
3. Pins for AlmaLinux, Rocky and each Fedora release; Debian netboot needs the signed archive Release chain; key expiry
   dates per pinned key.
4. Domain deny rules lose effect when the name table expires: derived address blocks; a DNS worker pool instead of a thread
   per lookup; a byte-bounded guest transmit queue.
5. Bounds on `snapshot.json` and on free-text fields of `config.json`; absolute paths for `ImageSource.local`.
6. A coverage-guided fuzz target for the signature, DNS and packet parsers.
7. The cause of the gate-lock test's rare failure is unproven (a retry hides it).
8. `actionlint` and `zizmor` have never run on the workflows; CI has never run on GitHub.
9. Decide whether ADR-0012, 0013, 0016, 0017 and 0019 are accepted.

## Done when

Every item is fixed with a regression test, or recorded with the reason it stays open.
