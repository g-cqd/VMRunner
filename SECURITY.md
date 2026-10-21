# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately**. Do not open a public issue or pull request for them.

Use GitHub's private vulnerability reporting: on the repository page open **Security > Advisories >
Report a vulnerability**. That opens a draft security advisory visible only to you and the maintainers.
If that option is not available to you, contact the maintainer through the e-mail address on their GitHub
profile and ask for a private channel before sending details.

A useful report has: the affected version or commit, the macOS version and hardware, what an attacker needs
(a malicious guest, a malicious catalog or mirror response, a malicious machine bundle on disk, local access),
steps or a proof of concept, and the impact you observed. Expect an acknowledgement within a few days;
this is a small project, so there is no formal SLA. Fixes are developed in the private advisory and credited to
you unless you ask otherwise.

## Supported versions

Only the latest commit on the default branch is supported. There are no maintained release branches.

## Scope

In scope:

- **The app (VMRunner.app).** Memory-safety bugs, privilege or entitlement misuse, unsafe handling of
  machine bundles and configuration files in `~/Library/Application Support/VMRunner`, command-line
  argument handling (`--start`), crashes reachable from untrusted input.
- **The download policy.** Anything that lets a catalog response (ipsw.me, CentOS mirror listings, Apple
  restore catalogs) or a redirect make the app fetch from a host outside the allow-list, over plain HTTP or a
  non-standard port, write outside the image cache, skip or weaken checksum verification (IPSW SHA-256 from
  ipsw.me, ISO `.SHA256SUM` from the mirror), or accept an oversized response.
- **The VM isolation claims.** The security profiles (Standard, Contained, Isolated, Hardened) promise that
  specific host-guest channels are off: network, clipboard, Rosetta, nested virtualization, vsock, microphone,
  sound output, shared folders and extra disks, memory balloon, suspend, runtime limit, disposable disk. A
  profile that leaves a channel open which the UI or README says is closed, or a setting that is not actually
  applied to the `VZVirtualMachineConfiguration`, is a vulnerability.
- **Build and signing scripts and CI.** `Scripts/build-app.sh` entitlement handling (for example
  `get-task-allow` or unexpected entitlements ending up in a release build), the pinned analyzer downloads in
  `Scripts/analyzers.sh`, and workflow permissions or injection issues in `.github/workflows`.

Not in scope:

- **Escapes from the guest through Apple's Virtualization framework or the hypervisor itself.** Report those
  to Apple (https://security.apple.com). VMRunner narrows the host-guest channels; it does not make an
  untrusted guest safe on its own, and the README says so.
- Attacks that need an already-compromised host account, root, or a disabled System Integrity Protection.
- Vulnerabilities in the guest operating systems (macOS, CentOS Stream) or in software run inside a guest.
- Denial of service by a user who can already run arbitrary code as the same user (for example filling the
  disk with a large VM).
- The ad-hoc signature itself: builds are signed with an ad-hoc identity for local use, not notarized or
  distributed. Gatekeeper and notarization behaviour are not a VMRunner vulnerability.
- Features documented as not included (bridged networking, USB passthrough, ASIF images).
- Findings from automated scanners without a demonstrated impact.
