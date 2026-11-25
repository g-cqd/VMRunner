# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately**. Do not open a public issue or pull request for them.

Use GitHub's private vulnerability reporting: on the repository page open **Security > Advisories >
Report a vulnerability**. That opens a draft security advisory visible only to you and the maintainers.
If that option is not available to you, contact the maintainer through the e-mail address on their GitHub
profile and ask for a private channel before sending details.

A useful report has: the affected version or commit, the macOS version and hardware, what an attacker needs
(a malicious guest, a malicious catalog or mirror response, a malicious machine bundle on disk, local access),
steps or a proof of concept, and the impact you observed.

## Response targets (SLAs)

| Milestone | Target |
| --- | --- |
| Private acknowledgement | Within **3 working days** |
| Initial triage & severity confirmation | Within **7 calendar days** |
| Fix & advisory — **Critical** | Within **7 calendar days** |
| Fix & advisory — **High** | Within **30 calendar days** |
| Fix — **Medium / Low** | Next scheduled release |

Security fixes in released versions are published with a GitHub Security Advisory (and CVE identifier where applicable)
and named in the release notes.

## Supported versions

Only the latest release line on the default branch is supported.

## Scope

In scope:

- **The app (VMRunner.app) and App-Sandboxed helper (VMHelper).** Memory-safety bugs, privilege or entitlement misuse,
  unsafe handling of machine bundles and configuration files in `~/Library/Application Support/VMRunner`, command-line
  argument handling (`--start`), crashes reachable from untrusted input.
- **The user-mode network stack (`NetStack`) and egress policy (`NetPolicy`).** DNS rebinding, non-canonical IP
  spellings, reserved/metadata/private-range bypasses, memory exhaustion, or flow-table leaks.
- **The control service (`ControlProtocol`, `AgentBridge`).** Peer-UID spoofing, expired/revoked/out-of-scope token
  acceptance, log/screenshot size-cap bypasses, or secret leakage into logs.
- **The download policy.** Anything that lets a catalog response (ipsw.me, Linux mirrors, Apple restore catalogs) or a
  redirect make the app fetch from a host outside the allow-list, over plain HTTP or a non-standard port, write outside
  the image cache, downgrade past a provider version floor, skip checksum/OpenPGP verification, or accept an oversized
  response.
- **The VM isolation claims.** The security profiles (`Standard`, `Contained`, `Isolated`, `Hardened`, `Agent`) promise
  that specific host-guest channels are off. A profile that leaves a channel open which the UI, threat model, or README
  says is closed, or a setting that is not actually applied to `VZVirtualMachineConfiguration`, is a vulnerability.
- **Build and signing scripts and CI.** `vmr build-app` (`Sources/DevTools/App`) entitlement handling, pinned analyzer
  downloads in `vmr analyzers`, and workflow permissions or injection issues in `.github/workflows`.

Not in scope:

- **Escapes from the guest through Apple's Virtualization framework or the hypervisor itself.** Report those to Apple
  (https://security.apple.com). VMRunner narrows the host-guest channels; it does not make an untrusted guest safe on
  its own, and `docs/security/threat-model.md` records this residual risk explicitly.
- Attacks that need an already-compromised host account, root, or disabled System Integrity Protection.
- Vulnerabilities inside guest operating systems or software run inside a guest.
- Findings from automated scanners without a demonstrated impact.
