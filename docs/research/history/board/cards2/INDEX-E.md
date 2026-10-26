# INDEX-E — Chain E: roadmap features 0010, 0011, 0012, 0013

Base: `main` at `73bceb0`. Every anchor of every card was read on that commit; cards after the first anchor on the text the
earlier cards of this chain leave behind (each card says which cards must be committed first). Locate by text, never by line.

Files: COMMON.md (in `../cards/`, rules every card follows), CHECKLIST-E.md (what the sonnet reviewer checks before dispatch),
E01.md to E17.md (one per card, one commit each).

## Worktree

The integrator creates it, never a card:
```
git -C ~/Developer/g-cqd/VMRunner worktree add ~/Developer/g-cqd/VMRunner-chains/e-features -b chain/e-features main
```
`WT = ~/Developer/g-cqd/VMRunner-chains/e-features`. One chain, cards strictly in order: each card
builds on the files the previous ones wrote. One build at a time for this chain (the gate takes 3 to 10 minutes).

## How to read the code blocks of a card

A fenced block nested in a list item is indented by the list's indentation. Remove exactly the indentation of the block's
opening fence (the line that starts with three backticks) from every line of the block; what remains is the text to write,
with its own indentation. Quoted single lines in backticks (`old` text) are written with their leading spaces as shown. The
base for every `old` text is the file as the previous cards left it **after** `swift-format` (the review formatted every
block and found no change, so the text below is what the file holds).

## Overrides of COMMON for chain E

COMMON's "Never touch" list holds, with these exceptions, and only for the lines each card names:
- `Sources/NetPolicy/NetworkPolicy.swift`: E01 makes `vpn` `package` (one keyword).
- `Sources/NetPolicy/VPNRequirement.swift`: E02 makes `allowsNetwork(vpn:)` `package` (one keyword).
- `Sources/VMRunner/Model/Security.swift`: E01 (kill-switch exposure lines) and E04 (host information in the Isolated
  summary, `applying`, `Posture`, `posture`, `exposures`).
- `Sources/VMRunner/Engine/VMController.swift`: E09 (one line replaced) and E11 (two lines replaced, one comment line added).
  Its class body is at the 300-line `type_body_length` limit (298 counted lines including braces on `73bceb0`): no card
  adds a counted line to it; new logic lives in new types and files (`NetworkCutoff`, `HostInfoPublisher`,
  `MachineIdentity.swift`) or in `VZGuestMachine`. A later card that must add to `VMController` puts it in a same-file
  `extension VMController`, never in the class body, and never disables the rule.
Paths in COMMON that do not exist on this base (`Sources/VMRunner/Network`, `Sources/VMRunner/Policy`) stay forbidden.

## Order and dependencies

| Card | Roadmap | What | Needs (committed) | Size (lines) |
|---|---|---|---|---|
| E01 | 0010 | VPN rule and metered switch: editor, exposure lines, help topic `killSwitch` | — | ~140 |
| E02 | 0010 | Rules, `NetworkCutoff` watcher, attachment swap in `VZGuestMachine`, factory | E01 | ~190 (see below) |
| E03 | 0010 | `GuestMachine.networkCutoff`, toolbar "Network cut" with its reason | E02 | ~45 |
| E04 | 0011 | `HostInfoSharing` switches, Isolated/Hardened clear them, posture, exposure, help `hostInformation` | E03 | ~140 |
| E05 | 0011 | Read-only share `vmrunner-host` over a fresh `HostInfo` folder | E04 | ~85 |
| E06 | 0011 | `HostFacts` and its files; editor section with preview | E02, E04, E05 | ~155 (see below) |
| E07 | 0011 | Battery and power source from IOKit | E06 | ~45 |
| E08 | 0011 | `HostInfoPublisher` (start, every 60 s, on path change) and wiring | E02, E05, E06, E07 | ~145 |
| E09 | 0012 | `MACVendor` generator replaces `randomLocallyAdministered()` | E08 (order only) | ~95 |
| E10 | 0012 | NVMe disk for Linux, virtio disk serial, bound in `ConfigBoundsTests` | E09 (order only) | ~100 |
| E11 | 0012 | Fresh MAC and machine identifier per disposable start (ephemeral identifier file) | E09 | ~110 |
| E12 | 0012 | Identity editor section; help `guestIdentity` (what a guest can still tell) | E09, E10, E11 | ~130 |
| E13 | 0013 | `AppSetting`: one enum for the app's settings keys | E12 (order only) | ~40 |
| E14 | 0013 | `ManagedPreferences` (forced keys, fail closed), clamp in `VMLibrary` load/add/update | E04, E13 | ~150 (see below) |
| E15 | 0013 | `.managedLock(key)` on the editor controls | E06, E14 | ~75 |
| E16 | 0013 | Locks on app settings; help `managedSettings` | E13, E14, E15 | ~100 |
| E17 | all | README, roadmap 0010 to 0013, row G of 0036, diary | E01 to E16 | ~130 docs |

Larger than the usual 120 lines, and why they are not split: E02, E06 and E14 add a value type together with its only
production caller, because the dead-code gate runs in production mode (`"production": true` in `.deadwood.json`): a type
used only by tests fails it, and acceptance comments on every member are more fragile than one larger card. Most of each
card is code to copy verbatim, and tests.

## Cards that need a real guest or a real network

**No card needs one to be applied:** every card's commands are unit tests with fakes and the gate, which never starts a
virtual machine. What the cards cannot prove is listed here as owner runs; **haiku must not run them** (CONTRIBUTING,
"Real-guest runs": owner-authorised, scratch data directory, capped guest, app window only).

| Run | After | What to observe |
|---|---|---|
| R1 | E03 | Kill switch on a real Linux guest, NAT and filtered: rule "Required" without a VPN cuts the link (guest `ip link`), connecting a VPN on the Mac brings it back, the toolbar shows "Network cut"; the metered switch on a phone's hotspot; the reattached NAT attachment really carries traffic again (unverified: the same attachment object is put back), also after a restore of a suspended machine |
| R2 | E08 | `mount -t virtiofs vmrunner-host` in a Linux guest and `mount_virtiofs vmrunner-host` in a macOS guest (custom tag on macOS unverified), each file readable, a change visible without remounting, and Suspend still working with host information on |
| R3 | E10 | A Linux guest booted with its disk on NVMe; the serial in `/dev/disk/by-id` for a virtio disk |
| R4 | E11 | A disposable macOS guest started with a fresh machine identifier (boots, new serial number) |
| R5 | E09 | DHCP on NAT for an address with each vendor prefix |
| R6 | E16 | A real configuration profile forcing the keys: locks shown, clamp applied, `defaults write` not treated as policy |
| R7 | E07 | On a laptop: the `battery` file against the menu bar's figure (not a guest, but real hardware) |

## Blocked or not carded

- **The in-guest VPN probe (roadmap 0010, first clause): not carded.** There is no guest-side program in the repository,
  and the host side would be a vsock listener whose bytes the app parses: a new guest-to-host channel, which needs its own
  ADR (wire format, who installs the program, limits) like ADR-0052 did for the console. E17 records it under "Not built".
- **Roadmap 0009** is `in-progress` in its front matter (the request called it done); 0010 keeps `blocked-by: ["0009"]`
  unchanged. Nothing in chain E depends on 0009's remaining work.

## Owner decisions (the default each card implements)

1. **0011 delivery: a read-only virtio-fs share, not vsock.** The roadmap allows either and the study names a share; a
   share needs no guest agent and the app parses nothing from the guest. Folder `HostInfo` in the bundle, removed and made
   again at each start (a copied bundle's link is never followed); tag `vmrunner-host`; one `key=value` file per category;
   rewritten at start, every 60 s and on a path change.
2. **Profiles and host information:** Standard and Contained keep the user's choice; Isolated (and so Hardened) clears all
   five. Counted in the posture.
3. **Kill switch rule source:** the VPN rule already stored in `NetworkPolicy.vpn` (made `package`), applying with NAT and
   filtered; no second field. The metered switch is a new `VMConfig` field.
4. **Kill switch at start:** an unknown VPN state cuts (fail closed, as `VPNRequirement` already defines), so a guest with a
   VPN rule starts with its link down for a moment.
5. **Kill switch and realism knobs are outside the profiles and the posture.** The kill switch has informational exposure
   lines (level none); the realism knobs have none.
6. **MAC vendors:** none (locally administered, the default), Apple `00:03:93`, Intel `00:1B:21`, Realtek `00:E0:4C`. The
   three prefixes were checked against the public IEEE MA-L registry (`oui.csv`) by the pre-dispatch review on 2026-10-22:
   `000393` Apple, Inc., `001B21` Intel Corporate, `00E04C` Realtek Semiconductor Corp.
7. **Fresh identity:** a switch, off by default, honoured for disposable machines only, for both the MAC and the machine
   identifier, macOS guests included (R4 owed).
8. **NVMe:** Linux guests only; the serial applies to virtio disks only (the framework has no NVMe identifier).
9. **Managed keys, first set:** `AllowSharedFolders`, `AllowClipboardSharing`, `AllowMicrophone`, `AllowSuspend`,
   `AllowHostInformation`, `RequireDisposableMachines`, `MaxRuntimeMinutes`, plus the four app settings. A wrong type
   restricts; a bad `MaxRuntimeMinutes` becomes 15. Read from the app's own domain even under `VMRUNNER_DATA_DIR`; the
   library reads it at launch (no live re-read), the locks read it when drawn. A forced `MaxRuntimeMinutes` locks the
   whole stepper.
10. **ADR-0013 stays `proposed`.** The roadmap entry does not say otherwise. **Owner action: accept ADR-0013 (or change it)
    with the key set above; E17 lists it under "Owed" in roadmap 0013.**

11. **A forced `MaxRuntimeMinutes` of 0 (or any value outside 15 to 1440) restricts to 15 minutes**, it never reads as "no
    limit": the fail-closed reading. If the owner wants 0 to mean no limit, say so before E14 is dispatched.

## Cards to read twice (uncertain lines)

- E07: `guard let blob = unsafe IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, .unknown) }` and the
  other three `unsafe` expressions: reviewed by compiling the function alone in a scratch directory with
  `-strict-memory-safety -warnings-as-errors` (clean; without the four `unsafe` markers it warns, so each is needed), then
  linking and running it (it printed a percentage and `ac`). `IOPSCopyPowerSourcesInfo` returns `Unmanaged<CFTypeRef>?`.
  The card still stops on any diagnostic rather than trying placements.
- E02: `device.attachment = attachment` (putting the detached NAT or file-handle attachment back): the API allows it
  (`VZNetworkDevice.attachment` is `nullable, strong`, settable at run time; a refused change is reported to the delegate and
  leaves the property nil), the framework's behaviour with the same object again is unverified (R1). Also unverified: a
  change of attachment on a machine that was just restored and is still paused (R1).
- E08: `while (try? await sleep(Self.interval)) != nil {` relies on a cancelled sleep throwing to end the loop;
  the test covers the timing with `TestClock`, not the cancellation. Reviewed: both `ContinuousClock.sleep` and `TestClock.sleep`
  throw `CancellationError` when the task is cancelled, `try?` turns that into nil, the loop ends, and `isolated deinit`
  cancels the task when the publisher is released; the task holds the publisher weakly, so nothing keeps it alive.
- E14: `maxRuntimeMinutes = (value as? Int).flatMap { offered.contains($0) ? $0 : nil } ?? EditorLimits.runtimeStepMinutes`:
  a forced Boolean bridges to 0 or 1 as `Int` and so becomes 15, which is the intended fail-closed result. Reviewed: a
  forced `0` also becomes 15 (the range tested is 15 to 1440), a forced `0` is not read as "no limit".
- E05: `#expect(share.directory.url.resolvingSymlinksInPath().path == bundle.hostInfoFolder.resolvingSymlinksInPath().path)`
  assumes `VZSharedDirectory` keeps the URL it is given. Reviewed: both sides are resolved through symbolic links and compared
  as paths (so a trailing slash or `/private` prefix does not matter); the remaining risk is the framework returning a different
  folder, which the test would then report.

## After each card and after the chain

As in `../cards/CHECKLIST.md`, "After each merge". The chain's worktree stays until E17 has merged.
