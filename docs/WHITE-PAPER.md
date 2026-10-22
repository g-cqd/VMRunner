# VMRunner — White Paper

The rules this repository is built under. They are principles, not a log: this file changes only when a principle
changes. Decisions and their evidence live in `docs/adr/`, work lives in `docs/roadmap/`, and the working log lives in
`docs/diary/`. Read this before starting a piece of work.

## What VMRunner is

A macOS app on Apple silicon that runs virtual machines (and, in time, containers) on Apple's own frameworks, with every
setting reachable in the app, every setting explained where it is changed, and every channel between guest and host
visible and switchable. The guest is untrusted. The host is the user's machine.

---

## 0. The evidence rule

A claim about behaviour is only as good as the check that ran. Say what ran: the command, the count, the platform. If
something was not run, say "not verified" and say why. Never write "works" about a path no one exercised; CI cannot start
a virtual machine, so guest behaviour is verified by hand on real hardware and recorded as such in the diary.

## 1. Tests come with the behaviour

Behaviour changes with a test that fails without them. Time-dependent and concurrent code takes an injected clock and is
tested with the test clock and event probes, never with `sleep`. A test that waits for a real duration is a bug. A test
that was written against a race is fixed by removing the race, not by raising a timeout.

## 2. Performance doctrine

Measure before changing; keep the number, in the committed benchmark baseline that the gate ratchets. Hot paths do not allocate: the packet paths of the network stack, the policy
decision and parsers carry allocation ceilings in tests, taken as the minimum of several attempts on the measuring
thread. Work that can wait is coalesced (settings writes), work that is large is streamed (checksums, downloads), and
memory is not held longer than needed (a restore image is deleted after installing). `unsafe` is for a measured gain
that safe code cannot reach, and is never added for a gain that was not measured.

## 3. Safety

- **Strict memory safety** is on for the app and the tooling. Each `unsafe` carries its justification. Test support that
  parks raw continuations by design is the single, documented exception.
- **Warnings are errors**, with the upcoming language features switched on.
- **Everything from outside is untrusted**: network frames, server metadata, file names, image contents, guest output.
  Parsers bound their reads, reject ambiguity, and never trust a length they have not checked.
- **Ambiguity denies.** A host spelled in a way a resolver might read differently from the policy is refused, not guessed.
- **Downloads** are https only, from exactly named hosts, followed through a redirect only to another such host,
  size-capped, filed in the cache by checksum, and checked against the checksum the source publishes (and a pinned
  vendor signature where there is one) before they are used. A file the user picks is used as it is.

## 4. Security posture

Least privilege, off by default. The app gets the entitlements it needs and the build verifies the signed result. A guest
channel (clipboard, shared folder, network, audio, vsock, device) exists only when its switch is on, and the app lists
what a guest can reach. A preset narrows channels; it never claims to make an untrusted guest safe. Features aimed at
making a guest unaware of virtualization are for analysis and privacy use, and the help says what a guest can still tell.

## 5. Documentation law

Five artifacts, each with one job.

- **White paper** (`docs/WHITE-PAPER.md`): this file. At most 200 lines.
- **ADRs** (`docs/adr/NNNN-kebab-title.md`): one decision per file, with front matter `status`, `date` and, when
  replaced, `superseded-by`. An accepted decision is never rewritten; a changed decision is a new ADR that names the old
  one, and the old one gets a banner. Sections: Context, Decision, Consequences, What this does not decide.
- **Roadmap** (`docs/roadmap/NNNN-kebab-title.md`): one unit of work per file with front matter `status`
  (`pending`, `in-progress`, `done`), `blocked-by` and `date`, and `decision` when an ADR governs it.
- **Diary** (`docs/diary/YYYY-MM-DD-NN.md`): the working log, one file per work session, at most 256 lines each, with a
  claims table (claim, probe, verdict) and a "Not verified" section.
- **Research** (`docs/research/topic-YYYY-MM.md`): a dated study that answers one question before a decision is made, with
  front matter `date`, `question` and `feeds` (the roadmap entries and ADRs it informs). It states what was verified and
  what was not. A roadmap entry or an ADR cites the study; a study is not edited to match a later decision, it is
  superseded by a newer one.

Numbers are zero-padded and unique within a directory. `vmr check docs` enforces the shape, so the rules above do not
depend on anyone remembering them.

## 6. Commit discipline

One reason per commit; every commit builds and passes the gate; the message says why, because the diff already says what.
Refactors and behaviour changes are separate commits. Commits are signed. History is not rewritten once shared.

## 7. Bans

- Shell scripts in the build or the gate; tooling is Swift (`vmr`) and is tested end to end.
- `DispatchQueue`, `print`, `NSLock`, and `@unchecked Sendable` without a stated reason.
- `NSRegularExpression`; use RegexBuilder.
- Logic in a view; views read view models.
- Private API, except where an ADR accepts it for test-only code.
- A feature without its help topic, or a help topic that overstates what was verified.
- Disabling a check to make a change pass.
