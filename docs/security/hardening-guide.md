# VMRunner — Enterprise Hardening Guide (as of 2026-11-25)

Status: **accepted** (R-OPS-2, R-OPS-3; complements `docs/security/threat-model.md` and `SECURITY.md`).

## 1. Recommended MDM Profile for Autonomous Agent Hosts (`V9`)

Push a macOS configuration profile targeting `VMRunner`'s bundle identifier with the following administrator-forced keys
(`ManagedKey`, read strictly via `UserDefaults.objectIsForced(forKey:)`):

| Key | Recommended Value | Effect |
|---|---|---|
| `AllowSharedFolders` | `false` | Disables VirtioFS host folder sharing across all machines |
| `AllowClipboardSharing` | `false` | Disables host-guest clipboard sync |
| `AllowMicrophone` | `false` | Disables audio capture inside guests |
| `AllowSuspend` | `false` | Forbids writing VM RAM state files to disk |
| `AllowHostInformation` | `false` | Disables battery, timezone, and host-identity passthrough |
| `AllowCustomGPU` | `false` | Forces Apple's built-in graphics device |
| `AllowPrivateInterfaces` | `false` | Closes all private Virtualization interfaces |
| `AllowUnfilteredNAT` | `false` | Forbids raw NAT; clamps to allow-listed filtered networking + private-range blocking |
| `RequirePrivateRangeBlock` | `true` | Forces RFC-1918 / loopback / metadata blocking on every filtered network |
| `RequireDisposableMachines` | `true` | Forces every VM to discard disk changes on stop (`ephemeral = true`) |
| `MaxRuntimeMinutes` | `120` | Hard wall-clock cap per run (15–1440 min; malformed values fail closed to 15 min) |

## 2. Control Plane & Capability Tokens (`V8` / `N-V5`)

- `control.sock` lives in a `0700` directory and verifies `LOCAL_PEERCRED` peer UID on every connection.
- Tokens are stored only as SHA-256 digests (`0600`), compared in constant time, scoped to explicit capabilities and
  machine UUIDs, and expire automatically after **30 days** by default (`ControlTokenStore.defaultLifetime`).
- Denials (including `.expiredToken`, `.outsideScope`, `.missingCapability`, `.agentAccessOff`) are emitted via
  `os.Logger` with redacted token IDs and never log plaintext secrets.

## 3. Name-Authoritative Filtered Egress (`V2` / `V3`)

- Use the **`Agent`** security preset (`SecurityProfile.agent`) for autonomous coding agents: disposable disk, zero
  shared folders/clipboard/hostInfo/private interfaces, 2-hour runtime cap, allow-listed filtered networking, and
  private-range blocking.
- For zero-NIC guests over vsock, `NetStack.ConnectProxyAuthorizer` validates `CONNECT host:port` request lines,
  resolves names host-side, evaluates every resolved address through `NetworkPolicy`, and returns the exact pinned
  addresses to dial (preventing DNS rebinding and raw-IP bypasses).
