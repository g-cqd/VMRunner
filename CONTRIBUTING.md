# Contributing

## Setup

Requirements: an Apple silicon Mac on macOS 26 or later and Xcode 27 (Swift 6.4), which ships swift-format. SwiftLint
needs no install: `vmr` downloads the release pinned in `Scripts/analyzers.lock` the first time a step or the hook needs it.

```sh
swift run vmr hooks install           # pre-commit: format lint and SwiftLint on staged Swift files
```

## Before you push: `swift run vmr check`

```sh
swift run vmr check                 # fast gate: format, swiftlint, docs, build, test, analyzers
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
- **Job summary.** With `GITHUB_STEP_SUMMARY` set (GitHub Actions does), `vmr check` appends a table of the steps
  (result, duration) to that file, plus test counts, coverage and analyzer findings when the steps ran. Nothing changes
  when it is unset.

The three static analyzers (retain cycles, duplicate code, dead code) and SwiftLint come from pinned, checksum-verified
releases listed in `Scripts/analyzers.lock`; `swift run vmr analyzers` downloads the analyzers, and the first
`swift run vmr check swiftlint` (or the first commit with the hook) downloads SwiftLint, into the git-ignored `.tools/`.
CI runs the same `swift run vmr check` steps, so the lock is the only place the versions are written. See the
"Quality gates" section of the README for what each analyzer gates on.

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
Do not start virtual machines from automated checks.

## Developer tooling

The scripts are Swift: `Sources/DevTools` (logic), `Sources/vmr` (the command line, `swift run vmr --help`) and
`Plugins/` (the `swift package check | analyzers | build-app` wrappers). Their tests are `Tests/DevToolsTests`: end to
end, they run the real `vmr` binary against fixture packages, a local fixture analyzer release and temporary git
repositories. They lint with the pinned SwiftLint (installed on first use, or the binary `SWIFTLINT_BIN` names), build real
packages and run in about twenty seconds in parallel. Keep new
tooling in Swift: no shell or Python files. The two dependencies (swift-subprocess, swift-argument-parser) are pinned with
`exact:`; the app target and its tests must never link them. The same goes for `VMHelperKit` and `VMHelper`, the
headless helper of the sandbox spike (roadmap 0025): `swift run vmr sandbox-spike run` launches it under App Sandbox or a
Seatbelt profile. Without `--boot` it only probes and validates; `--boot` starts a virtual machine and is for the owner.

## Continuous integration

Workflows live in `.github/workflows`; every third-party action is pinned to a full commit SHA with a trailing
`# vX.Y.Z` comment (Dependabot keeps them current), and every job declares `timeout-minutes` and least-privilege
`permissions`.

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | push to main, PR, merge queue | `changes` (decides what runs from the diff), `lint` (format, SwiftLint, documentation), `gate` (build and tests, which fails if none ran; coverage; the hardened app bundle; the analyzers), `bench` (the benchmark gate, advisory until it is stable), `sanitizers` (asan, tsan, ubsan; on a PR only when the network stack, the engine, the test support or the dependencies changed). A documentation-only change runs `lint` and nothing else. The aggregate job **CI passed** is the one required check and tolerates skipped jobs |
| `codeql.yml` | push to main, PR, merge queue, weekly | CodeQL for the workflows and (experimental, Swift 6.4 is not yet supported) Swift |
| `zizmor.yml` | `.github/**` changes, merge queue, weekly | actionlint and zizmor on the workflows |
| `dependency-review.yml` | PR | fails a PR that adds a dependency with a high severity advisory |
| `scorecard.yml` | push to main, weekly | OpenSSF Scorecard into code scanning |
| `cache-cleanup.yml` | PR closed, weekly | deletes a closed PR's caches and keeps the newest caches within 8 GiB |
| `release.yml` | tag `v*` | builds, attests and publishes a release |

`codeql.yml`, `scorecard.yml` and `dependency-review.yml` need a public repository or GitHub Advanced Security.
Build caches are restored by every run and saved only on main, on an exact-key miss. The local `swift run vmr check
--full` runs the same steps as CI.

## Releasing

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the new version and merge it to main through a PR.
2. Wait for CI on main, then tag that commit and push the tag: `git tag -s vX.Y.Z && git push origin vX.Y.Z`.
3. `release.yml` refuses a tag that is not `vMAJOR.MINOR.PATCH[-prerelease]`, is not on main, or differs from the
   built bundle's version. It builds `swift run vmr build-app release --hardened`, zips with `ditto`, attests the zip
   (verify with `gh attestation verify VMRunner-vX.Y.Z.zip --repo OWNER/REPO`) and creates the release with generated
   notes, the zip and its `.sha256`.

The app is ad-hoc signed, not Developer ID signed or notarized: whether the virtualization entitlement works under a
Developer ID signature is unverified, so signing is not wired yet.

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
