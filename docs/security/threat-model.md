# VMRunner — STRIDE Threat Model (as of 2026-11-25)

Status: **accepted** (closes N-V6 / V12 / R-GOV-1). Single authoritative STRIDE threat model for `VMRunner.app`, the
App-Sandboxed `VMHelper` process, the `NetStack`/`NetPolicy` user-mode network engine, the `ControlProtocol` local
socket & `AgentBridge` MCP server, and the image/catalog downloader. Open backlog items live in
`docs/roadmap/0034-security-backlog.md`.

## 1. Assets

| # | Asset | Where | Primary protection |
|---|---|---|---|
| A1 | Host files, Keychains, credentials, and sibling apps | macOS host user account | Hardware virtualization (`Virtualization.framework`), App-Sandboxed `VMHelper`, disabled shared folders / clipboard / hostInfo under `Isolated` / `Hardened` / `Agent` |
| A2 | Host LAN, loopback services, and cloud metadata endpoints | `127.0.0.0/8`, `169.254.169.254`, `192.168.64.0/24`, RFC 1918, ULA | `NetPolicy` built-in floor (cannot be lifted) + `blockPrivateRanges` + pinned resolved IP dialing in `NetStack` |
| A3 | Control-plane capability tokens | `~/Library/Application Support/VMRunner/control/tokens.json` (`0600`) | SHA-256 digests only (never plaintext secrets), constant-time verification, per-capability & per-machine scope, default 30-day expiry (`expiresAt`), peer-UID verification (`LOCAL_PEERCRED`), denial logging without secrets |
| A4 | Guest OS images & golden bases | `ImageStore` cache & machine bundles | `DownloadPolicy` host allow-list, HTTPS-only, size caps, OpenPGP pinned vendor keys (`PGP.PinnedKeys`), SHA-256 verification, provider version floors (`minimumVersion`) |
| A5 | Organisation security posture | Managed preferences (`ManagedKey` via `UserDefaults.objectIsForced`) | Mandatory `ManagedPreferences.clamp(_:)` overriding user settings; invalid forced types fail closed |

## 2. Trust Boundaries

1. **Guest OS ↔ Hypervisor / `VMHelper` (App Sandbox):** Untrusted guest code (including autonomous AI agents) talks
   only to virtualized devices; `VMHelper` runs per-workload inside macOS App Sandbox.
2. **Guest NIC ↔ `NetStack` / `NetPolicy`:** Every Ethernet/IP/TCP/UDP/DNS frame from the guest is treated as hostile
   wire input; DNS answers are folded and pinned to the exact evaluated IP before `connect()`.
3. **Local process / AI agent ↔ `ControlService` (`control.sock`):** Private `0700` folder, `LOCAL_PEERCRED` UID check,
   capability + machine-scoped expiring tokens, bounded request/response lengths.
4. **Remote mirrors / catalogs ↔ `DownloadPolicy` / `PGP`:** Third-party catalogs (ipsw.me) supply checksums/metadata
   only, never download hosts; Linux distributions enforce OpenPGP signatures + version floors.
5. **Virtualization private interfaces & custom GPU (`PrivateInterfaces`, `VirtioGPU`) ↔ Guest:** Closed under
   `Isolated`, `Hardened`, `Agent`, `AllowPrivateInterfaces = false`, and `DisablePrivateInterfaces = true`.

## 3. STRIDE Analysis

| Category | Threat | Boundary | Mitigation today | Residual risk / planned work |
|---|---|---|---|---|
| **Spoofing** | Local process impersonates authorised agent on `control.sock` | Boundary 3 | `0700` socket dir, `LOCAL_PEERCRED` UID check, 256-bit `vmrc_` tokens compared in constant time | Token rotation guidance; audit export (`V7`) |
| **Spoofing** | Guest spoofs `Host`/SNI to bypass domain allow-list or triggers DNS rebinding | Boundary 2 | `NetPolicy` evaluates all resolved IPs (including IPv4-in-IPv6 forms) and `NetStack` connects strictly to the evaluated IP | Name-authoritative `CONNECT` proxy over vsock (`V2`) |
| **Tampering** | Mirror or MITM serves tampered or downgraded installer ISO | Boundary 4 | HTTPS-only allow-listed hosts, pinned OpenPGP keys (Debian, Alpine, AlmaLinux, Rocky, Ubuntu, Fedora), SHA-256 verification, `minimumVersion` floors (incl. CentOS Stream) | Verify Debian netboot `Release.gpg` when used |
| **Tampering** | Compromised guest mutates host files via shared folders or persistent disk | Boundary 1 | `Hardened` & `Agent` enforce disposable disks (`ephemeral = true`), zero shared folders, zero suspend state, 2 h runtime cap | Signed vsock guest agent for sanitized patch extraction (`V4`) |
| **Repudiation** | Unaudited control-plane calls or egress denials | Boundaries 2 & 3 | `ControlDenial` logged via `os.Logger` (redacted IDs, never tokens); `FlowEvent` ring buffer & throttled logs | Structured SIEM export bundle (`V7` / `R-OPS-1`) |
| **Information Disclosure** | Guest reads host clipboard, microphone, battery/timezone, or LAN/metadata services | Boundaries 1 & 2 | `Isolated` / `Hardened` / `Agent` turn off clipboard, audio, hostInfo, serial console, and enforce `NetPolicy` floor | Live macOS guest filtered-network validation matrix (`V1`) |
| **Denial of Service** | Hostile guest floods `NetStack` flows, DNS queries, or `ControlService` logs/screenshots | Boundaries 2 & 3 | Bounded flow tables, `TokenBucket`, `FlowLogThrottle`, `ControlLimits`, `ControlLog.maxBytes` (64 KiB), `ControlScreenshot.maximumBytes` (700 KiB), `maxRuntimeMinutes` | Continuous coverage-guided fuzzing of `NetStack`/`DNSWire`/`PGP` |
| **Elevation of Privilege** | Guest exploits `Virtualization.framework` or `VirtioGPU` / `PrivateInterfaces` to escape into host | Boundaries 1 & 5 | Per-workload App-Sandboxed `VMHelper`; `PrivateCapabilityPolicy` & `CustomGPU` disabled in `Isolated`/`Hardened`/`Agent` and via MDM | Hypervisor escape is Apple's boundary (report to Apple); compile-time exclusion option for enterprise agent builds (`N-V4`) |

## 4. Accepted residual risks (with review expiry)

| Risk | Owner | Mitigation today | Review / expiry date |
|---|---|---|---|
| `N-V3`: Hypervisor or Virtualization.framework guest escape | Maintainer | Per-workload App-Sandboxed `VMHelper`, hardened entitlements, zero host channels in `Hardened`/`Agent` | 2027-02-25 |
| `N-V4`: `PrivateInterfaces` & `VirtioGPU` linked into standard app binary | Maintainer | Runtime-blocked in `Isolated`/`Hardened`/`Agent`, by MDM (`AllowPrivateInterfaces`), and by `DisablePrivateInterfaces` | 2027-02-25 |
| `V1`: Filtered network live-validated on Linux; macOS guest matrix pending | Maintainer | Same `NetStack`/`NetPolicy` unit & harness coverage; macOS guest test scheduled | 2027-02-25 |
