---
status: proposed
date: 2026-10-21
---
# 0012 — Provisioning starts with a cloud init seed

## Context

Users want to install from an ISO and run scripts at install steps, compatible with Kubernetes tooling. The framework has
no kernel arguments under UEFI, no `fw_cfg` and no guest agent.

## Decision

1. The main carrier is a cloud-init NoCloud seed: a read-only `cidata` volume attached as USB mass storage.
2. Installer seed media follow by label: `OEMDRV` for Fedora-family kickstart and openSUSE AutoYaST, `cidata` for Ubuntu
   autoinstall, a repacked ISO for Debian preseed.
3. A small vsock agent runs steps, reports progress and delivers secrets. Secrets never go in the seed.
4. The user-facing spec is a Kubernetes-style envelope with Lima-style steps, compiled to cloud-init, with the
   `cloudInit` section passed through under KubeVirt's field names.
5. Every script file carries a SHA-256 checked on the host.

## Consequences

Nothing is built. Each step needs a real guest run before its help may say it works. See `docs/research/provisioning-2026-10.md`.

2026-10-23: items 4 and 5 and the seed's contents are built as a library, `Sources/Provisioning`, with nothing linking it
yet and nothing run in a guest. The input is a strict subset of YAML read without a dependency; the seed is an ISO 9660
image with Joliet names written by the library, reproducible to the byte, rather than `hdiutil makehybrid`, whose output
differs from run to run and which would be a subprocess of the app. Item 1's attachment, item 2 and item 3 are not built;
roadmap 0016 lists what remains.

## What this does not decide

Whether to repack ISOs or boot the kernel directly for installers that insist on a kernel argument; both are unverified.
