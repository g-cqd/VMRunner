# REVIEWED-F — pre-dispatch review of F01 to F12 (base a98fd14)

Method: a copy of the repository at a98fd14 under /tmp (deleted), with every card applied in order, one commit per card in the
copy, `swift build --build-tests` after each, the card's tests, then `vmr check` with the steps format, swiftlint, docs,
analyzers (arcleak, dolly, deadwood production mode), and at the end policy, workflows and the whole `swift test` (all suites
passed, one pre-existing known issue). Every quoted old text was matched exactly once; every new block was compared with the
formatted result.

| Card | Verdict |
|---|---|
| F01 | PASS. Compiles under the package flags; `CFGetTypeID` check proven with values read back from `UserDefaults.object(forKey:)`: Boolean false and true give 15, number 0 and 0.0 give nil, 60 gives 60, 60.5 and "0" give 15. 10 tests in `ManagedPreferencesTests` is right. Help, roadmap and ADR wording fine; ADR keeps `status: proposed`; `vmr check docs` passes. |
| F02 | PATCHED. `#expect(workers.submit({...}, late: {...}))` did not compile (non-Sendable parameter inside the macro). Each `submit` result is now taken into a `let` before `#expect`. Then passes, and the second test fails when the deadline check is removed (`["busy ran", "waited ran", "fresh ran"]`). |
| F03 | PASS. Both new tests pass, and both fail with `ttl: .infinity` restored. `package var derivedBlocks` needed and enough. Longest new line 137 columns. |
| F04 | PASS. Test passes; deadwood sees the `AppDelegate` caller; the sweep follows no link. |
| F05 | PASS. `GateLockTests` 5, `DNSWireMutationTests` 2, `PGPKeyExpiryTests` 3. The 1,171 figure reproduced (1171 of 20,000), so `> 500` holds. |
| F06 | PASS. Comments and ADR text only; no code line moved; ADR front matter unchanged. |
| F07 | PATCHED. The 0555 test fails when run as root (removal succeeds): it now carries `.disabled(if: geteuid() == 0, ...)` and the stop condition names a volume that ignores modes. Passes as a normal user. |
| F08 | PATCHED. `#expect(cable.set(...))` on a `var` (mutating call) did not compile: results taken into `let`s. The source side (`extension VZNetworkDevice: NetworkCard`, the weak `Task`) compiles in the module; arcleak and deadwood clean; the stop notice text matches `MachineState`. |
| F09 | PASS. `VMLibrary` body not longer; the new test passes; the secure-boot and unchanged-settings tests still pass. |
| F10 | PASS. `@ViewBuilder` lock compiles at all call sites; serial filter test passes (`\n` and `é` dropped). |
| F11 | PASS. The count is real: `git log ad16e56..a98fd14` prints 18. |
| F12 | PASS. The roadmap anchors are unique; the diary command printed `docs/diary/2026-10-22-06.md` and `# Diary — 2026-10-22 (6)`; on another date it gives `-01` and `(1)`, which the docs rule accepts. `main..HEAD` is exactly 11 after F01 to F11 (my copy showed 12 only because of a non-card commit of mine). Board-id grep prints nothing; `vmr check docs` passes. |

Cards still risky: none to hold. Closest to the edge: F08 (about 100 lines, framework behaviour only checked with a fake) and F02
(threads and a semaphore, deterministic but the real contention is owner run O5).

Owner decisions (defaults implemented):
1. `MaxRuntimeMinutes` forced to 0 is no limit (decided by the owner); Boolean false stays 15; 1 to 14, negatives, more than 1440 and strings are 15; ADR-0013 stays proposed.
2. F08: a cut that does not take stops the machine (fail closed), pending the owner.
3. F04: sweep at launch, not at the start of a setup.
4. F03: derived blocks live 12 hours after the proxy last gave the address.

Cards that need an owner run (real guest or hardware, never haiku): F01 and F10 (O1, real profile and form layout), F08 (O2), F04
(O3), F07 and F09 (O4), F02 (O5, optional).
