---
date: 2026-10-21
question: "How can the app use private framework behaviour for the use cases public API cannot reach, with the least risk?"
feeds: [roadmap 0029, ADR-0019]
---
# Using private APIs with the least risk

Study, not a decision record. Host: macOS 26.7.1; SDK: macOS 27. Items marked *unverified* were not run.

## Short answer

- Put every private call behind **one module** (`PrivateInterfaces`) with a **capability registry** that fails closed: a
  capability that cannot be resolved and validated on the running OS build is off, and the interface says so.
- Use an existing Objective-C-runtime interop package for selectors (it checks the real method signature against the
  Swift type before any call), add a small typed `dlsym` layer of our own for C symbols, and do not wait for upstream to add
  the gating we need.
- Public entitlements and Developer ID allow some of what the other studies list, and rule out the rest.
  Anything needing a `com.apple.private.*` entitlement is impossible: Apple's code-signing enforcement rejects such a build at
  launch.
- Obfuscating symbol names defeats `strings` and nothing else. It is optional, and nothing may rely on it.

## What a good interop layer does (observed in the reference package)

- Resolves a class with `objc_lookUpClass`, then optionally checks its image and the exported class symbol.
- Treats the **Swift function type as the declaration** of a method and compares it to `method_getTypeEncoding` before the
  call; a mismatch throws and nothing is called. Sizes are rechecked against `NSMethodSignature`, and the receiver's real
  class is rechecked at call time.
- Calls through `NSInvocation` inside `@try/@catch`, so an Objective-C exception becomes a typed error. It cannot catch a
  crash from a wrong ABI assumption.
- Records every resolution and failure, logs a fault once per failing symbol, and has one global switch. A call costs about
  1.6 µs.
- Limits: no blocks, variadics or custom ownership attributes; C functions through `dlsym` and key-value-coding key checks
  are not there yet; there is no OS or build gating, no per-feature switch, and failures are logged with the symbol name in
  clear.

## Techniques per use case

| Use case | Technique | Entitlement | State |
|---|---|---|---|
| Windows PMU emulation | An Objective-C action on the generic platform configuration, signature probably `v@:B` (*inference*) | `com.apple.security.virtualization` only, per the framework header | The selector string exists in this host's shared cache; which class implements it is *unverified* |
| Windows UEFI framebuffer, TPM | Not private API: a guest-side driver; no virtual TPM exists | – | – |
| Fewer virtual-machine tells | Public knobs first: machine identifier, MAC, block-device and NVMe identifiers | – | The macOS 27 headers have no SMBIOS or battery API; private selectors are unknown |
| Custom virtio-gpu | Public `VZCustomVirtioDeviceConfiguration`, macOS 27 | virtualization | Header only; this host is on 26.7.1 |
| Apple's internal Linux GPU path | The framework issues per-feature sandbox extensions (strings for paravirtualized graphics, IOSurface and VideoToolbox exist) | Almost certainly Apple-internal (*inference*) | Strings only |
| Seatbelt SPI | `dlsym` to a closed set of typed C function shapes | none | The symbols are in the SDK's `libsystem_sandbox.tbd`; the public header does not declare them |
| Cross-process display | A helper hosts the view and exports a surface with the public IOSurface XPC call | none | Needs the view's layer contents to be an IOSurface: *unverified* |
| Battery and host information, guest agent | Public vsock device plus an agent | – | No private API needed |
| Saved-state or configuration validation relaxations | A selector call | – | Not recommended; names unknown |

Discovering the private surface: reading class lists from the dyld shared cache with `otool`, `dyld_info` or `ipsw` did not
work here. The safer route is a test that calls `class_copyMethodList` on the framework's classes in our own process and
writes the result, with encodings, to a golden file per OS build.

## Safety design

1. **Capability registry.** Each capability has an id, a minimum and maximum OS build (`kern.osversion`), a resolver, a
   validator, a fallback or "disabled" outcome, and a kill switch. The validator checks the class's image, the selector and
   the exact encoding; for C symbols it pins the image build, since `dlsym` carries no type information.
2. **Isolation.** All private access sits in one module with an allow-list and exposes typed Swift facades only. Risky calls
   run in the per-workload helper, so a crash does not take down the interface. Seatbelt SPI is helper-only: it is
   irreversible, cannot be applied twice and cannot be stacked with App Sandbox (see the sandboxing study).
3. **Policy.** Kill switches persist and can be forced by managed preferences. The Hardened preset turns every private
   capability off. The security summary lists each one as "uses unsupported API". No telemetry. Each call is logged at debug
   level.
4. **Tests, run locally** (CI cannot load the framework with a display or start guests): contract tests that assert exact
   encodings against a golden file per OS build; a canary that fails when any resolution fails on an OS beta; mutation checks
   showing the contract tests catch a wrong encoding; a leak check that builds release and greps the binary for forbidden
   strings; and a lint test that fails when `dlsym`, `NSClassFromString`, `NSSelectorFromString`, `objc_msgSend` or the
   interop import appear outside `PrivateInterfaces`.
5. **Obfuscation, honestly.** A compile-time string macro with per-use-site keys hides names from `strings` and naive static
   scans. The key sits next to the bytes, the algorithm is not cryptographic, and the decoded selector is registered with the
   Objective-C runtime where a debugger sees it. Per-site random keys also make builds non-reproducible. Use it only where a
   static scan matters; the Developer ID route does not need it.

## Risks

- A private selector can change in any OS build; a wrong call can crash the process, and an exception handler does not
  catch a segmentation fault.
- A build carrying a `com.apple.private.*` entitlement is rejected at launch. Do not depend on turning code-signing
  enforcement or SIP off. `com.apple.vm.networking` is restricted but can be requested from Apple.
- Library validation is not an obstacle to this plan, since no private framework is linked. Do not add the entitlement that
  disables it; it weakens the build.
- Enhanced Security entitlements may change how these calls behave. *Unverified*: run the canary suite against a build signed
  with them.
- Notarization does not look for private API; App Review does (guideline 2.5.1). Developer ID is the realistic channel.

## Feasibility with public entitlements, hardened runtime and Developer ID

1. Host and battery information, and the guest agent, over vsock: public API.
2. Seatbelt SPI in a helper: feasible, unsupported.
3. Custom virtio-gpu on macOS 27 hosts: public API, large effort.
4. Windows PMU: feasible but experimental; the missing virtual TPM stays impossible.
5. Headless display through an IOSurface: needs a spike.
6. Fewer virtual-machine tells through public knobs only: partial. `kern.hv_vmm_present` cannot be changed from the host.
7. Validation relaxations: not recommended.
8. Apple's internal GPU extensions: impossible.

## As dependencies

- The interop package: MIT; tools 6.3, macOS 15 floor, Swift 6 mode, strict memory safety, warnings as errors; builds under
  its own flags (package settings do not propagate). It has **no tags or releases**, so `exact:` is impossible and only a
  reviewed `revision:` pin works. It re-exports the string-macro package, so **depend on the interop package alone**; its
  implementation comes from a third repository, which Swift Package Manager will list in `Package.resolved`, and the two
  packages' requirements on that third repository may conflict if both are added (*inference; no resolve was run*).
- Macros need trust in Xcode, or `-skipMacroValidation` on the command line; the manifest of the macro package's
  dependency (swift-syntax) is resolved even when no macro is used.
- Only `PrivateInterfaces` declares the product and imports it (`internal import`). The app and the tests link
  `PrivateInterfaces`, never the package.
- The dependency URLs in `Package.swift` and `Package.resolved` are the one unavoidable mention of those projects; prose
  never names them.

**Gaps to close upstream** (our wrapper works around each): no OS or build gating; one global switch instead of one per
feature; symbol names logged in clear (needs a redacted mode); C functions through `dlsym` and key-value-coding key checks
pending; no tags; no contract tests against the virtualization classes; the object wrapper is not `Sendable` while every
framework call must run on the machine's queue; only Objective-C exceptions are contained, with no out-of-process probe for
crash-prone selectors; and per-site random obfuscation keys make builds non-reproducible (offer a seedable option).

## First spike

1. Create `PrivateInterfaces` with two capabilities: the PMU setter and the sandbox-apply call.
2. A discovery test that writes the method list and the setter's encoding for the generic platform configuration to a golden
   file on this host.
3. The canary and the leak check.
4. Confirm the `v@:B` signature before writing any Windows code.

## Not verified

Which class implements the PMU selector; behaviour on macOS 27 (this host is 26.7.1); whether the machine view's layer
contents are an IOSurface; whether swift-syntax is prebuilt in the toolchain; whether the package plug-ins raise prompts;
whether the two packages' requirements conflict in a real resolve; Enhanced Security's effect on these calls; notarization and
code-signing behaviour for a build carrying private entitlements (known, not re-tested).
