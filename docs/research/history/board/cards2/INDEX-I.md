# Chain I: provisioning, first step — a library, no user-visible feature (9 cards, one branch, sequential)

Roadmap 0016, ADR-0012. Branch `chain/i-provisioning` from `main` at `a9ae6d0`, one long-lived worktree, created by the
integrator (never by a card):

```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/i-provisioning -b chain/i-provisioning a9ae6d0
```

`WT = ~/Developer/g-cqd/VMRunner-chains/i-provisioning`. Haiku (effort low) does each card; sonnet
(effort medium) reviews every card before dispatch and the chain's diff before the merge; opus merges after the gate.
One build at a time: the cards run strictly in order in the one worktree.

## Order, dependencies and files

| Card | Scope | Depends on | Files | Size | Risk |
|---|---|---|---|---|---|
| I01 | The `Provisioning` library target and `ProvisioningTests`, `ProvisioningLimits`, `ProvisioningError`; the layering test covers the new target; the coverage bundles list it | — | `Package.swift`, `.vmr.json`, `Sources/Provisioning/ProvisioningLimits.swift`, `Tests/ProvisioningTests/ProvisioningLimitsTests.swift`, `Tests/DevToolsTests/ModuleBoundaryTests.swift` | ~90 | medium (first build of a new target; the deadwood directive) |
| I02 | The strict YAML-subset reader with line-numbered refusals; spec-size and depth limits | I01 | `Sources/Provisioning/SpecReader.swift`, `Tests/ProvisioningTests/SpecReaderTests.swift` | ~390 | **high** |
| I03 | The spec model (envelope, `cloudInit` pass-through, steps, `env` values apart from `secretRef`) read from the tree; step limit | I02 | `Sources/Provisioning/ProvisioningSpec.swift`, `Sources/Provisioning/ProvisioningSpec+Reading.swift`, `Tests/ProvisioningTests/ProvisioningSpecTests.swift` | ~370 | medium |
| I04 | The host's SHA-256 check of every `file:` script, fail-closed, bounded read; `VerifiedScripts`; file-size limit | I03 | `Sources/Provisioning/ScriptFiles.swift`, `Tests/ProvisioningTests/ScratchFolder.swift`, `Tests/ProvisioningTests/ScriptFilesTests.swift` | ~180 | medium (symbolic-link and `/private` path handling) |
| I05 | Steps to a deterministic cloud-config (`bootcmd`, `runcmd`, per-boot file) and `meta-data`; refusals of what cannot run yet | I04 | `Sources/Provisioning/SeedCompiler.swift`, `Tests/ProvisioningTests/SeedCompilerTests.swift` | ~230 | medium (golden) |
| I06 | `CloudInitSeed` and `SeedCompiler.compile`: pass-through `userData`, MIME multi-part merge, `network-config`; the seed's fields are text only | I05 | `Sources/Provisioning/CloudInitSeed.swift`, `Tests/ProvisioningTests/CloudInitSeedTests.swift` | ~180 | medium (golden) |
| I07 | The in-memory ISO 9660 + Joliet writer, reproducible to the byte, cross-checked with the system's `tar` and a golden digest | I06 (order only) | `Sources/Provisioning/ISOImage.swift`, `Tests/ProvisioningTests/ISOImageTests.swift` | ~200 | **high** |
| I08 | `SeedImage`: the `cidata` volume from a `CloudInitSeed`, written read-only (0444); end-to-end spec to image file | I07 | `Sources/Provisioning/SeedImage.swift`, `Tests/ProvisioningTests/SeedImageTests.swift` | ~110 | low |
| I09 | Roadmap 0016 (in-progress, dated "Built so far", "Remaining"), ADR-0012 dated note (stays `proposed`), README layout, CONTRIBUTING code rule, diary `2026-10-23-NN` | I08 | `docs/roadmap/0016-provisioning.md`, `docs/adr/0012-provisioning-starts-with-a-cloud-init-seed.md`, `README.md`, `CONTRIBUTING.md`, `docs/diary/2026-10-23-NN.md` | ~110 | low |

Expected test counts in `ProvisioningTests` after each card: 3, 12, 18, 25, 33, 40, 45, 48 (Swift Testing counts a
parametrized test once).

## Rules for chain I (they override `cards/COMMON.md` where they differ)

- **Base.** `main` at `a9ae6d0`, not COMMON's `73bceb0`.
- **Never touch** stays as in COMMON, except: I01 edits `Package.swift` (two targets added, nothing else) and `.vmr.json`
  (`coverage.testBundles` only). No card edits `.swiftlint.yml`, `.deadwood.json`, `.dolly.json`, a baseline or the
  `platforms` line.
- **Standing owner rules**, repeated in every card: no outside project named in prose, docs, comments or commit messages
  ("the shared utility library" and the like; the formats and tools the repository already cites, such as cloud-init,
  KubeVirt's field names, ISO 9660 and `hdiutil`, are not the owner's projects and may be named as ADR-0012 and the study
  do); no distribution plans; every commit atomic, signed, building, `swift run vmr check` 8/8; macOS 15 API floor; Swift
  6.4 strict memory safety (no card needs `unsafe`); warnings are errors; SwiftLint `type_body_length` 300; Swift Testing;
  no board or card ids in code, docs, comments or commit messages.
- **Dead code.** Every file under `Sources/Provisioning` starts with the two comment lines and the directive
  `// @dw:disable referenced-only-by-tests` (measured with the pinned analyzer on a scratch corpus: the directive silences
  that rule for the rest of the file and nothing else; an unused function in the region is still reported as
  `unused-function`). No `@dw:accept`, no baseline change. The change that links the library removes the directives.
- **Compile errors.** The cards' code was written without a compiler. A compile, SwiftLint or swift-format finding is
  fixed minimally on the reported line, without changing behaviour, an output byte, a message or a test's meaning, and the
  report says what changed. A failing test is never edited: the executor stops and reports.
- **Golden values** (I05, I06, I07) and fixture digests (I03 to I05) were computed outside the code, with a separate model
  of the rules (scratch Python, deleted) and `shasum`/`base64`; the ISO model's image was read back correctly by
  `/usr/bin/tar` (bsdtar 3.5.3) and identified by `file` as `ISO 9660 CD-ROM filesystem data 'CIDATA'`.
- **`ProvisioningTests` needs no registration** beyond `Package.swift`: the gate's `test` step runs every test target, the
  `docs` step does not look at sources, SwiftLint, swift-format and the analyzers cover `Sources` and `Tests` already.
  Coverage (`--full` only) measures the bundles `.vmr.json` lists, hence I01's change; the floor stays 55.

## No help topic, no posture line, in this chain

Nothing user-visible ships: the app does not link the library, no machine gets a seed, no editor shows a spec, so there is
no feature for a help topic to describe and nothing new a guest can reach (the white paper bans a feature without its help
topic, not a library). The next provisioning chain ships them together with the first use: it attaches the seed as a
read-only USB mass storage device, adds the editor section with its help topic marked experimental, adds the seed to the
exposure summary ("what can the guest reach"), removes the `@dw:disable` directives, and runs an owner-authorised real-guest
run with a cloud image before the help says anything works.

## Owner decisions (each with the default the cards use)

1. **Target name** `Provisioning` (ADR-0042: a capability; its main type is `ProvisioningSpec`, not the module's name).
   It sits beside the app's unrelated `Provisioner` (machine setup). Alternative: `GuestSeed`.
2. **Input format:** a strict YAML subset read by the library (no dependency), exactly as I02's doc comment lists.
   Alternative: JSON only (Foundation, but no line numbers and silent duplicate keys).
3. **Tabs** are allowed inside a `|` block's text (scripts and heredocs use them) and refused everywhere else.
   Alternative: refuse every tab.
4. **Flow collections are refused**, including `{ secretRef: name }` from the study's example: the block form is required.
5. **Seed image:** the in-library ISO 9660 + Joliet writer, not `hdiutil makehybrid` (measured: works, 0.05 s, but two runs
   differ in a few bytes of dates, and it would be the app's first subprocess). Alternative: `hdiutil` through `Process` with a
   scratch folder, tests skipped without it.
6. **Dead-code directive** per file until a target links the library. Alternatives: a developer `vmr` command as a
   production caller now (scope growth), or a `@dw:accept:this` per declaration.
7. **Fail closed:** the compiler refuses installer phases, `ready`, `pre-shutdown`, `user: user` and any `secretRef`
   rather than dropping them; KubeVirt's `secretRef` and `networkDataSecretRef` are refused because a seed is readable in the
   guest.
8. **Script shape:** every script starts with `#!`; scripts travel base64 in the cloud-config and run from `/var/lib/cloud/vmrunner`
   (owner decision after review: not `/run`, which Debian and Ubuntu mount `noexec`; persistent, allows running files, exists in
   cloud-init images);
   `every-boot` uses cloud-init's per-boot folder; with the user's own `userData` the seed is a MIME multi-part document with
   `Merge-Type: list(append)+dict(no_replace,recurse_list)+str()`. The script folder and the merge are unverified in a guest.
9. **Limits:** 64 KiB spec, 32 steps, 64 KiB per script file (base64 fits Linux's 128 KiB per-argument cap), depth 8.
10. **Instance identifier:** an input of the compiler; the attach chain chooses it (the machine's identifier by default).
11. **Coverage:** `ProvisioningTests` joins `coverage.testBundles`.
12. **Access level:** `package` (ADR-0047's rule), although `GuestConsole` uses `public`.
13. **The macOS floor:** the brief says macOS 15, `Package.swift` says `.macOS(.v26)`. The chain changes nothing there and
    uses nothing newer than macOS 15; the owner says which statement is current.

## Owner-run list

- Confirm or overturn the decisions above (before I02 for 2 to 4, before I05 for 7 and 8, before I07 for 5).
- No real-guest run belongs to this chain: nothing attaches a seed. The first one belongs to the next provisioning chain.
- After the merge, the integrator removes the worktree and the branch (CONTRIBUTING, "Worktrees and cleanup").

## Review focus (sonnet, before dispatch)

Hardest: **I02** (the reader: line accounting of the list-item rewrite, `literalBlock`'s end condition, each refusal case's
line) and **I07** (byte offsets of the descriptors against ECMA-119, the golden digest's input order). Next: I03's refusal
table (each replacement occurs once in the base spec and names the line stated), and I04's symbolic-link check under
`/var` -> `/private/var`.
