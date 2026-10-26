# CHECKLIST-D — What the sonnet reviewer verifies before each card of chain D is dispatched

Effort `medium`. Read-only, except the scratch work of item 6 under `/tmp`. Never build or test in the main checkout; the
gate runs in WT, by the executor. Record, per card, "pass" or the finding and the fix you propose; do not edit the card yourself
unless the integrator asks.

## For every card

1. **Base.** `git -C ~/Developer/g-cqd/VMRunner log -1 --format=%h main` prints `73bceb0`, or every anchor
   of the card is re-checked on the current `main` and on WT after the previous card (item 13). Every "replace" or "after the
   line" text must exist exactly once in the file the card names, unless the card says it occurs twice (D04 and D05 trust
   notes). Texts that an earlier card of the chain wrote are checked on WT after that card, not on `main`.
2. **Locked worktrees.** No file of the card appears in `git diff --name-only main...<branch>` of a locked worktree
   (`git worktree list`); otherwise mark the card CONFLICT-RISK and hold it.
3. **Names exist.** Every type, function and helper the card calls exists (`grep -rn`). Every `--filter` value is a suite
   name (`grep -rn "struct <Name>" Tests`, including nested ones such as `UserNetBootTests` and `UserNetThroughputTests`), so
   no filter silently runs zero tests. Known correct names: `HelpCatalogTests` (not `HelpTests`), `DownloadSizeLimitTests`,
   `UserNetDNSQuestionPolicyTests`, `UserNetDNSAnswerPolicyTests`, `UserNetTCPHandshakeTests`, `AddressJudgementTests`,
   `HostBypassTests`, `PGPClearSignedTests`, `LibraryLoadTests`.
4. **Compiles as written.** Look for, in the card's code: `try` to the right of a binary operator (not allowed); a value
   returned from a closure in `#expect(throws:)` (fine); memberwise initializers of `PinnedKey` (D03 inserts `expires` after
   `created`, so later pins that pass it must pass it in that position: D20 does); typed-throws closures in
   `ByteView.withBytes(of:_:)` (`{ view throws(PacketError) in ... }`); `Mutex` holding closures (D13); `unsafe open(...)`
   under strict memory safety (D01, same form as `GateLock.swift`); file-scope test declarations are `private` (swift-format's
   `FileScopedDeclarationPrivacy`).
5. **Expected output is concrete.** Each command has an exit status, a `PASS` line, a count or exact text.
6. **Pinned data (D04, D05, D06, D20), network, read-only, under `/tmp`:**
   - Fingerprints on the vendors' own pages: `https://almalinux.org/security/` and
     `https://wiki.almalinux.org/release-notes/10.0.html` (`EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572`);
     `https://rockylinux.org/keys` (`FC226859C0860BF0DDB95B085B106C736FEDFC85`); `https://fedoraproject.org/security/`
     (`C6E7F081CF80E13146676E88829B606631645531`); `https://ftp-master.debian.org/keys.html` (primary
     `04B54C3CDCA79751B16BC6B5225629DF75B188BD`; the subkey `B8E5F13176D2A7A75220028078DBA3BC47EF2265` is bound in
     `fixtures/raw/debian-archive-key-13.asc`).
   - Signatures, offline, with a throwaway keyring: `gpg --homedir /tmp/d-review --import fixtures/raw/RPM-GPG-KEY-*`
     `fixtures/raw/debian-archive-key-13.asc`, then `gpg --homedir /tmp/d-review --verify` on
     `fixtures/raw/almalinux-10-aarch64-CHECKSUM`, `fixtures/raw/Fedora-Server-43-1.6-aarch64-CHECKSUM`,
     `fixtures/raw/rocky-10-aarch64-CHECKSUM.asc fixtures/raw/rocky-10-aarch64-CHECKSUM` and
     `fixtures/raw/debian-stable-InRelease-2026-10-22`: each says `Good signature` (InRelease also says it cannot check two
     other signatures; that is expected). Delete `/tmp/d-review` afterwards.
   - The constants in the card match the key files: modulus, `created` and fingerprint (any OpenPGP packet dump will do).
   - The Swift fixture in `fixtures/SignedVendorFiles+AlmaRockyFedora.D0N.swift` decodes to the raw files byte for byte
     (a multi-line literal indented by 8 spaces, with an empty last line so the value ends in a line break).
7. **Limits.** Lines of Swift at most 140 columns (SwiftLint is `strict`, so warnings fail); a test or source file stays under
   500 lines (`file_length` warning), a type body under 300 counted lines (`type_body_length`); `VMLibrary`'s class body is
   about 283, so D17 must put its code in a same-file extension. Numeric literals of five digits or more are grouped
   (`GroupNumericLiterals`). No `count == 0` (`empty_count`), no `== []` or `== ""` comparisons.
8. **Dead code.** Every new production symbol has a production caller in the same card: `RSAPublicKey.expires`,
   `PinnedKey.expires`, `Failure.keyExpired` (D03); the pinned keys (through their providers); `PolicyGate.remember`,
   `derivedBlocks` (D09, called by `DNSProxy`); `UserNetStats.dnsAnswersLost` (D10); `AnswerFolding`,
   `publishHeldAnswers` (D11); `ResolverWorkers`, `ResolverQueue`, `SystemNameResolver.maximumQueued` (D13);
   `GuestTxQueue.byteBudget` (D14); `ImageStore.installCopy` (D16, `Provisioner`); `ImageStore.isInFlatCache`,
   `migrateFlatCacheInstallers` (D17, `load()`); `Signature.parseEach` (D19, `verifyClearSigned`); `DebianReleaseTrust`,
   `DebianRelease`, `debianArchive13` (D20, `debianNetbootMini`). No `@dw:accept` is needed in this chain.
9. **Clones.** No new block is token-for-token a copy of an existing one. Watch `AnswerFolding.expire` against
   `DenialSuppression.expire` (D11): similar, not identical; dolly's near-clone note is advisory.
10. **Shipping rules (CONTRIBUTING).** A user-visible change carries its help text in the same card (D03, D07, D09, D12, D21;
    D20's help is in D21, the next card, which is held with it); nothing widens what a guest can reach (no exposure line, no
    `Security.swift` edit); behaviour changes carry tests that fail before the change (D09, D10 say which line fails); ADRs and
    roadmap updates are in D08, D18, D19, D21; the diary is D22.
11. **Words.** ADR-0042: no planning words (spike, prototype, poc, draft, wip), no `Kit`, `Util`, `Helper`, `Manager` suffix in a
    new name. No outside project named in text that goes into the repository (docs, comments, help); vendor and distribution
    names the app supports, Apple's APIs and file names are fine. Grep the code and markdown blocks of the card for `aemi`,
    `libFuzzer`, `swift.org` and `gpg`: none may appear in a block that goes into the repository.
12. **Gates and placeholders.** D07 is dispatched only with the owner's "go" (or the default recorded in INDEX-D); D19 to D21
    only after the owner accepted ADR-0055; D18 has no `<<TSAN>>` left; D22 has no `<<...>>` left.
13. **Anchor check.** For each fenced block or inline line that the card
    introduces with "replace", "the line", "these lines" or "delete", `grep -n -F` its first and last line in the named file.
14. **Order and cap.** One build at a time for the chain; D02 is a build; the card's "after" card has merged into WT.

## After each card (integrator)

The report has the commit SHA, `git show --stat`, the last lines of each command, and the gate's 8 `PASS` lines. Read the diff:
it touches only the card's files and does what the card says. After the chain: the gate on the merged tree, then the cleanup of
CONTRIBUTING ("Worktrees and cleanup"), and delete `/tmp/d01-run-*.log` and `/tmp/d02-tsan-*.log`.
