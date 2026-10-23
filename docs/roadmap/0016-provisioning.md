---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0012
---
# 0016 — Unattended installs and scripts at install steps, Kubernetes-compatible

Study: `docs/research/provisioning-2026-10.md`. Build in order: spec parser and seed builder, installer seed media, vsock agent.

## Done when

A cloud image boots with a generated seed, runs a `first-boot` script whose hash the host checked, and reports `ready`.

## Built so far (2026-10-23): the spec, the seed's files and its image, as a library

`Sources/Provisioning`, a library target of the root package that links the system frameworks only (a test in
`DevToolsTests` checks it). Nothing links it yet, so nothing of it is visible in the app, and none of it has run in a guest.

- **The spec.** A document with `apiVersion: vmrunner.dev/v1alpha1`, `kind: Provisioning`, `metadata.name` (a DNS label,
  the guest's host name) and a `spec` holding `cloudInit` (`userData`, `userDataBase64`, `networkData`,
  `networkDataBase64`, passed through) and `provision`, ordered steps with `at`, `user`, `script` or `file` with `sha256`,
  and `env` (a value, or a `secretRef` kept apart from values). Unknown keys are refused.
- **The reader.** A strict subset of YAML: block maps and lists, one-line plain and quoted values, `|` and `|-` blocks
  (whose text may hold tabs), comments. Anything else (tabs elsewhere, CR, a byte order mark, `---`, directives, anchors,
  aliases, tags, flow collections, `>` and `|+`, a plain value holding `: `, a key given twice) is refused with its line.
  Every value stays text.
- **The host check.** Every `file:` script is read once, at most 64 KiB, and must match its SHA-256; a missing file, a
  folder or a symbolic link is refused. Only checked bytes reach the compiler.
- **The compiler.** `early-boot` becomes a `bootcmd` entry, `first-boot` a `runcmd` entry, `every-boot` a per-boot script;
  each script travels base64-encoded and runs from `/var/lib/cloud/vmrunner` with its values (not `/run`, which Debian
  and Ubuntu mount `noexec`). With the spec's own `userData`, the `user-data` is a two-part MIME document whose second part
  appends its lists to the first (a `Merge-Type` header). Neither the script folder nor the merge has run in a guest. `meta-data` carries an
  instance identifier the caller gives, and the host name. Output is the same for the same input (golden tests).
- **Refused until built:** installer phases (`pre-install`, `post-install`, `install-error`), `ready` and `pre-shutdown`,
  `user: user`, and any `secretRef` (a secret never goes in the seed; it waits for the vsock agent).
- **The image.** An ISO 9660 volume labelled `cidata` with Joliet names, written in memory by the library (the same seed
  always gives the same bytes), saved read-only. The system's `tar` lists and extracts its files in the tests.
  `hdiutil makehybrid` was measured as the alternative: it builds a readable image but two runs differ in their dates, and
  it would be a subprocess of the app.
- **Limits.** 64 KiB of spec, 32 steps, 64 KiB per script file, 8 levels of nesting, each tested at its boundary.

## Remaining

Each item needs a real guest run before its help may drop "experimental".

1. Attach the seed to a Linux machine as a read-only USB mass storage device, built per start into the machine bundle's
   cache; choose the instance identifier (the machine's identifier is the obvious one) and detach the seed after the first
   boot where the distribution allows. The first guest run checks what the tests could not: that cloud-init finds the volume
   and its Joliet names, and runs `bootcmd`, `runcmd`, the per-boot script and the merged multi-part document.
2. An editor section to pick the spec file, with its help topic marked experimental.
3. The posture: the seed in the machine's exposure summary ("what can the guest reach": a seed tells the guest things), and
   the help topic saying what the guest can read from it.
4. Installer seed media, one distribution at a time: `OEMDRV` for the Fedora family and openSUSE, `cidata` plus the
   `autoinstall` prompt for Ubuntu, a repacked ISO for Debian preseed.
5. The vsock agent: `ready` and `pre-shutdown`, steps run as the user, secrets delivered at run time, the guest-side
   re-check of each script's SHA-256, and Ignition on vsock port 1024.
