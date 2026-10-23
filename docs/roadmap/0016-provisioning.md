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

`Sources/GuestSeed`, a library target of the root package that links the system frameworks only (a test in
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
  each script travels base64-encoded and runs from `/var/lib/cloud/vmrunner` with its values (not `/run`, which some images
  mount `noexec`; not checked here). With the spec's own `userData`, the `user-data` is a two-part MIME document whose second part
  appends its lists to the first (a `Merge-Type` header). Neither the script folder nor the merge has run in a guest. `meta-data` carries an
  instance identifier the caller gives, and the host name. Output is the same for the same input (golden tests).
- **Refused until built:** installer phases (`pre-install`, `post-install`, `install-error`), `ready` and `pre-shutdown`,
  `user: user`, and any `secretRef` (a secret never goes in the seed; it waits for the vsock agent).
- **The image.** An ISO 9660 volume labelled `cidata` with Joliet names, written in memory by the library (the same seed
  always gives the same bytes), saved read-only. The system's `tar` lists and extracts its files in the tests.
  `hdiutil makehybrid` was measured as the alternative: it builds a readable image but two runs differ in their dates, and
  it would be a subprocess of the app.
- **Limits.** 64 KiB of spec, 32 steps, 64 KiB per script file, 8 levels of nesting, each tested at its boundary with the limits lowered.

## Built so far (2026-10-23): the seed attached to a Linux machine, experimental

The app links `Sources/GuestSeed`. Every part is tested on the host; none of it has run in a guest, so the help says
"experimental".

- **The setting.** A Linux machine has a provisioning spec path: absolute, at most 1024 bytes, checked where the
  configuration is read, approved like the installer image (one read-only approval, which covers the script files below the
  spec's folder). It is in use only while the installer is not attached, since an installer's live system would run the
  steps too.
- **At each start** the app reads the spec (a regular file, 64 KiB at most), checks its script files against their SHA-256,
  compiles the seed with the machine's identifier as the instance identifier, and writes it into the machine's bundle
  (`ProvisioningSeed.iso`, readable by its owner only). A spec that cannot be used stops the start with its line. The seed
  is attached as a read-only USB mass storage device after the disks, and removed with the run's other leftovers when the
  machine stops; a disposable machine gets a new one at each start, like every machine.
- **Saved state.** A suspended machine resumes only with the seed it was saved with. An edit that adds, removes or moves the
  spec drops the saved state, and so does a seed whose contents changed: the digest of the last seed is kept in the bundle
  (`ProvisioningSeed.sha256`). The machine then boots afresh.
- **Posture.** The Isolated and Hardened profiles remove the spec; the exposure summary lists it while it is in use; the
  managed key `AllowProvisioning` removes it from every machine and locks the chooser.
- **Editor and help.** A *Provisioning (experimental)* section chooses, checks and removes the spec; the check lists each
  step with its line, phase and digest, or the refusal with its line. The help topic is marked experimental.
- **USB, not virtio.** cloud-init finds the volume by its label on any block device; USB is what ADR-0012 decided, the bus
  the app already boots installers from, and the device that can later be detached while the machine runs. A guest kernel
  without USB storage would not see it: the first guest run says.

## Remaining

Each item needs a real guest run before its help may drop "experimental".

1. The first real-guest run with a cloud image: that cloud-init finds the read-only USB volume and its Joliet names, runs
   `bootcmd`, `runcmd` and the per-boot script from `/var/lib/cloud/vmrunner`, finds `base64`, and merges the two-part
   document. If the image's kernel has no USB storage, the seed moves to a read-only virtio disk. Detaching the seed after
   the first boot is not built.
2. Installer seed media, one distribution at a time: `OEMDRV` for the Fedora family and openSUSE, `cidata` plus the
   `autoinstall` prompt for Ubuntu, a repacked ISO for Debian preseed.
3. The vsock agent: `ready` and `pre-shutdown`, steps run as the user, secrets delivered at run time (a secret never goes
   into the seed), the guest-side re-check of each script's SHA-256, and Ignition on vsock port 1024.
