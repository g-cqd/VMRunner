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
2. *Fixed.* The image's Secure Boot capability was never read: Isolated and Hardened turned Secure Boot on, which Alpine cannot
   boot. Setup now records the catalog image's capability in the machine (`imageSupportsSecureBoot`); a profile never turns
   Secure Boot on for an image that cannot use it, and the editor and the exposure summary say so.
3. *Fixed, except Debian netboot.* AlmaLinux 10, Rocky Linux 10 and Fedora 43 and 44 are signed providers with pinned keys
   (ADR-0054); every pinned key records its expiry, the verifier refuses a key from that second, and a test fails 90 days
   ahead. The Debian netboot chain (the archive's signed `InRelease`, which carries several signatures, one by a subkey) waits
   for the owner's decision.
4. *Fixed, except the floor opt-in.* A block rule for a name on some ports keeps holding for the addresses DNS gave the guest
   after the name table forgets them (derived address blocks); lookups run on at most 32 resolver threads that take queued
   lookups in turn; the guest transmit queue is bounded in bytes (8 MiB) as well as frames; a DNS-over-TCP answer that finds
   the guest's buffer full resets the session and is counted; repeated DNS answers are folded into one event with a count. An
   opt-in to lift one kind of the floor (ADR-0029) is not built: ADR-0029 left it out on purpose, and the owner decides
   whether a guest ever needs it.
5. *Fixed.* Bounds on `snapshot.json` (64 KiB, refused before it is parsed) and on the free-text fields and lists of
   `config.json` (`EditorLimits`: names, paths, counts, rule length), enforced when the file is read and in the editor;
   `ImageSource.local` must name an absolute path, at decode and in the file picker.
6. *Partly fixed.* Seeded, deterministic mutation tests run in the gate for the signature parsers (`PGPFuzzTests`), every
   frame type (`UserNetRobustnessTests`), resolver results (`UserNetDNSFuzzTests`) and the guest's DNS queries and the
   resolver's record data (`DNSWireMutationTests`). Coverage-guided fuzzing needs the compiler's fuzzing runtime, which the
   Xcode toolchain the gate and CI use does not ship (the open-source Swift toolchain does); a separate job on that
   toolchain is the owner's decision.
7. *Fixed.* The gate lock's `flock` belongs to the open file, so a concurrent spawn that still held a copy of its descriptor
   most likely kept the lock after `close`; the lock is now released explicitly, a test shows the mechanism with real system calls, and
   the retry is gone (30 runs of the DevTools suite under load passed). The ThreadSanitizer abort seen once did not recur in two runs of the tsan step; it
   stays unexplained and is watched.
8. `actionlint` and `zizmor` have never run on the workflows; CI has never run on GitHub.
9. Decide whether ADR-0012, 0013, 0016, 0017 and 0019 are accepted.

## Done when

Every item is fixed with a regression test, or recorded with the reason it stays open.
