# REVIEWED-I — pre-dispatch review of chain I (provisioning library)

Reviewer: sonnet. Base `main` at `a9ae6d0`. Method: a scratch worktree (detached, under /tmp, removed afterwards), the nine
cards applied in order exactly as written (code and tests extracted from the card text), `swift-format`, `swift build`,
`swift test --filter`, SwiftLint `--strict` on the new files, the analyzers after every card (later cards' files moved aside),
and finally `swift run vmr check` (8/8 PASS, twice: before and after the last card edits) and `swift run vmr check coverage`
(logic-layer line coverage 91.4 %, floor 55 %). The main repository and its `.build` were not touched. Test counts after
each card match INDEX-I: 3, 12, 18, 25, 33, 40, 45, 48.

## Verdicts

| Card | Verdict | Edits |
|---|---|---|
| I01 | ready | 0 |
| I02 | ready after the edit listed | 1 |
| I03 | ready after the edits listed | 2 |
| I04 | ready after the edit listed | 1 |
| I05 | ready (one owner decision to settle first: see "Owner decisions", item A) | 0 |
| I06 | ready after the edits listed | 2 |
| I07 | ready after the wording edit listed (layout verified, see below) | 1 |
| I08 | ready | 0 |
| I09 | ready after the edits listed | 3 |
| INDEX-I | wording only | 1 |

Eleven edits in total, in seven files (INDEX-I.md, I02, I03, I04, I06, I07, I09).

## Edits made to the card files

1. **I02** (code, `SpecNode`): `case list([SpecNode], line: Int)` became `case list([Self], line: Int)`. As written, SwiftLint
   (`--strict`, rule `prefer_self_in_static_references`) fails on that line, so the gate's `swiftlint` step would have stopped
   the executor. Compiles and passes with `[Self]`; behaviour unchanged.
2. **I03** (code, `environment`): the control-character guard `$0.value < 0x20 || $0.value == 0x7F` was too narrow. Measured
   with a YAML 1.1 reader (Ruby's Psych, which folds the same way cloud-init's PyYAML does): a U+0085 inside an `env` value
   was folded to a space in the `bootcmd`/`runcmd` form but kept in the per-boot form, so the same value reached the guest
   differently by phase. PyYAML also rejects U+0080 to U+009F, U+FFFE and U+FFFF outright, which would make cloud-init drop the
   whole cloud-config. The guard now calls a new `private static func isControlOrLineBreak(_:)` (below 0x20, 0x7F to 0x9F,
   0x2028, 0x2029, 0xFFFE, 0xFFFF). Not an injection (quotes held), a fidelity and fail-late defect.
3. **I03** (tests and command): two refusal cases added to `specRefusals` (`a\u{85}b`, `a\u{2028}b`, line 9, "one line"), and
   the command-3 count "29 cases" became "31 cases".
4. **I04** (code comment): the card said the swap-between-check-and-read limit was "stated in the code"; it was not. The doc
   comment of `ScriptFiles` now says that a file swapped for a link after the type check is not refused as a link, but only
   bytes matching the digest are returned.
5. **I06** (code, `partType`): `hasPrefix("#cloud-config")` also matched `#cloud-config-archive` and `#cloud-config-jsonp`, which
   cloud-init treats as other part kinds; in the merged form the part would be mislabelled `text/cloud-config` and fail at boot.
   Now refused with the same message unless the character after `#cloud-config` is not `-`.
6. **I06** (test): `userDataOfAnotherKindIsRefusedWithItsLine` gains a `#cloud-config-archive` case (line 7).
7. **I07** (wording): "two runs differ in 8 bytes" became "in a few bytes": re-measured here, two `hdiutil makehybrid` runs two
   seconds apart differ in 12 bytes (dates), so the count depends on timing.
8. **I09** (diary table): claim 3 "29 refusal cases" became "31" (after edit 3).
9. **I09** (diary table): claim 10 "8 bytes" became "a few bytes" (same measurement as 7).
10. **I09** (diary, "Not verified"): the `/run` bullet now says an image may mount `/run` with `noexec`, in which case the unpacked
    script cannot be started from there (see item A).
11. **INDEX-I** (decision 5): "8 bytes of dates" became "a few bytes of dates".

## Per card

**I01.** Anchors match (`GuestConsoleTests` line, `testBundles`, the two `ModuleBoundaryTests` anchors). Builds, 3 tests, the
manifest test and the third directory argument pass. The coverage `ignoreRegex` contains `Provisioner`, which does not match
`Provisioning`, so the new target is measured. The build uses `InternalImportsByDefault` and `MemberImportVisibility`, which
matters for later cards (I04 and I08 correctly use `package import Foundation`). No issue.

**I02 (high risk, verified independently).** Compiles; 9 tests, 30 cases pass. Beyond the card's tests I ran about 70 probes and
150 000 random documents (no trap, no hang, every refusal line within the document, every refusal but the size and empty ones
carries a line). Confirmed: tabs refused in indentation, comments and blank lines but kept in `|` text (a tab-only line inside a
block ends the block and is then refused: acceptable); block end condition (a shallower comment line ends the block; a line
between the key's and the body's indentation gives "unexpected indentation" at its line); `- key: |` blocks take their indent
from the re-read map column, with the line of the dash; `- k: v` rewrite handles `-   a:` (gap 3), mismatched continuation
columns and a list at the key's column; duplicate keys per map (not across items), a second key in a list item map; anchors,
aliases, tags, flow in value, item and root position, folded and keep blocks, `|2`, `|foo`, directives, `---`/`...` (also with
trailing text), BOM and CR anywhere (line counted correctly, also late in the document), quoted keys, `<<`, merge keys, plain
values holding `: `, trailing `:`, `x#y`, URLs, empty quoted values. Limits at their boundaries with the standard values:
65 536 bytes read, 65 537 refused (also in multi-byte text, where bytes are counted); depth 8 read, 9 refused, with maps and
with lists. Observations, none blocking: a key may be `-` or `---` (harmless); NUL and other control characters are accepted in
scalars (I03 refuses them in `env` values; `userData` is passed through by design); the duplicate-key check is quadratic (7 346
keys in 65 000 bytes took 2 s in a debug build; a `Set` would fix it; not a defect at the limits the model applies later).

**I03.** Compiles; 6 tests, 31 cases (after the edit). Every replacement occurs once in the base spec and names the stated line.
The secret entry is pinned by a `Mirror` test. `ready` and `pre-shutdown` are accepted by the model and refused by the compiler
(I05), as documented. File paths: ASCII letters, digits, `.`, `_`, `-`, `/`, no empty, `.` or `..` part, 255 bytes.

**I04 (SHA-256 host check, tried to break it).** Compiles; 7 tests; the fixture digest equals `shasum -a 256`. Probed: a FIFO
(refused as not regular, no blocking), a 4 GB sparse file (refused after reading 64 KiB + 1), an empty file with the empty-file
digest (accepted), a symlinked spec folder (accepted: only the file and the path below the folder are checked), a symlink as the
file, a symlinked folder on the way, a directory, a missing file: all as designed under `/var` -> `/private/var`. Fail-closed:
every `try?` falls to a refusal. TOCTOU: the bytes returned are the bytes hashed (one read, hashed from memory, stored in
`VerifiedScripts`), so a swap after the type check cannot change what is packed; a link swapped in is followed by the open but
the digest still decides. Residual (not an edit): `VerifiedScripts` is keyed by path only and I05 does not compare the step's
digest with the stored one, so passing the scripts of one spec with the steps of another that names the same path would pack
bytes checked against a different digest. Only reachable by misusing the internal compile function; storing the digest next to the
bytes and comparing in `contents(of:)` is a cheap hardening for the attach chain.

**I05 (injection tried).** Compiles; 8 tests; golden matches; decoded script matches. There is no step name field: the only
text that reaches the cloud-config besides base64 is `env` names (validated `[A-Za-z_][A-Za-z0-9_]*`, ASCII) and values
(shell-quoted, then YAML single-quoted). I compiled `env` values containing `'`, `''`, `'''`, `"`, `$(...)`, backticks, `;`,
`&&`, `|`, backslashes, `]`, `', '/bin/touch', '...', '`, `# x`, `-n`, leading/trailing spaces and empty, for all three phases,
parsed the output with a YAML 1.1 reader, ran each `sh -c` command and the decoded per-boot wrapper (paths redirected): every
value arrived verbatim, nothing executed, the YAML sequence kept its three items. Only the characters in edit 2 misbehaved. Secrets:
every phase goes through `command(for:)`, which refuses any `secretRef` and `user: user`; installer phases refused before it.
Two minor notes: `metaData(name:instanceID:)` does not re-validate `name` (always the model's DNS label today; cheap to check
there too); the shell command carries the whole base64 script plus the env values, so a 64 KiB script plus some 40 KiB of
values would pass Linux's 128 KiB single-argument cap and fail at run time (no limit sums them).

**I06.** Compiles; 7 tests; the golden multi-part parses with Python's `email` into two `text/cloud-config` parts with the
`Merge-Type` on the second. After edit 5/6: still 7 tests. `compile` is the only maker of `CloudInitSeed` (memberwise init is
internal) and the Mirror test pins its fields to text.

**I07 (high risk, verified independently).** Compiles; 5 tests; the golden digest `2c9a3db4...02e8` matches an image built by
the code. Checked against ECMA-119 with a separate parser I wrote (both-endian fields must agree, record lengths even, sorted
records, extents inside the image): volume descriptors at sectors 16 (type 1) and 17 (type 2, escape `%/E`), terminator at 18;
identifiers `CD001`, version 1; system area zero; system id at 8, volume id at 40 (`CIDATA` / UTF-16 `cidata`), space size at
80, set size 120, sequence 124, block size 128 (2048), path table size 132 (10), L table 140 / M table 148 (next sector),
optional tables 0, root record 156..190 (34 bytes), unspecified dates `0000000000000000\0` at 813/830/847/864, structure version
881; path tables 10 bytes each (L little-endian, M big-endian); root directory with `.` and `..` pointing to itself; directory
record layout (extent 2, size 10, date 18, flags 25, unit/gap 26/27, sequence 28, id length 32, id 33, pad when the id length is
even); files from sector 25, each on its own sector, an empty file shares the next sector with length 0. Determinism: file order
irrelevant, every date fixed, 3 builds equal. Read back with `/usr/bin/tar -tvf`/`-xOf` (names, contents, 4 800-byte file, empty
file, no files at all), `file` (`ISO 9660 CD-ROM filesystem data 'CIDATA'`) and `hdiutil attach -readonly -nobrowse -mountpoint
/tmp/review-x/mnt` (personality `ISO Joliet`, volume name `cidata`, read-only, three files with the right contents), then detached
(no image left attached). Deviations from strict ISO 9660 that no tool here objects to, to confirm in a guest: primary identifiers
contain `-` (not a d-character) and carry no `;1`; the unused 37-byte file-identifier fields of the Joliet descriptor are a flat
run of UTF-16 spaces (alignment off after the first). Linux reads the Joliet names, so this should not matter; it is the first
thing to check if a distribution's kernel lacks Joliet.

**I08.** Compiles; 3 tests; the final total is 48. `.atomic` replaces a read-only file; mode 0444 is set after the rename, so the
file is briefly 0644 (no consequence in a private cache folder).

**I09.** Anchors match (ADR paragraph, README layout, CONTRIBUTING bullet); the diary number is `01` (no 2026-10-23 file exists on
`main`). `vmr check docs` passes (110 files), `vmr check coverage` passes. Cosmetic: the new README layout line puts one space
after `Sources/Provisioning`, one column further than the aligned lines above it (the name is longer than the column); the card's
anchor lines cannot be re-aligned without touching other lines, so left as is. The policy step prints "no origin/main to compare
with" in a scratch worktree, so it was not exercised; nothing in the chain touches a baseline, the coverage floor or
`.swiftlint.yml`, so it should pass.

## Standing rules

- No outside project name beyond what the repository already cites (KubeVirt, cloud-init, Lima-style, Ignition, k3s and kubectl
  are all in the study or ADR). The tests use `k3s`/`kubectl` as sample text only. No board or card id in code, docs, comments
  or commit messages (the diary says "the chain ran in a worktree", no id).
- macOS API use: nothing newer than macOS 15; the one gated stdlib call is `count(where:)` (macOS 15). The package says
  `.macOS(.v26)`.
- Strict memory safety: no `unsafe` needed anywhere in the card code. Warnings are errors: clean. `type_body_length`: clean.
  Deadwood: every file has the directive on line 3; analyzers pass after every card, and an added unused function is still
  reported (`unused-function`) with the directive present. Dolly reports near-clone advisories in the new files (and a few
  similarity 1.00 regions inside `SpecReader` and `ProvisioningSpec+Reading`); the gate passes, they are advisory.

## Owner decisions needing attention

A. **Decision 8, run path `/run/vmrunner`.** Not verifiable here and the most likely thing to fail in the first guest run: some
   distribution images mount `/run` with `noexec` (to my knowledge Debian and Ubuntu cloud images do), which would make
   `exec /run/vmrunner/step-NNN` fail with "Permission denied". Changing the path means recomputing the goldens of I05 and I06
   (the paths and the base64 of the per-boot wrapper). Decide before dispatching I05 whether to keep `/run/vmrunner` (accepting the
   risk until the guest run) or use a directory on the root filesystem; the cards stay consistent either way only if the goldens
   are recomputed. `Merge-Type` merging and the per-boot folder are likewise unverified.
B. Decision 3 (tabs in `|` blocks) and 4 (flow collections refused, so the study's `{ secretRef: name }` is written as a block):
   confirm before I02, as INDEX says; the tests pin both.
C. Decision 5 (own ISO writer): the writer is verified against `tar`, `hdiutil`, `file` and an independent parser, so the only
   open point is the strict-ISO deviation above.
D. Decision 12/13: `package` access and the macOS floor statement (brief says 15, manifest says 26).
E. Decision 9 limits: no limit bounds the total of script + env values in one command (I05 note).
F. Optional hardening for the attach chain: digest stored next to the bytes in `VerifiedScripts`; name re-validated in `metaData`.
G. The gate installs SwiftLint and actionlint on first run from the network (it did here); a machine without network access
   needs them cached.

## What only an owner or a real-guest run can confirm

- That cloud-init in a Linux guest finds the `cidata` volume as a read-only USB device and reads the Joliet names (and what
  happens on a kernel without Joliet).
- That `bootcmd`, `runcmd` and the per-boot script run, that `/run/vmrunner` is executable (item A), that `base64` exists, and that
  the `Merge-Type` header merges the two parts as documented.
- That the 64 KiB script plus values fits a single argument on every target distribution.
- The policy step (needs `origin/main`) and the coverage step in the integrator's worktree.
