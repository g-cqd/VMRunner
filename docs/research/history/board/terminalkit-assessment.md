# TerminalKit for VMRunner's console: assessment

Private board document for the owner. Date 2026-10-23. VMRunner was read, not edited. TerminalKit was read at HEAD `361472c` ("build: pin Aemi to afc1be3"), shallow clone. Nothing was run from TerminalKit except one `swift build` (see 4).

Read versus inferred: statements with a path were read in source. "Inferred" marks judgement. Timings and sizes not measured are said so.

## Bottom line

TerminalKit has **no output-side terminal emulator**. It is an input/output toolkit for programs that draw their own UI (key/mouse decoding, escape *encoders*, a diff renderer, raw mode, a text rope). The only thing that parses escape sequences coming in is `TerminalStateModel`, a 227-line test oracle that is ASCII-only, has no cursor, no grid and drops newlines, and lives in a product called TestSupport. It cannot give VMRunner a `read screen` tool. What it could give the `vmr guest console` client (raw mode guard, SIGWINCH plumbing, a reset ladder) is about 100 lines in-repo, and it would cost a dependency graph with a revision pin, no tags, no licence and a new transitive package (swift-syntax) in `Package.resolved`.

Recommendation: **Option A** (no dependency, in-repo fixes), first card a guest-output sanitiser for the console client plus signal-safe restore. For the screen model, write a small in-repo emulator in `GuestConsole`.

## 1. TerminalKit inventory (read)

Package: `swift-tools-version: 6.4`, `platforms: [.macOS(.v26)]`, Swift 6 mode, StrictMemorySafety, treatAllWarnings(as: .error), same upcoming features as VMRunner. Products (Package.swift):

| Product | Lines | What the public API really offers |
|---|---|---|
| TerminalKitCore | 210 | `TerminalResetLadder` / `TerminalResetTier`: byte values for a three-tier recovery (selective private-mode off, DECSTR, RIS). Pure values, no fd. Plus `SourceStandards.swift`. |
| TerminalKitIO | 924 | `TerminalConnection` protocol, `POSIXTerminalConnection` (read/write, `enterRawMode`/`restoreMode`, `getSize()` via TIOCGWINSZ), `RawModeGuard` (~Copyable, restores in deinit), capability probe, a mock connection. |
| TerminalKitStyle | 58 | `Style` value types. |
| TerminalKitCodecs | 1809 | Encoders: SGR, OSC clipboard/palette, graphics, `EscapeSequences`. Decoders for keyboard (kitty protocol) and mouse. This is input-side parsing and output-side *encoding*. Depends on AemiKernel. |
| TerminalKitInput | 1696 | `TerminalSession` (modes entered and left as a unit), `SignalHandler` (SIGWINCH to `onResize`, signal pipe, own thread; uses C target `CTerminalSignals`), `InputLoop`, `SequenceRouter` (589 lines, routes decoded input events), pointer/clipboard logic. Depends on AemiKernel. |
| TerminalKitText | 3399 | Rope, text buffer, selection, wrap, Unicode width tables, `TextSanitizer`. |
| TerminalKitRender | 1769 | `ScreenBuffer` (public: `columns`, `rows`, `subscript(row,col)`, `write`, `shiftRows`, `resize`), `DiffRenderer`, `RenderPipeline`. It is a grid a *program draws into* and diffs out as escape bytes. Nothing parses bytes into it. |
| TerminalKitTestSupport | 267 | `TerminalStateModel` (the oracle) and `ProcessFootprint`. |
| TerminalKit (umbrella) | 7 | Only `@_exported import TerminalKitCore`. The file says test support is deliberately not re-exported. |

### Is there an output-side emulator?

No, in the sense asked. The nearest thing is `Sources/TerminalKitTestSupport/TerminalStateModel.swift`:

- It states its own scope: "The model deliberately understands only what it must: private modes set and reset, the alternate screen, cursor visibility, SGR, and the difference between a reset that preserves history and one that destroys it. Everything else it ignores".
- Handled: `ESC c` (RIS), CSI with `?`, `!`, `>`, `<` markers, `h`/`l` private modes, `m` SGR (stored as a set of ints, not per cell), `CSI ! p` (DECSTR), kitty keyboard push/pop (`u`). Any other `ESC x` is skipped; OSC/DCS are not recognised (an OSC body would leak into the text as printable bytes).
- Not handled: cursor position (`H`, `A`-`D`), erase (`J`, `K`), scroll regions, insert/delete line/char, tabs, wrapping, UTF-8 (only 0x20-0x7E is appended, `appendPrintable`), `\n` and `\r` (bytes below 0x20 are dropped, so the "screen" is one ever-overwritten line). `screenLines` and `scrollbackLines` exist but are set by a canned helper `applyFullScreenSession()`.
- It is a 227-line oracle for a reset ladder, with its own file comment saying real terminals disagreed with it once (DECSTR). Not a candidate for "visible text of the screen".

Text of the screen from TerminalKit: would be `TerminalStateModel.screenLines` (one line of ASCII), or, if someone wrote the parser, `ScreenBuffer[row, col]` cells (`Cell` is 36 lines, `PackedCell` 16 bytes) read back out. The grid type is usable as a *store*; the parser, cursor, scroll and SGR state machine would all be new code.

### Test support from a non-test target

It is a normal `.library` product (Package.swift lists it with the others), so SwiftPM lets any target, including `vmr`, `import TerminalKitTestSupport`; there is no test-only product kind in SwiftPM. Its comment says "so a consumer can test its own terminal layer". Linking it into a tool is allowed and nothing technically blocks it, but it is a stated misuse of the product (umbrella comment: "a shipping binary that links it has paid for a test double it never consulted"), it is not API-stable, and given the above it would give nothing useful. (Inferred: no API stability policy found; I did not search for one.)

## 2. What VMRunner has today (read)

Client: `Sources/DevTools/CLI/GuestCommand.swift` `Console` command (about lines 185-215). It prints "attached ...; Ctrl-] detaches", then `TerminalMode.raw { ConsoleRelay.run(socketPath:, input: STDIN, output: STDOUT) }`.

- `Sources/DevTools/Guest/TerminalMode.swift` (16 lines): `isatty`, `tcgetattr`, `cfmakeraw`, `tcsetattr`, `defer` restore. Restores on normal return or throw only.
- `Sources/GuestConsole/ConsoleRelay.swift` (58 lines): poll loop between the socket and fds, 16 KiB buffer. Doc comment: "Copies bytes ... unchanged". Detach byte 0x1D (Ctrl-]) cuts the typed chunk at the first 0x1D and ends.
- `Sources/GuestConsole/LossyText.swift` (4 lines): `String(decoding:as: UTF8.self)`. Only UTF-8 repair, no filtering.
- Escape handling exists in one place only: `PromptClassifier.strippingEscapes` in `ExecProtocol.swift` (CSI only; bare ESC dropped; used for prompt detection and exec marker matching), and `ConsoleSession.excerpt` (control chars shown as `.` in error messages). Neither is on the relay path.
- ADR-0052 (read): the console is a "raw byte pipe", and item on the client says "It makes no claim against a guest that wants to confuse the client". So the lack of sanitising is a documented, not accidental, position, but the ADR is about the exec client confusion, not about the user's terminal.
- Roadmap 0005 "Remaining": item 3 screenshots then keyboard/mouse input (graphical, via ScreenCaptureKit/VZ view, not the serial console); item 5 "Opening the console in the user's terminal application ... It needs the console client inside the app's bundle first." Research doc `docs/research/automation-2026-10.md` lists a `vm://<id>/console-log` resource and says the serial console is "a raw byte pipe; protect it like a root shell". There is no `read screen` tool in `Sources/AgentBridge/MCPTool.swift` today (I grepped the tool list only, not every enum case).

### Gaps in the client terminal handling

| Gap | Evidence | Severity |
|---|---|---|
| Guest output goes to the real terminal unfiltered | `ConsoleRelay.run` writes `buffer[0..<count]` straight to `output`. Guest-controlled bytes can: set the window title (OSC 0/2) and, on some terminals, read it back via CSI 21 t (title reporting injection); write the clipboard (OSC 52); send DA/DSR/CPR queries so the terminal *types answers into the user's stdin*, which the relay forwards to the guest (low harm) but also which land in the user's shell after detach if timing is bad; enable mouse/bracketed-paste/alternate screen/kitty keyboard modes and leave them on after detach; hyperlinks (OSC 8); DCS/APC/graphics payloads; clear scrollback (`CSI 3 J`, RIS) or move the cursor to overwrite the "attached" banner and previous output. | Security, real. The guest is untrusted by design (the project's threat model: "runs untrusted guests"). Inferred severity: medium; depends on the user's terminal app (Terminal.app, iTerm2, kitty differ on OSC 52 and title reporting; I did not test any). |
| No restore of terminal modes after detach/close | Only termios is restored. Modes a guest turned on stay on (see above). TerminalKit's `TerminalResetLadder` documents exactly this ("restoreMode() alone cannot fix this: it restores termios"). | Real, small. |
| Not signal safe | `defer` runs on normal exit; SIGTERM/SIGHUP/SIGINT (raw mode clears ISIG, but a `kill` still arrives) leave the terminal raw. No signal handler anywhere (grep: no SIGWINCH, TIOCGWINSZ, TIOCSWINSZ in `Sources/GuestConsole`, `Sources/DevTools`, `Sources/VMHelper`). | Real, small. |
| No window-size forwarding | No SIGWINCH handling, no TIOCGWINSZ. The console is a virtio serial port, not a pty, so the protocol has nowhere to carry a size; the guest's `stty size` never matches. Closing it needs a size message in the bridge protocol or an in-band `stty cols N rows M` on attach (inferred), not just client code. | Medium; needs a guest-side decision, TerminalKit helps only with the client half. |
| Detach key is a raw byte, 0x1D | Works when the guest is not in a mode that changes keys; with kitty keyboard protocol enabled by the guest (it can enable it, it is a CSI), Ctrl-] arrives as `CSI 93;5u` and **detach stops working**. Can be avoided by sanitising (never forwarding mode-setting sequences) or by decoding input (TerminalKit has a kitty keyboard decoder). Also no `~.`-style escape and no detach if stdin is not a tty. | Real, interacts with the sanitiser. |
| Line discipline | Raw, 1:1, fine for an interactive console. No local echo or LF/CR translation, so a guest getty must do its own (it does). Nothing to fix. | None |
| Paste, large writes | `writeAll(... stallMilliseconds: 10_000)` bounded. Fine. | None |

### Needs of the planned agent features

- `read screen` (visible text of the console) and "wait for text on screen": a screen model that turns the replay/live byte stream into a grid. Today `PromptClassifier` only strips CSI and looks at the last line, which is correct for a getty at 80 columns with line output and wrong for any full-screen program (htop, vi, a bootloader menu, `apk` progress bars). The 2026-10 research already lists "programs that redraw the whole screen" as an unsupported case.
- Because the same bytes feed both the user's terminal and an agent, the sanitiser and the screen model should be the *same* parser: one state machine that classifies every sequence (pass/drop/model).

## 3. Fit matrix

Effort in cards (a card is one reviewable change with tests, small unless noted). "Uses" says exactly what of TerminalKit would be consumed.

| Gap / feature | TerminalKit solves? | What would be used | Effort in cards | Risk |
|---|---|---|---|---|
| Sanitise guest output to the user's terminal | No (partly: `TextSanitizer` strips C0/C1 from a *String*, which also removes ESC so the rest of a sequence prints as text, and removes CR; wrong tool for a byte stream: not stateful across reads, no UTF-8 split handling, no OSC/DCS string states) | Nothing usable | 1 (in-repo, see 5) | Low |
| Restore terminal modes after detach | Yes | `TerminalResetLadder.escapeBytes(for: .selectiveCleanup)` is a 70-byte list; copying it is cheaper than a dependency | 0.3 | Low |
| Signal-safe restore | Partly | `SignalHandler` + `CTerminalSignals` (C target) and `RawModeGuard`; design is async-signal-safe per ADR-0015/0013 in that repo (I read titles, not the bodies) | 0.5 in-repo; ~0.5 plus dependency work if consumed | Low; SwiftPM brings a C target |
| SIGWINCH / size forwarding | Partly (client side only: `SignalHandler`, `getSize()`) | `getSize()`, `SignalHandler(onResize:)` | 1 for client + protocol message, of which TerminalKit would save about 30 lines | Medium (bridge protocol change, ADR-0052 touches) |
| Escape key / detach robust to kitty keyboard modes | Partly | `KeyboardDecoder` | 0.3 if sanitiser blocks mode sets; the decoder is not needed | Low |
| Line discipline | n/a (nothing to fix) | | 0 | |
| Screen model for `read screen` / wait-for-text | **No** (no emulator; oracle is not it) | At best the `ScreenBuffer` grid type as storage (needs `TerminalKitRender` -> Codecs, Style, IO, Text, plus Aemi) | 3 to 4 cards in-repo (grid, SGR-less text mode first, cursor + erase + scroll, alt screen, tests with recorded Alpine boot); TerminalKit saves the grid struct only (about 100 lines of the ~600) | Medium: terminal semantics are where bugs hide; TerminalKit's own README says real emulators disagreed with its model |
| Open console in user's terminal app (roadmap 0005 item 5) | No | Unrelated: needs the client in the app bundle (app target cannot link tooling packages, and "owner's libraries" are not planned for the app) | Out of scope | |

## 4. Dependency reality (read, and one build)

- Manifest: `swift-tools-version: 6.4`, `.macOS(.v26)`: same floors as VMRunner (6.4 and `.macOS(.v26)`). The local toolchain is Apple Swift 6.4 (swiftlang-6.4.0.34.1). **It compiles here**: `swift build --product TerminalKitInput --product TerminalKitRender` completed, "Build complete! (6,00 sec)", 10 s wall from a cold `.build` (Aemi/support checked out; Aemi products built are only what those need; AemiKernel and friends were built within the 240-step graph).
- Strict flags: TerminalKit uses Swift 6 mode, `StrictMemorySafety`, `treatAllWarnings(as: .error)`, `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `InferIsolatedConformances`. VMRunner's `commonSettings` additionally has `NonisolatedNonsendingByDefault` and `ImmutableWeakCaptures`; dependency targets build with their own settings, so no clash (inferred from SwiftPM semantics; the strictest-mode build here used TerminalKit's own flags only).
- Dependencies: one external package, **Aemi** (`https://github.com/Aemi-Studio/aemi.git`), `revision: "afc1be3d578045b381e76f6b1712a81b39956ced"`. The manifest comment says: "Aemi publishes no tags". Aemi is public (MIT licensed per GitHub API). Aemi's manifest: tools 6.3, platforms iOS 18 / macOS 15 and others, and package-level dependencies: `swift-syntax "603.0.0"..<"605.0.0"`, `swift-collections from: "1.7.3"`, `swift-system from: "1.8.1"`, plus optional docc plugin and `ordo-one/benchmark` only under conditions I saw as lines 119-122 (not read for the condition).
- TerminalKit's `Package.resolved`: Aemi (revision), swift-collections 1.7.4, swift-syntax 604.0.0, swift-system 1.8.1. The checkouts after my build: swift-syntax 12 MB, swift-collections 15 MB, swift-system, aemi.
- What it would add to VMRunner's `Package.resolved`: today it has swift-argument-parser, swift-async-algorithms, swift-collections 1.7.3 (exact), swift-subprocess, swift-system. New: `aemi`, `swift-syntax`, and `terminalkit` itself. SwiftPM fetches swift-syntax for resolution even if no macro target is built (we saw it checked out and not compiled). Collections is compatible (Aemi says `from: 1.7.3`, VMRunner exact 1.7.3), swift-system already present. This is the same macro-compiler concern the 2026-10 reuse survey cites against the shared library ("declares a macro-compiler dependency at package level").
- Pinning rule: the owner's rule is exact versions. TerminalKit has **no git tags and no GitHub releases** (`git ls-remote --tags` empty; releases API returns 0), so the only possible pin is `revision:`. A revision pin on a dependency that itself pins another by revision is, as far as I know, accepted when the root uses a revision (inferred; not tried because it would mean editing VMRunner). It breaks the "exact version + Dependabot" model in ADR-0001 item 3.
- Licence: **none found.** No `LICENSE` file in the tree, and the GitHub API reports `license: null`. A public repo with no licence is all-rights-reserved to outside parties, but the owner is the author, so only a formality for VMRunner. `DependencyPolicyTests.everyDeclaredPackageIsInTheLicenseNoticeAndTheAppsOnesInTheReadme` requires every declared package to appear in `THIRD_PARTY_LICENSES`, so a licence text would need to be added to TerminalKit first (or the test would be a documented exception).
- Build time and size: not measured on VMRunner. Evidence: cold build of Input+Render here was about 10 s wall including Aemi kernel; for `vmr` I would guess low tens of seconds extra cold build and a small binary increase (inferred; TerminalKit Text has a 614-line generated Unicode table). `vmr` already links swift-subprocess, argument-parser.
- Interaction with the rules:
  - Strict memory safety / warnings as errors: dependencies are compiled with their own settings; both packages already use the same strict set. No conflict.
  - `DependencyPolicyTests`: the first test compares the *app target*'s `dependencies:` list with ADR-0001. A package used only by `DevTools`/`vmr` does not touch that test. But `theAppTargetDependsOnExactlyThePackagesTheAdrNames` also asserts `app.packages.isDisjoint(with: ["swift-subprocess", "swift-argument-parser"])` ("tooling packages stay out of the app"), which is the model to extend. The licence-notice test would fail until `THIRD_PARTY_LICENSES` names `terminalkit` and `aemi`.
  - ADR-0001 item 4 ("Packages that duplicate the SDK are not added") and the Consequences ("A new dependency is an architectural decision that needs an ADR"): a new ADR is required; item 2 would be amended to list the new tooling package.
  - Standing conclusion, `docs/roadmap/0036-order-of-remaining-work.md` line 30: "Not planned, with reasons in the studies: depending on the owner's libraries or on swift-crypto from the app". Reasons in `docs/research/reusable-code-survey-2026-10.md` "Short answer": "No library fits as a dependency of the app: the shared utility library declares a macro-compiler dependency at package level, and the JSON library pins a collections range that cannot resolve with this repository's exact pin. Copying small, reviewed files with their licence header is the only fit with ADR-0001." The words are "**from the app**", so a tooling-only dependency does **not** literally conflict with the sentence, but the reasoning (macro-compiler graph, copy small reviewed files) applies equally to Aemi, and the survey's guidance is to copy. Also roadmap item 5 puts the console client into the app bundle later, which would pull a tooling dependency into the app and hit the line. So B would need that study conclusion re-opened or scoped.
  - Rule that outside projects are not named in the repo's prose: VMRunner's docs already say "the owner's libraries" rather than names (grep for `Aemi|TerminalKit` in docs, Sources, Tests, Package.swift found no hits except diary lines about "aemi worktrees"; `docs/diary/2026-10-22-01.md` line 36 does name aemi, so the rule is not applied to the diary, I did not verify the rule's text). A dependency would have to be named in `Package.swift`, `Package.resolved` and `THIRD_PARTY_LICENSES`, which cannot avoid the name. The ADR could say "a terminal library of the owner's".

## 5. Alternatives without a dependency (sketch)

All inside `Sources/GuestConsole` (plain library: imports Foundation and Synchronization only, enforced by `theConsoleLibraryImportsNothingButFoundationAndSynchronization`), so tooling and the future bundled client share it.

1. `EscapeFilter` (about 120 lines + 150 lines of tests): a byte-stream state machine used by the relay for the user's terminal.
   - States: ground, ESC, CSI (params/intermediates), OSC/DCS/APC/PM/SOS string (until BEL or ST, with a length cap), UTF-8 continuation tracking so a sequence split across reads is handled and invalid UTF-8 is replaced.
   - Policy (allow-list): pass printable text, `\n \r \t \b` (and BEL, maybe rate-limited); allow SGR (`CSI ... m` with digits/`;`/`:` only), cursor movement and erase (`H`, `A-D`, `J`, `K` except `3J`), `CSI ? 25 h/l`, and alternate screen only if you want full-screen programs to work; drop OSC, DCS, APC, PM, SOS, any `CSI ... t`, `n`, `c`, `q`, `u`, `>`/`<`/`=` marked sequences, and private modes other than a short allow-list; replace other C0 and all C1 (including 8-bit forms 0x80-0x9F only when decoded as scalars) with a visible mark such as U+FFFD or `^X`. Keep a counter of dropped sequences.
   - Options: `--raw` to keep today's behaviour for experts, default filtered. Default must be the filter, because the guest is untrusted.
2. Cleanup on exit (about 25 lines): after relay ends, write the 70-byte selective reset (modes off, SGR reset, cursor visible), which is the same list as TerminalKit's. Replace `TerminalMode` by one that also installs `sigaction` handlers for SIGTERM/SIGHUP/SIGINT that set a flag read by the poll loop (use a self-pipe so `poll` wakes; add the pipe fd to `entries`). Total about 60 lines in `TerminalMode.swift` and `ConsoleRelay.swift`.
3. Size: on attach and on SIGWINCH (self-pipe again) send the size. Smallest honest form (about 40 lines + 1 test): write `stty rows R cols C\n` on attach. That types into the guest's shell and fails when something other than a shell is reading, so it is a poor fit; the clean form is a size field in the bridge protocol (helper-side `ioctl` is impossible since it is not a pty, so the guest needs to cooperate). Recommend leaving window size out until the guest agent over vsock exists (roadmap item 6).
4. Screen model (new `ScreenModel` in `GuestConsole`, 350 to 500 lines + tests): fixed columns x rows (default 80x25 or whatever the guest `stty size` is), cells `[Character]` (no style needed to read text), handling printable UTF-8 with width 1 (wide chars as a follow-up), `\r \n \b \t`, CSI `H f A B C D E F G d J K L M P @ X S T r`, `ESC 7/8`, `ESC M`, alt screen (1049 save/restore), scroll region, SGR parsed and ignored. Expose `func text() -> String` (rows trimmed, trailing blanks removed) and `func contains(_:)`. Feed from the same filter so one parser classifies. A recorded Alpine boot (the research doc has one) is the first fixture. A `read_screen` control method and MCP tool (the control method plumbing is described in ADR-0056) comes after, a card of its own.

The sanitiser and the model can share the CSI/OSC scanner; build the scanner once and let both policies sit on it.

## 6. Recommendation and options

**Option A (recommended): no dependency, in-repo fixes.**
- Costs: filter (1 card), exit cleanup + signal-safe restore (1 card), screen model (3 to 4 cards), no ADR, no `Package.resolved` change, no licence work, nothing named in the repo.
- Gains: closes the security gap first, keeps `GuestConsole` free of dependencies, keeps the client movable into the app bundle (roadmap 0005 item 5) without touching the "not from the app" conclusion.
- Risk: you own the emulator's bugs; mitigated by the recorded-boot fixtures and fuzz-style tests (random bytes never crash, never produce a forbidden byte on output).

**Option B: tooling-only dependency on TerminalKitIO/TerminalKitInput for the console client** (raw mode guard, SignalHandler, getSize, reset ladder).
- Costs: new ADR amending ADR-0001 item 2; `revision:` pin because there are no tags (against the exact-version rule); add LICENSE to TerminalKit and THIRD_PARTY_LICENSES entries (test requires it); `aemi`, `swift-syntax`, `terminalkit` enter `Package.resolved`; the study's reasons (macro-compiler graph) and its "copy small reviewed files" advice must be re-argued; and when the client moves into the app (item 5) it conflicts with the standing line. Dependabot cannot propose revision bumps the way it does versions.
- Gains: about 150 lines not written (raw mode, signals, size). It does **not** supply a sanitiser, a screen model, or anything for gaps 1 and 5.
- Verdict: poor ratio; the lines saved are smaller than the ADR it needs.

**Option C: build the screen model on TerminalKit's emulator.** Does not exist; the only candidate is the 227-line oracle in a test-support product, which cannot handle newlines, UTF-8 or cursor movement. Using `ScreenBuffer` as the grid saves about 100 lines at the price of the whole Aemi/Render/Text graph. Not viable.

Only if TerminalKit later ships a real emulator (an `Emulator`/`VT` product with a grid, cursor, SGR, scroll region and alt screen, tags and a licence) would C be worth re-opening; the cheap signal to watch is a roadmap entry in `docs/roadmap` of that repo (today none mentions an output parser; 0002 is about the reset ladder; I saw only the first 19 entry names).

### First card to write

"Console client: filter guest output and restore the terminal." Scope: `EscapeFilter` in `GuestConsole`, used by `ConsoleRelay.run` for the user's terminal (a `--raw` flag keeps the old path), the selective-reset write after the relay ends, self-pipe signal handling for SIGTERM/SIGHUP/SIGINT in `TerminalMode`, and an ADR line in 0052 replacing "makes no claim against a guest that wants to confuse the client" with the filter policy. Tests: OSC 52, OSC 0 with title query, CSI 21 t, DA request, `CSI ? 1000 h`, split-across-reads, invalid UTF-8, 1 MiB of random bytes never emits ESC followed by a dropped final byte, detach byte unaffected.

## Not verified

- No terminal emulator was tried against the injection vectors (OSC 52, title reporting); effect depends on the user's terminal app and settings.
- Binary size and build-time impact on `vmr` were not measured (would require editing VMRunner).
- Whether SwiftPM accepts a revision-pinned transitive dependency under a revision-pinned root: inferred, not tried.
- I read `TerminalStateModel`, the reset ladder, `TextSanitizer`, the IO/Input public signatures and manifests in full or by grep; I did not read the bodies of `SignalHandler`, `SequenceRouter` or `RenderPipeline`.
