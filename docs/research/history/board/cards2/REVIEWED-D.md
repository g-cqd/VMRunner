# REVIEWED-D — pre-dispatch review of cards D01 to D22 (base main 73bceb0)

Read-only check against the real code; no build, no test. Chain-E conflict marks stay (D09, D12, D16, D17, D18, D21).

- D01: PATCHED. Why text says "likely reason" (mechanism proven by the dup/flock test, cause of the flake not). Anchors and test count (5) verified.
- D02: PATCHED. `grep -c` printing `0` with exit 1 is stated as expected.
- D03: PASS. Expiry check is `now >= expires`, fails closed; both new fields have production uses.
- D04: PASS. Key, fixture and fingerprint verified (gpg, vendor pages live); no deadwood accept needed.
- D05: PATCHED. Two Rocky resolve tests removed (download.rockylinux.org is refused by DownloadPolicy until D07); command now expects 1 test. Moved to D07.
- D06: PATCHED. Fedora 44 key test now asserts `signatureRejected` with reason "not pinned for this download".
- D07: PATCHED. Step 6 appended: `RockyLinuxResolveTests` (4 tests); file list, format command and filters updated; count corrected to 4.
- D08: PASS. ADR-0054 shape, numbers 0054/0055 free (highest on main 0053).
- D09: PASS.
- D10: PATCHED. `summaryLine` entry on its own line (was ~150 columns).
- D11: PASS.
- D12: PASS.
- D13: PASS. `Mutex` is `@unchecked Sendable where Value: ~Copyable` in the SDK interface; `final class ResolverWorkers: Sendable` compiles.
- D14: PASS.
- D15: PASS. About 20% of mutants parse (about 4,000 of 20,000), 500 is a safe seeded threshold.
- D16: PASS. "Basis of this reading" paragraph added (install reads its own clone; ADR-0031 rule for Linux installers).
- D17: PASS with wording fix ("approved too", not "in place of").
- D18: PATCHED. `<<TSAN>>` explanation deleted at dispatch; wording follows D01; reword for skipped cards.
- D19: PASS; ADR-0055 gained a freshness-replay consequence (no InRelease freshness check; floor 13.7).
- D20: PATCHED. Ambiguous anchor named precisely; refusal tests assert reasons; fifth test for an expired pinned key. Subkey B8E5F131...2265 decoded and matches, expiry 2035-03-28.
- D21: PASS.
- D22: PATCHED. Integrator fills `<<DATE>>`, `<<NN>>`, `<<N>>`; Placeholders list deleted; claims 1, 5, 6 reworded.
