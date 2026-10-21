# Contributing

## Setup

Requirements: an Apple silicon Mac on macOS 26 or later, Xcode 27 (Swift 6.4), and the lint tools:

```sh
brew install swiftlint                # swift-format ships with the Xcode toolchain
swift run vmr hooks install           # pre-commit: format lint and SwiftLint on staged Swift files
```

## Before you push: `swift run vmr check`

```sh
swift run vmr check                 # fast gate: format, swiftlint, build, test, analyzers
swift run vmr check --full          # + ASan, TSan, UBSan test runs, release build, coverage gate
swift run vmr check test analyzers  # only the named steps (swift run vmr check --list shows them all)
```

Every step runs even if an earlier one fails; each prints PASS or FAIL and the command exits non-zero if any
failed. CI runs the same commands, so a green local run is a green CI run (minus the hosted-runner limits noted
in `.github/workflows/ci.yml`).

The three analyzers (arcleak, dolly, deadwood) come from pinned, checksum-verified releases listed in
`Scripts/analyzers.lock`; `swift run vmr analyzers` downloads them into the git-ignored `.tools/`. See the
"Quality gates" section of the README for what each one gates on.

- **A new analyzer finding is a failure.** Fix it, or accept it deliberately: `// @al:accept -- reason`
  (arcleak), `// @dl:accept -- reason` (dolly), `// @dw:accept -- reason` (deadwood), always with a reason.
- **Baselines (`.arcleak-baseline.json`, `.dolly-baseline.json`, `.deadwood-baseline.json`) record accepted
  debt and ship empty.** Never regenerate them to silence a new finding. When you pay debt down, run
  `swift run vmr analyzers baseline arcleak dolly deadwood` and commit the smaller file. Fingerprints include
  positions, so a large refactor can move baselined findings out of the baseline; fix them or regenerate deliberately in a separate commit.
- **Coverage is a ratchet.** `coverage.minimum` in `.vmr.json` (and `COVERAGE_MIN`) only goes up.

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

`vmr build-app` reads the effective entitlements back from the signed bundle and fails if `get-task-allow` or any
unexpected entitlement is present. Do not start virtual machines from automated checks.

## Developer tooling

The scripts are Swift: `Sources/DevTools` (logic), `Sources/vmr` (the command line, `swift run vmr --help`) and
`Plugins/` (the `swift package check | analyzers | build-app` wrappers). Their tests are `Tests/DevToolsTests`: end to
end, they run the real `vmr` binary against fixture packages, a local fixture analyzer release and temporary git
repositories. They need `swiftlint` on `PATH`, build real packages and run in about twenty seconds in parallel. Keep new
tooling in Swift: no shell or Python files. The two dependencies (swift-subprocess, swift-argument-parser) are pinned with
`exact:`; the app target and its tests must never link them.

## Pull requests

Keep changes small and focused, add or update tests for behavior changes, and describe the user-visible effect.
Report security issues privately, as described in `SECURITY.md`, not in a pull request.
