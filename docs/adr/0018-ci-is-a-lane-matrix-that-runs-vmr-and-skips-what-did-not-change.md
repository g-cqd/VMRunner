---
status: accepted
date: 2026-10-21
---
# 0018 — CI is a lane matrix that runs vmr and skips what did not change

## Context

A mature reference pipeline was reviewed before designing this one. What it did well: least-privilege permissions, a
concurrency group that never cancels the main branch, per-job time limits, a published benchmark summary. What was wrong
with it, and which this repository's first workflow partly repeated:

- A shared workflow and a composite action referenced at a moving branch (`@main`): the pipeline changes under you.
- Third-party actions pinned by tag, not by commit.
- The same checkout, toolchain and cache boilerplate repeated in six jobs.
- Cache keys that hash every source file, so each commit creates a cache and the quota churns.
- A path filter on the whole workflow, so a documentation-only pull request never reports the required check.
- Every job waits for the slowest one (`needs`), which lengthens the run for no dependency reason.
- Several jobs that can never fail the build (`continue-on-error`), which are noise by construction.
- Multi-line shell inside YAML, untestable.
- No single aggregate check to require, so a ruleset must list jobs that are sometimes skipped.

## Decision

1. Every job runs `swift run vmr ...`; the workflow only decides where and when. Analyzers run through `vmr check analyzers`,
   so the lock file is the one place their versions live and there is no second pin to keep equal.
2. Lanes that differ only in the command and the cache are one matrix job. There are three job definitions (lint, gate,
   sanitizers), a change detector and the aggregate.
3. The change detector uses `git diff` against the base, no third-party action. Documentation-only changes run lint (which
   includes the documentation check) and nothing else. Sanitizers run on a pull request only when the network stack, the
   engine, the test support or the dependencies changed, and always on main, merge groups and manual runs. A diff that cannot
   be computed runs everything.
4. Caches are restored everywhere and saved only from main on an exact-key miss; keys hash the manifest and the lock file,
   not the sources.
5. One required check, `CI passed`, fails on a failed or cancelled job and tolerates skipped ones.
6. Every action is pinned to a commit with its version in a comment; the workflows pass `actionlint` and `zizmor`.

## Consequences

Heavy macOS minutes are not spent on documentation. The jobs run in parallel. The change detector's regexes live in the
workflow; moving them into `vmr` would make them testable and is the next step if they grow.

## What this does not decide

A pinned SwiftLint (it still comes from Homebrew), a benchmark or allocation regression gate, and Developer ID signing.
