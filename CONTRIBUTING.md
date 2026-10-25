# Contributing

## Setup

Requirements: an Apple silicon Mac on macOS 26 or later and Xcode 27 (Swift 6.4), which ships swift-format. SwiftLint
needs no install: `vmr` downloads the release pinned in `Scripts/analyzers.lock` the first time a step or the hook needs it.

```sh
swift run vmr hooks install           # pre-commit: format lint and SwiftLint on staged Swift files
```

## Before you push: `swift run vmr check`

```sh
swift run vmr check                 # fast gate: format, swiftlint, docs, workflows, policy, build, test, analyzers
swift run vmr check --full          # + ASan, TSan, UBSan test runs, release build, coverage and benchmark gates
swift run vmr check test analyzers  # only the named steps (swift run vmr check --list shows them all)
```

Every step runs even if an earlier one fails; each prints PASS or FAIL and the command exits non-zero if any
failed. CI runs the same commands, so a green local run is a green CI run (minus the hosted-runner limits noted
in `.github/workflows/ci.yml`).

- **One gate per checkout.** `vmr check` takes an exclusive lock on `.build`; a second one (another terminal or the
  pre-push hook) does not wait but exits at once with status 75 and the pid of the first. The lock goes
  when the process ends, however it ends. `--list` takes no lock.
- **`docs`** checks `docs/` and `README.md` against the documentation law (`docs/WHITE-PAPER.md` section 5): file
  names, numbering, front matter, headings, supersession, `blocked-by`, `decision` and `feeds` references, and relative
  links. It prints `path:line: message` for each violation; fix the document, not the checker.
- **Nested packages.** `packages` in `.vmr.json` lists packages of their own, directories with a `Package.swift` and a
  committed `Package.resolved`. After the root package, the `build` and `test` steps build and test each of them with
  `--package-path` into its own `.build-packages/<path>` scratch directory, so its dependencies stay out of the root's
  graph and its build products out of the root's `.build`. The `analyzers` step also analyzes their `Sources` and `Tests`.
  No other step looks at them; `SWIFT_TEST_FLAGS` applies to the root's test run only.
- **Job summary.** With `GITHUB_STEP_SUMMARY` set (GitHub Actions does), `vmr check` appends a table of the steps
  (result, duration) to that file, plus test counts, coverage and analyzer findings when the steps ran. Nothing changes
  when it is unset.

The three static analyzers (retain cycles, duplicate code, dead code), SwiftLint and the workflow linters (actionlint and
zizmor) come from pinned, checksum-verified releases listed in `Scripts/analyzers.lock`; `swift run vmr analyzers`
downloads the analyzers, the first `swift run vmr check swiftlint` (or the first commit with the hook) downloads
SwiftLint, and the first `swift run vmr check workflows` downloads actionlint and zizmor, into the git-ignored `.tools/`.
CI runs the same `swift run vmr check` steps, so the lock is the only place the versions are written. See the
"Quality gates" section of the README for what each analyzer gates on.

- **`workflows`** runs actionlint, then zizmor, over `.github`. zizmor only warns about a file it cannot parse, so it runs
  with `--strict-collection`, which makes that a failure (actionlint fails on invalid YAML by itself), and `--offline`, so
  it never calls the GitHub API. A finding of either tool, at any severity, fails the step. actionlint runs without its
  shellcheck and pyflakes integrations, so the result does not depend on `PATH`; `zizmor.yml` still runs actionlint with
  shellcheck on Linux (`.github/workflows/zizmor.yml`). Do not add `-config-file`: actionlint reads `.github/actionlint.yaml` itself. `ACTIONLINT_BIN` and `ZIZMOR_BIN` name binaries of your own, like `SWIFTLINT_BIN`.
- **SwiftLint is never taken from `PATH`.** Every checkout lints with the pinned version, so a new SwiftLint release
  cannot turn a green gate red by itself. To bump it, follow the lock file's header and fix what the new version
  reports in the same change. `SWIFTLINT_BIN` (like `ARCLEAK_BIN`, `DOLLY_BIN` and `DEADWOOD_BIN`) names a binary of
  your own instead; it is used as it is, without the checksum or version check (when the `CI` variable is set, `vmr` prints a
  `WARNING` line naming the override, so one slipped into a workflow shows in its log).
- **Nothing in the checkout is trusted as a tool.** `.gitignore` does not stop `git add -f`, so a pull request can commit
  an executable under `.tools/`. After a verified install `vmr` writes `.vmr-verified` beside the binary (the lock's
  archive digest and the binary's own digest); every resolve hashes the binary and, on a mismatch or a missing stamp,
  reinstalls from the verified archive. It also refuses outright when git tracks any file under `.tools/` (skipped only
  when git is missing or the directory is in no repository). The tools stay in the package directory because the
  SwiftPM plugin sandbox may write nowhere else; the stamp is a local integrity check, and the tracked-file refusal is
  what keeps a committed binary and a committed stamp from vouching for each other.

- **A new analyzer finding is a failure.** Fix it, or accept it deliberately: `// @al:accept -- reason`
  (arcleak), `// @dl:accept -- reason` (dolly), `// @dw:accept -- reason` (deadwood), always with a reason.
- **Baselines (`.arcleak-baseline.json`, `.dolly-baseline.json`, `.deadwood-baseline.json`) record accepted
  debt and ship empty.** Never regenerate them to silence a new finding. When you pay debt down, run
  `swift run vmr analyzers baseline arcleak dolly deadwood` and commit the smaller file. Fingerprints include
  positions, so a large refactor can move baselined findings out of the baseline; fix them or regenerate deliberately in a separate commit.
- **Coverage is a ratchet.** `coverage.minimum` in `.vmr.json` (and `COVERAGE_MIN`) only goes up.
- **Benchmarks are a ratchet too.** `swift run vmr check bench` (in `--full`) runs the suites named `*Benchmarks` in an
  optimized build and compares their figures with `.vmr-bench.json`: allocation counts exactly, retired instructions per unit
  of work within 3%; wall-clock rates are only reported, because they spread by tens of percent on a busy machine. A figure
  that got worse fails the step; one that got better prints that the baseline should be re-recorded. After a change that is
  meant to move a figure, run `swift run vmr bench record` and commit the baseline with the change. A new benchmark is a
  Swift Testing suite named `...Benchmarks` with `.tags(.bench), .benchmarksRequested` that reports through TestKit's
  `recordBenchmark`; a plain `swift test` skips it. In CI the step is advisory until its runs there are stable.
- **`policy` keeps the gate from being relaxed quietly.** It compares the working tree with the branch's base
  (`origin/main`, or the merge base with it) and fails when a baseline file accepts a finding the base did not, the
  coverage floor is lower, `.swiftlint.yml` disables a rule, drops an opt-in rule or excludes a path, or `.gitattributes`
  adds `-diff`, `binary` or `linguist-generated` to a pattern (each hides changes from review). A deliberate relaxation
  is acknowledged where the reviewer sees it: a `Policy-Ack: <reason>` trailer in any commit message the branch adds, or
  `VMR_POLICY_ACK=<reason>` for a local run. Without an `origin/main` (a fresh clone) it says so and checks nothing; CI
  checks out the full history for it. It does not see `// swiftlint:disable` comments, `// @al:accept`-style
  acceptances or a changed severity in `.swiftlint.yml`, which stay review-only.

## Worktrees and cleanup

Parallel work (people or agents) happens in git worktrees on their own branches, never on `main`. Every worktree is
cleaned up, always:

- **After each merge**, in the same step as the merge: check that the branch is merged (`git merge-base --is-ancestor
  BRANCH main`, or `git cherry main BRANCH` when commits were cherry-picked or amended on the way in), look at
  `git -C WORKTREE status --short` so nothing uncommitted is lost, then `git worktree remove --force WORKTREE`,
  `git branch -D BRANCH` and `git worktree prune`. If the directory survives (build products are large), delete what is
  left of it. A worktree whose agent is still running is locked: leave it alone; unlock it only once that agent has
  reported.
- **After everything is done** (the end of a session, a phase or a release): `git worktree list` shows only the main
  checkout and `git branch` lists no work branches; no background process of the work is left running (loops, load
  generators, build servers); scratch directories created outside the repository (`/tmp` experiments, downloaded
  archives, PoC builds) are deleted; the build directories of removed worktrees (`.build*`, `.tools`) are gone; the
  working tree is clean (`git status`). The diary entry of the session says what was cleaned and what was left on
  purpose.
- Never delete a branch or worktree that holds work that is not on `main` or that nobody has looked at.

## Agents and models

Work delegated to agents follows one convention:

- **opus orchestrates.** It decomposes work, writes the task cards, sequences them and judges what comes back. It does not
  write code.
- **haiku does atomic tasks**: one implementation step, one probe, one mechanical change. A task card for haiku is complete
  and unambiguous: the files, the exact change, the command that proves it, the expected output, and what it must not touch.
  A haiku task is small enough to finish in one sitting; if it is not, it is split.
- **sonnet checks and reviews.** A sonnet reviewer reads every task card before it is dispatched (can it be misread? is
  every path and command real? is the acceptance command runnable?) and reads every result before it is merged (does the
  diff do what the card says and nothing else? are the tests meaningful?).
- Each role uses the latest version of its model (the `opus`, `haiku` and `sonnet` aliases of the agent tool resolve to the
  current generation).
- Thinking effort is set per task and never above medium: `low` for an atomic task with a complete card, `medium` for
  orchestration, reviews and anything that needs judgment.
- The integrator merges only reviewed work, runs the gate on the merged tree, and removes the worktree
  (see "Worktrees and cleanup").

## Code rules

The compiler and linters enforce most of these (`Package.swift`, `.swiftlint.yml`, `.swift-format`):

- Swift 6 language mode, warnings are errors, strict memory safety: every use of an unsafe construct is
  marked `unsafe` and justified in a comment.
- Swift concurrency only. No `DispatchQueue` (unless a framework API demands a queue), no `NSLock`,
  `os_unfair_lock` or similar: use `Mutex` from `Synchronization` or an actor.
- `@unchecked Sendable` needs a trailing comment naming the lock or invariant.
- No force unwraps, force casts or `try!`; no implicitly unwrapped optionals; no `print`: use `Log` in the app and `Output` in the command-line tooling.
- Formatting belongs to `swift-format` (4 spaces, 140 columns); run `swift-format format -i -r Sources Plugins Tests`.
- Anything that fetches remote data goes through `DownloadPolicy` (HTTPS, allow-listed hosts, verified
  checksums). Anything that widens what a guest can reach on the host must be reflected in the security
  profiles and their exposure summary, and covered by a test.
- `Sources/NetPolicy` (the network policy) and `Sources/NetStack` (the user-mode network stack) are library targets of the
  root package, so the headless helper can host the stack without linking the app (ADR-0047). They import the system
  frameworks and each other, never SwiftUI, AppKit, Observation or Virtualization (a test in `DevToolsTests` checks the
  manifest and the imports). A declaration another target of this package uses is `package`; the rest stays internal, and
  these targets' own tests use `@testable import`. Keep the per-packet path inside `NetStack`: no `public` or
  `@inlinable` on it without a measurement from `swift run vmr check bench`.
- `Sources/GuestSeed` (the provisioning spec, its compiler and the seed image, roadmap 0016) is a library target of the
  same kind: system frameworks only, `package` access, and the same test of the manifest and the imports. The app links it
  to build a Linux machine's seed at each start (`ProvisioningSeed`). A declaration only the library's own tests read carries
  a trailing `// @dw:accept:this referenced-only-by-tests -- <reason>` on its line.
- `Sources/ControlProtocol` (the control service's protocol, ADR-0056) is a library target of the root package. It links
  `GuestConsole` for the socket calls and imports Foundation, Synchronization and CryptoKit only; the manifest test in
  `DevToolsTests` checks its dependencies. Its API is `public`, as the console's is, and the dead-code gate roots public
  declarations. The tooling (`vmr control`) and `AgentBridge` now link its client, so moving it to `package` access, with
  a narrow directive where the gate needs one, is the open follow-up.
- `Sources/AgentBridge` (the MCP server over stdio, roadmap 0005) is a library target of the same kind: it links
  `ControlProtocol` and `GuestConsole` and the system frameworks only (the manifest test in `DevToolsTests` checks it), the
  app does not link it, and `vmr control mcp` serves it. Its API is `public`, like the control library's.
- `Sources/VirtioGPU` (the pure core of the host-implemented virtio GPU, roadmap 0014, ADR-0058) is a library target of the
  same kind as `NetPolicy`, with a stricter import rule: it imports nothing at all, not even Foundation. A declaration
  another target uses is `package`; the rest stays internal, and its tests use `@testable import`. The app links it and
  holds its own Virtualization adapter in `Sources/VMRunner/Engine/CustomGPU`, behind `@available(macOS 27.0, *)`. The runner
  (`Sources/VirtioGPURunner`, its command line in `Sources/VirtioGPURunnerCore`) links it and boots a virtual machine, so
  only its owner runs it; the app does not link the runner, and `vmr build-app` builds the app's product alone (a test in
  `DevToolsTests` checks the manifest, the imports and the build arguments).
- `Sources/VirtioInput` (the pure core of the host-implemented virtio keyboard and pointer, roadmap 0014, ADR-0058 item 7) is
  a library target under the same rules as `VirtioGPU`: it imports nothing at all and depends on no target, a declaration
  another target uses is `package`, and its tests use `@testable import`. The app links it, through the adapter in
  `Sources/VMRunner/Engine/CustomGPU`, and `DependencyPolicyTests` lets the app link it. A declaration that only its tests use
  carries the trailing `// @dw:accept:this referenced-only-by-tests` where the dead-code gate asks.
- `Sources/PrivateInterfaces` (ADR-0019, ADR-0059) is the only code that finds a method by the name of its class and selector.
  A capability there has an id, a range of macOS builds, the expected type encoding of each method, a read-back and a kill
  switch, and every failed check makes it unavailable with a reason; nothing is called after a failed check. It links the
  Virtualization framework and no other target, a declaration another target uses is `package`, and the app links it.
  A test in `DevToolsTests` fails when the runtime's lookup functions appear in any other target. Its contract tests need the
  framework's private selectors and are skipped on a macOS that lacks them; the fail-closed paths are tested with a fake
  resolver and run everywhere. Add a capability only with a probe on the running macOS build and a decision of its own.
- Code that needs a display or the virtualization entitlement (`Views`, `VMController`, `Provisioner`,
  `ConfigurationBuilder`) is kept thin; put logic in the model layer where unit tests can reach it.

## Building the app

```sh
swift run vmr build-app                     # release, ad-hoc signed, hardened runtime, then verified
swift run vmr build-app release --hardened  # + Enhanced Security entitlements (hardened process and heap, ...)
```

The entitlement policy is written in code (`Sources/DevTools/App/EntitlementPolicy.swift`), not derived from the
entitlement files: an allowlist of keys with their one permitted value (virtualization, audio input, the hardened-process
family) and a refusal of everything else, named for `com.apple.security.cs.*` (hardened runtime relaxations),
`com.apple.security.temporary-exception.*` and, in a release build, `get-task-allow`. `vmr build-app` applies it to both
entitlement files before it builds anything, and again to the effective entitlements it reads back from the signed
bundle, which must also equal the file used to sign. It also rejects a double hyphen inside an XML comment of an
entitlement file (the kernel's parser does). A new entitlement therefore needs a change to the policy, which review sees.

`vmr build-app` also embeds the container runner at `VMRunner.app/Contents/Helpers/ContainerRunner`. It builds the product
from `Packages/Containers` in the app's configuration, from the pinned versions of that package's `Package.resolved` and
in its own scratch directory (`.build-packages/Packages-Containers`, shared with `vmr check build`), copies the executable
and signs the copy ad hoc with the hardened runtime and `Resources/ContainerRunner.entitlements` before it signs the app,
so the app's signature seals it. The runner's policy is `EntitlementPolicy.runnerAllowed`: virtualization and nothing else,
checked on the file before anything is built, with the signature read back to equal the file; `--hardened` and `--arm64e` change only the
app. `--container-runner PATH` embeds a built executable instead of building the package (the tests do; they never build
or run the runner).

`vmr check` and CI never start virtual machines. Real-guest runs are separate and deliberate: the owner, or an agent the owner
has authorised for the session, runs them by hand against a scratch data directory (never the owner's own library), with
the resources of the guest capped, only the app's own window captured or driven (never the foreground, never the whole
screen), and everything the run created (machines, downloaded images, processes) removed afterwards. Their results go into
the diary with what was and was not observed.

`VMRUNNER_DATA_DIR=/absolute/path` makes the app keep everything it stores (the machines, the images, the approvals file) in
that folder instead of `~/Library/Application Support/VMRunner`, and is how a real-guest run stays off the owner's library:
point it at a fresh folder under `/tmp`. The folder must be an absolute path without `..`; one that exists must be a real
folder (not a link) of the current user and closed to others, and a missing one is created private. A value that cannot be
used stops the launch with the reason (exit status 78); the app never falls back to the default folder for it. The setting
also keeps the app's settings in a defaults domain of their own (the app's identifier followed by
`.data-directory-override`) and turns off window restoration and the main window's frame autosave (the app also never
restores windows from saved state in any run); state AppKit autosaves by itself elsewhere (a split view's divider) still goes
to the app's own domain. It does not move the unified log.

## Real-guest runs with `vmr guest`

`vmr guest` is how an authorised run acts on a guest without a screen: it fetches a small Linux image, boots it behind a
console socket, runs commands in it and stops it. Run it only when the owner has authorised real-guest runs for the session,
and keep to these conditions, which the tool also enforces where it can:

- **Scratch directory.** Everything goes under the `--directory` you give, in practice a new directory under `/tmp`. The tool
  refuses the user's `Library`, the home folder and `/`. Delete the directory when the run is over.
- **Caps.** At most 2 CPUs and 2048 MiB (`--cpus`, `--memory-mib`), and a hard run-time limit (`--max-seconds`, 900 by
  default, 3600 at most) after which the helper stops the machine whatever else happens.
- **No screen, no keys.** The console is the only channel: no screen capture, no GUI automation, no keystrokes into the
  foreground. Only processes you started are signalled: `vmr guest stop` signals the pid in the run's pid file, and only while
  that pid still runs the helper it recorded.
- **Signed image.** `fetch` takes the newest Alpine netboot release that has a signature and checks its `.sha256` and, when
  `gpg` is installed, its `.asc` against the release key (accepted only with the fingerprint pinned in the source); it says
  when the signature could not be checked.
- **macOS exception.** The run of 2026-10-22 used a macOS guest with the framework's minimum, 2 CPUs and 4096 MiB, and a disk
  of at least 40 GiB (16 GiB failed: the first attempt used 16 GiB, the second 40 GiB), within at most 4 CPUs and 8 GiB. Check
  with `df` that at least 48 GiB is free before the download.
- **Download space.** A download is first written to a temporary file in `$TMPDIR`, outside `--directory`. A run checks the free
  space there too, and removes the `CFNetworkDownload_*` leftovers it created.

```sh
swift run vmr guest fetch alpine-netboot --directory /tmp/vmr-guest          # about 430 MB, a minute or two
swift run vmr guest start --directory /tmp/vmr-guest                         # builds and signs the helper, boots, waits for a login prompt
swift run vmr guest exec /private/tmp/vmr-guest/guest/console.sock -- uname -a   # prints the output, exits with the command's status
swift run vmr guest console /private/tmp/vmr-guest/guest/console.sock        # interactive, output filtered; Ctrl-] detaches
swift run vmr guest stop --directory /tmp/vmr-guest
rm -rf /tmp/vmr-guest
```

The guest can sit on the app's filtered network instead of the framework's NAT, to test a policy against a real guest
(roadmap 0030, ADR-0053):

```sh
swift run vmr guest start --directory /tmp/vmr-guest --net filtered --policy policy.json [--deny-action drop]
swift run vmr guest policy /private/tmp/vmr-guest/guest/console.sock new-policy.json   # replaces the policy while the guest runs
swift run vmr guest flows /private/tmp/vmr-guest/guest/console.sock --last 20          # what its connections did, and the counters
```

`policy.json` is the JSON the app stores for a `NetworkPolicy` (`{}` is the default policy); a guest is named by its console
socket, its helper's pid or its scratch directory. Note that the stack treats the Mac's own LAN address as a private
address: it is reachable only when the policy has `"blockPrivateRanges": false`, which is how a server on the Mac can be
used as a fast target. A policy that blocks the package mirror stops the image from booting.

`start` prints the socket path (the real path: `/tmp` is `/private/tmp`). The console takes one client at a time, so
`exec` retries for three seconds while another client leaves and then fails with status 125; a command that runs out of time
fails with 124. Anything else a guest does is the guest's: with NAT it can reach the network, so run only what you would run
on a throwaway machine. The decision behind the console is `docs/adr/0052-*`; `docs/research/automation-2026-10.md` has the
measured numbers.

`vmr guest console` filters what the guest prints before it reaches your terminal: text, colours, cursor movement and
erasing pass; window titles, the clipboard, hyperlinks, queries that make the terminal answer, mode changes and resets do
not. `--raw` passes everything unchanged and says so on standard error, for a guest you trust whose full-screen programs
need it; the usual modes are turned off when it ends. Ctrl-] detaches; SIGHUP, SIGINT, SIGQUIT, SIGPIPE and SIGTERM end
the session the same way and put the terminal back (exit status 128 plus the signal); if the client itself crashes,
`stty sane` does. Only that client filters the console: `exec` and the bridge see the guest's raw bytes. `vmr guest exec`
filters its output when standard output is a terminal and writes the bytes exactly as the guest sent them otherwise, so
scripts get them unchanged. A guest can still redraw the visible screen: cursor movement and erasing pass, so what the
screen shows is not proof of what ran. The filter assumes a terminal that reads UTF-8 (C1 controls are removed in both
forms only there).

## The control service from a terminal: `vmr control`

`vmr control` calls the control service of a running app (ADR-0056) as a script or an AI agent would. It never starts the
app by itself. Its tests run it against the library's own service on a socket under `/tmp`, never against the app. Against
the app, use a scratch data directory as for any real run, and treat a start through it as a real-guest run.

```sh
export VMRUNNER_DATA_DIR=/tmp/vmr-owner      # the folder the app was started with; the socket is Control/control.sock in it
chmod 600 token.txt                          # a token made in Settings; a file other users may read is refused
swift run vmr control status --token-file token.txt
swift run vmr control list --token-file token.txt [--json]
swift run vmr control state|start|stop MACHINE --token-file token.txt [--force] [--json]   # MACHINE: an id, or a name
swift run vmr control log MACHINE --token-file token.txt [--bytes N] [--json]   # the end of a container's output log, at most 64 KiB
VMR_CONTROL_TOKEN="$(cat token.txt)" .build/debug/vmr control mcp   # MCP over stdin and stdout, for an agent's settings
```

The token is never an argument: `ps` shows arguments to every user. Exit statuses: 0 done; 1 refused by the service (no
such machine, agent access off, refused); 64 a usage error or no token; 66 the token file cannot be read; 69 nothing
serves the socket; 75 no answer in time (what the call started may still finish); 76 an answer the client cannot read;
77 not permitted (the token lacks the capability, the token file is open to others, or another user serves the socket).

## Developer tooling

The scripts are Swift: `Sources/DevTools` (logic), `Sources/vmr` (the command line, `swift run vmr --help`) and
`Plugins/` (the `swift package check | analyzers | build-app` wrappers). Their tests are `Tests/DevToolsTests`: end to
end, they run the real `vmr` binary against fixture packages, a local fixture analyzer release and temporary git
repositories. They lint with the pinned SwiftLint (installed on first use, or the binary `SWIFTLINT_BIN` names), build real
packages and run in about twenty seconds in parallel. Keep new
tooling in Swift: no shell or Python files. The tooling's two dependencies (swift-subprocess, swift-argument-parser) are pinned with
`exact:`; the app target and its tests must never link them. The app's own packages are listed in ADR-0001, and a test
compares them with `Package.swift`. Every build and test `vmr` starts, and every `swift` command in the workflows, passes
`--only-use-versions-from-resolved-file`: versions come from the committed `Package.resolved` alone, so after a
dependency change run `swift package resolve` and commit the file. The same goes for `VMHelperCore` and `VMHelper`, the
headless helper of the sandbox helper (roadmap 0025): `swift run vmr sandbox run` launches it under App Sandbox or a
Seatbelt profile. Without `--boot` it only probes and validates; `--boot` starts a virtual machine and is for the owner.

The container runner (roadmap 0024) lives in a package of its own, `Packages/Containers`, with its own committed
`Package.resolved`: it links the container library of ADR-0017, pinned with `exact:`, and the packages that brings in, none of
which belongs in the root graph. The root package does not depend on it, and the `packages` key of `.vmr.json` makes
`vmr check build test` cover it. `swift run vmr container-sign` builds and signs the runner; running it boots a virtual
machine, so only its owner does, from `docs/research/containers-2026-10.md`. `swift run vmr container-run --boot` signs it,
makes a scratch directory and runs it with an image, a command, a size and an environment: a real-guest run under the
conditions above (an authorised session, at most 2 CPUs and 2048 MiB, a run-time limit), refused without `--boot`. A new
package copies the root manifest's `// BEGIN shared settings` block verbatim (a test compares them).

`swift run vmr windows drivers verify FILE` checks a driver disc you downloaded against the SHA-256 values pinned in
`Resources/WindowsDriverPins.json`: it prints the matching entry and exits 0, or says "not in the pinned list" and exits 1
(65: the list is unreadable or malformed; 66: the file cannot be read). It reads the file once, read-only, in chunks, and
downloads nothing. The list ships empty on purpose: the owner adds an entry (`sha256`, `name`, `version`, and `notes` with
the source and the date of the file they checked; the value comes from `shasum -a 256 FILE`).

## Continuous integration

Workflows live in `.github/workflows`; every third-party action is pinned to a full commit SHA with a trailing
`# vX.Y.Z` comment (Dependabot keeps them current), and every job declares `timeout-minutes` and least-privilege
`permissions`.

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | push to main, PR, merge queue | `changes` (decides what runs from the diff), `lint` (format, SwiftLint, documentation, workflow lint, policy), `gate` (build and tests, which fails if none ran; coverage; the hardened app bundle; the analyzers), `bench` (the benchmark gate, advisory until it is stable), `sanitizers` (asan, tsan, ubsan; on a PR only when the network stack, the engine, the test support or the dependencies changed). A documentation-only change runs `lint` and nothing else. The aggregate job **CI passed** is the one required check and tolerates skipped jobs |
| `codeql.yml` | push to main, PR, merge queue, weekly | CodeQL for the workflows and (experimental, Swift 6.4 is not yet supported) Swift |
| `zizmor.yml` | `.github/**` changes, merge queue, weekly | actionlint and zizmor on the workflows |
| `dependency-review.yml` | PR | fails a PR that adds a dependency with a high severity advisory |
| `scorecard.yml` | push to main, weekly | OpenSSF Scorecard into code scanning |
| `cache-cleanup.yml` | PR closed, weekly | deletes a closed PR's caches and keeps the newest caches within 8 GiB |
| `release.yml` | tag `v*` | checks CI passed on the commit and no placeholder is left, builds, attests (public repository only) and publishes a release |

`codeql.yml`, `scorecard.yml` and `dependency-review.yml` need a public repository or GitHub Advanced Security.
Build caches are restored by every run and saved only on main, on an exact-key miss. The local `swift run vmr check
--full` runs the same steps as CI.

## Releasing

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the new version and merge it to main through a PR.
2. Re-check every pinned vendor key (`PGP.PinnedKeys`) against its vendor's own page: the fingerprint, whether it was revoked,
   and when it expires (its `expires` field; `nil` means the vendor set none). `PGPKeyExpiryTests` fails 90 days before a pinned
   key expires: pin the vendor's next key, with a real signature from it as a test fixture, before then.
3. Wait for CI on main, then tag that commit and push the tag: `git tag -s vX.Y.Z && git push origin vX.Y.Z`.
4. `release.yml` refuses a tag that is not `vMAJOR.MINOR.PATCH[-prerelease]`, is not on main, is on a commit without a
   successful `CI` run (`gh run list --commit`), or differs from the built bundle's version, and it refuses while
   `vmr check publication` finds a placeholder. It builds `swift run vmr build-app release --hardened` and zips with
   `ditto`. The `build` job reports the zip's SHA-256 as a job output; the `publish` job compares the downloaded zip with
   that output (not with a file inside the artifact), then writes the release's `.sha256` asset from it.
5. **What is attested, and when.** The zip, and only the zip, gets a build provenance attestation from the `publish` job
   (verify with `gh attestation verify VMRunner-vX.Y.Z.zip --repo OWNER/REPO`), and only while the repository is public:
   attestations need a public repository or GitHub Enterprise Cloud, so on a private repository the job logs a notice and
   the release carries no attestation. The attestation names the workflow run and the tag that produced the digest; it
   is not attached to the `.sha256` asset or the generated notes, and it is not a notarization. The job that attests runs
   no repository build code, which is why the attestation is not made inside `build`.
6. The release is created with generated notes, the zip and its `.sha256`.

The app is ad-hoc signed, not Developer ID signed or notarized: whether the virtualization entitlement works under a
Developer ID signature is unverified, so signing is not wired yet.

## Publication checklist

The repository is private and two values are placeholders on purpose; ordinary CI and `vmr check --full` pass with them.
`release.yml` runs `swift run vmr check publication` before it builds, and that step fails while either is left, so a
release cannot ship with them. Before the first release:

1. Replace `@OWNER` in `.github/CODEOWNERS` with the maintainer handle or team (GitHub ignores an owner it cannot
   resolve, so until then nothing requires an owner's review).
2. Replace the `com.example.` bundle identifier (`CFBundleIdentifier` in `Resources/Info.plist`) with the real one.
3. Replace `OWNER/REPO` in the commands this file and the README show.
4. Apply the repository settings below.

## Repository settings (once the repository is on GitHub)

These cannot be set from the repository's files; the owner applies them once.

- **Ruleset on `main`** (Settings > Rules): require a pull request with CODEOWNERS review (`.github/CODEOWNERS`);
  require the status check **CI passed**; require linear history; require signed commits; block force pushes and
  deletion; enable the **merge queue** (CI, CodeQL and the workflow lint already trigger on `merge_group`). Add a tag
  ruleset for `v*` that restricts who can create and delete release tags.
- **Actions** (Settings > Actions > General): allow only actions pinned to a full-length commit SHA ("Require actions
  to be pinned to a full-length commit SHA"); set the default workflow token to read-only and do not let workflows
  approve pull requests; require approval for workflows from outside collaborators.
- **Code security** (Settings > Advanced Security): enable secret scanning with push protection, Dependabot alerts
  and security updates, private vulnerability reporting (`SECURITY.md` relies on it), and code scanning.

## Pull requests

Keep changes small and focused, add or update tests for behavior changes, and describe the user-visible effect.
Report security issues privately, as described in `SECURITY.md`, not in a pull request.
