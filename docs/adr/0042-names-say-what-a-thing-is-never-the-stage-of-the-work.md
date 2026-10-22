---
status: accepted
date: 2026-10-22
---
# 0042 — Names say what a thing is, never the stage of the work

## Context

Parts of the tree carried the stage of the work in their names (a container "spike", a sandbox "spike" command) and a
mix of suffixes: `TestKit`, `VMHelperKit`, `CTestKitMalloc` beside modules with no suffix at all. A name outlives the
stage: the first run of a prototype becomes the product, and the name then lies.

## Decision

1. No planning word (spike, prototype, poc, experiment, draft, wip) appears in an identifier, directory, file name, product,
   command or flag. Prose may say what has and has not been verified.
2. No grab-bag suffix (`Kit`, `Util`, `Helper`, `Manager`). A library is named for the capability it provides.
3. The testable logic of an executable is `<Executable>Core`. A product name that states a real process role stays
   (`VMHelper` is a helper process).
4. A module is never named like an Apple framework (`Network`) or like its main type (`NetworkPolicy`).
5. Packages are named for a capability, targets for what they contain; tests are `<Target>Tests`.
6. Renames are mechanical commits of their own, made when no open branch imports the old name.

## Consequences

Done: `VMHelperKit` to `VMHelperCore`, `ContainerSpike` to `ContainerRunner`, `vmr sandbox-spike` to `vmr sandbox`,
`vmr spike-sign` to `vmr container-sign`. To do: `TestKit` to `TestSupport` and `CTestKitMalloc` to `CTestSupportMalloc`,
after the test-support sync (roadmap 0031, 0032). Commit subjects of earlier history are not rewritten.

## What this does not decide

The names of packages that do not exist yet beyond those in roadmap 0032.
