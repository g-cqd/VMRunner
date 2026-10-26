# macOS 27 SDK Virtualization survey (2026-10-24)

Written by a read-only researcher agent; saved here by the orchestrator in condensed form. Legend: [H] read in the SDK 27.0
headers or Swift interface, [D] apple-docs or WWDC, [W] web page, [I] inferred. Nothing was built or run.

Method: host Darwin 27.0 / SDK 27.0; compared `MacOSX27.0.sdk` with `MacOSX26.5.sdk` Virtualization headers (117 vs 140 files);
read `Virtualization.swiftinterface`; apple-docs pages (`virtualization/custom-drivers`, `virtualization/graphics`,
`virtualization/vzvirtualmachineviewadaptor`, `wwdc/wwdc2026-224`, macOS 27 release notes); third-party repos vzgpu and EZVM.

## Summary

1. SDK 27.0 adds a Linux-only custom virtio device API: `VZCustomVirtioDevice` with queues, shared-memory regions and guest-memory
   mappings [H, D].
2. Apple's graphics classes are unchanged: `VZVirtioGraphicsDeviceConfiguration` still has one scanout; no 3D/virgl/Venus/Metal
   for Linux in any header [H].
3. So accelerated Linux graphics from Apple is not unblocked. A host-implemented virtio-gpu is now possible, nothing more.
4. The macOS Metal guest path has no SDK change (`VZMacGraphicsDisplay*` differ only in the copyright year) [H].
5. Secure Boot for Linux is unblocked: `VZEFIVariableStore` gains `enableSecureBootUsingDefaultPlatformKey`,
   `enrollDefaultSecureBootSignatures`, `disableSecureBoot` and more [H]. The app already uses them behind `#available(macOS 27.0, *)`.
6. ASIF and stacked images are unblocked through the new DiskImageKit framework; the bridge is the Swift-only
   `VZDiskImageStorageDeviceAttachment(diskImage:...)` [H, D].
7. Other additions: USB passthrough (`VZUSBPassthroughDeviceConfiguration`, needs the Claim USB Accessory capability and the
   AccessoryAccess framework), guest provisioning options (already used), `VZVirtualMachineConfiguration.label`,
   `VZVirtualMachineViewAdaptor`, new `VZErrorCode` values.
8. The only deprecated `VZ*` symbol is `VZMacAuxiliaryStorage initWithContentsOfURL:` (since 12.0), which the app does not use.
9. `Package.swift` has `.macOS(.v26)`; any 27-only code needs `#available(macOS 27.0, *)` (four guarded uses exist today).
10. Spike: a Linux guest with a custom virtio-gpu 2D scanout shown in the app's own view, about 5 cards.

**Most important finding:** SDK 27 adds no accelerated-graphics device, only generic virtio plumbing. Any Linux GPU acceleration is
a virtio-gpu backend VMRunner would implement itself, and a custom device is not a `VZGraphicsDevice`, so `VZVirtualMachineView`
will not display it [I].

## Custom virtio (API_AVAILABLE(macos(27.0)), Linux guests) [H, D]

- `VZVirtualMachineConfiguration.customVirtioDevices`; `VZCustomVirtioDeviceConfiguration` (deviceID, PCI class/subclass,
  queue count, mandatory/optional feature sets, device-specific configuration, provider, shared-memory regions,
  `supportsSaveRestore`).
- `VZCustomVirtioDeviceDelegateProvider(deviceQueue:delegate:)`; `VZCustomVirtioDevice` (negotiated features, guest memory
  mapping, `queueAtIndex:`, `requestDeviceReset`, `updateDeviceSpecificConfiguration`); delegate callbacks for queue
  notifications, DRIVER_OK, stop/pause/resume/reset, save/restore as `NSData`.
- `VZVirtioQueue` / `VZVirtioQueueElement` (read/write buffers, `returnToQueue`; the header warns about TOCTOU on guest memory);
  `VZVirtioSharedMemoryRegion` (map/unmap with host-page alignment).
- No entitlement beyond `com.apple.security.virtualization` is named in the headers (requiring none is an inference).
- **Open gap:** the WWDC talk says the host can trigger an interrupt on the device, but no interrupt-raising method appears in any
  header. `returnToQueue` and `updateDeviceSpecificConfiguration` are the only host-to-guest signals found, untested.

## Secure Boot [H]

`enableSecureBootUsingDefaultPlatformKeyWithError:`, `enableSecureBootWithPlatformKey:error:`, `disableSecureBootWithError:`,
`resetSecureBootWithError:`, `getSecureBootEnabled:error:`, `enrollDefaultSecureBootSignaturesWithError:` (Microsoft KEK, UEFI CA,
revocation list), `enrollSecureBootSignatures:error:`, `getEnrolledSecureBootSignaturesWithError:`, plus signature database
classes and errors 50001/50002.

## Disk images [H, D]

No ASIF symbol in the Virtualization headers. DiskImageKit.framework is new; the base layer can be any supported format including
raw, upper layers are ASIF (`.cache` or `.overlay`); read-only layers can be shared; duplicate the EFI variable store or
auxiliary storage when cloning with a shared base. Single-file ASIF via `init(url:)` already worked on 26 (not tested).

## Candidate verdicts

| Candidate | Verdict |
|---|---|
| Linux virtio-gpu 3D from Apple | No. Header unchanged: one scanout. |
| Linux virtio-gpu via custom device | Possible; everything is yours to build. |
| macOS Metal guest path | No SDK change. |
| Secure Boot for Linux | Yes; already implemented behind `#available`. |
| Stacked or overlay images | Yes, via DiskImageKit. |
| New network devices | None as classes. |
| Save/restore | Custom devices opt in through delegate `NSData`; a GPU device holding renderer contexts cannot be rebuilt from it alone. |

## Custom virtio-gpu details

- virtio-gpu is device ID 16, PCI class 0x03; ID, class, queues, features and config space (events_read, num_scanouts,
  num_capsets) are yours to supply [I, virtio spec].
- Host-visible blobs use the shared-memory region API.
- Guest requirements per the third-party vzgpu README [W, unverified]: Fedora 45 Beta, kernel 7.2.x with a patched `virtio_gpu`
  (blob sizes rounded up for 16 KiB host mapping), Mesa 26.2.4 or later, a 4 KiB-page guest kernel; verified on macOS 27.2 with
  an M5, so it may need a newer host than this 27.0.1. Open defects: tearing, a context-destroy crash, hvc0 input loss. EZVM
  uses a virgl/ANGLE/Metal stack and falls back to Apple's device.
- Still impossible: Apple's own GPU path for Linux, a `VZVirtualMachineView` scanout from a custom device, multiple scanouts on
  Apple's device, save/restore of renderer state, Windows guest acceleration, a custom device for macOS guests (the docs scope
  custom devices to Linux).

## Roadmap and ADR items that say "needs macOS 27"

- 0014 / ADR-0014 item 3 (custom virtio-gpu spike): primitives exist, with the interrupt gap above.
- 0036 row H and 0038: "blocked on a macOS 27 host" — the host is now 27.0.1, so the dependency is met.
- ADR-0004 item 4 (Secure Boot for Isolated and Hardened): already implemented.
- ASIF stacks, USB passthrough, guest provisioning: not listed as blocked, now possible.

## Spike recommendation

Smallest experiment: a throwaway tool with a `VZCustomVirtioDeviceConfiguration` (deviceID 16, PCI class 3, two queues, one
scanout), booting a stock Linux guest with `virtio_gpu` and showing a 2D scanout (`GET_DISPLAY_INFO`, `RESOURCE_CREATE_2D`,
`ATTACH_BACKING`, `TRANSFER_TO_HOST_2D`, `SET_SCANOUT`, `FLUSH`) in an `NSView` or `CAMetalLayer`. Success: a `virtio_gpu` line
in `dmesg` and a visible desktop. Measure frame latency and CPU at 1080p against Apple's baseline, behaviour on pause/resume/
reboot, whether a host-to-guest notify is possible, memory per resource, resize.

| # | Card | Estimate (inference) |
|---|---|---|
| 1 | Feasibility probe: device enumerates, `virtio_gpu` binds, interrupt/notify test | 2 to 3 days |
| 2 | 2D command set plus scanout in a view | 1 to 2 weeks |
| 3 | Integration: toggle, fallback to Apple's device, resize, pause/save-restore policy | about 1 week |
| 4 | virgl GL through virglrenderer and ANGLE, plus bundling | several weeks |
| 5 | Venus (Vulkan) with blob and shared memory | months |

Do 1 and 2 as the spike and stop. Separate cards: DiskImageKit overlays/snapshots (3 to 5 days, behind a 27 guard); optional USB
passthrough (a few days, needs the Claim USB Accessory capability).

## Impact on the current build

Anything above needs `#available(macOS 27.0, *)`. Existing guarded uses: `Model/Security.swift:40`,
`Views/Editor/SmallSections.swift:98`, `Engine/VZGuestMachine.swift:156`, `Engine/ConfigurationBuilder.swift:182`. None of the
`VZ*` symbols the app uses is deprecated in 27. `VZVirtualMachineView` now documents a Swift 6 strict-concurrency issue and the
`adaptor` fix.

## Not verified

The interrupt-raising API; any runtime behaviour; custom devices with macOS guests; entitlements beyond
`com.apple.security.virtualization`; whether the AccessoryAccess capability needs provisioning; the vzgpu and EZVM claims; the
research note's question about a macOS 27 guest's Metal family.
