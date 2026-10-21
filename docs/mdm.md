# MDM and VMRunner

**Status: investigated, not implemented.** Short answer: Apple documents no way to push a host Mac's MDM policy into a
Virtualization.framework guest. The practical enterprise story is to let an MDM configure **VMRunner itself**.

## 1. Enrolling a macOS guest in an MDM

- **Automated Device Enrollment does not work with VZ guests.** The guest's machine identifier determines its serial
  number, hardware UUID, and provisioning UUID; a chosen serial cannot be turned into an identifier
  ([Eclectic Light](https://eclecticlight.co/2022/08/24/virtualisation-on-apple-silicon-macs-11-machine-identities/)). A test with a
  real serial failed because the VM could not obtain a user identity certificate (no Secure Enclave)
  ([khronokernel](https://khronokernel.com/macos/2023/08/18/AS-VM-SERIAL.html)); Iru says spoofing a serial for Apple Business
  Manager is "no longer possible" on Apple silicon ([Iru](https://www.iru.com/blog/archive/mac-virtualization)).
- **User-initiated (profile-based) enrollment works** (Jamf on Tart VMs: [Snelson](https://snelson.us/2022/05/testing-sideways-jamf-pro-enrollments-with-tart/);
  [MacStadium](https://docs.macstadium.com/remote-desktop-vdi/configuration/mdm-enrollment): "That approval step can't be automated away").
- Vendors disagree on support: Intune supports macOS VMs "for testing purposes only"
  ([Microsoft](https://learn.microsoft.com/en-us/intune/device-enrollment/apple/methods-macos)), Iru says "not supported"
  ([Iru](https://docs.iru.com/en/iru/requirements/device-requirements)).
- macOS 26.1 had a bug publishing serial number 0 for VMs ("Fixed" in 26.2); it blocked Jamf enrollment.
- `VZMacGuestProvisioningOptions` (macOS 27 guests) sets up an account on first boot; it does not enroll in an MDM.
- Not found: Apple statements on declarative device management, activation lock, or supervision in VZ guests.

## 2. "Forwarding" the host's policies into a guest

Not recommended and mostly blocked:

- `profiles` cannot install configuration profiles on macOS 11 and later; the Profiles pane is the route, and manual
  install needs user approval. MDM-installed profiles are bound to their MDM and are not designed to be re-exported;
  whether `profiles show` redacts secrets was not verified.
- Wi-Fi, VPN, Restrictions, global proxy, and managed-preferences payloads allow manual install on macOS, so an
  organisation-supplied, guest-targeted bundle is technically installable by hand. Copying the host's installed profiles
  may breach the organisation's policy.
- Mechanisms that exist: a shared folder or a vsock listener to carry a `.mobileconfig` or agent data into the guest;
  trusted roots readable with `SecTrustSettingsCopyCertificates`.
- A host VPN and guest NAT interact badly in community reports (packets leaving un-NATed, or lost connectivity).

## 3. MDM governing VMRunner itself (the practical part)

A configuration profile with payload `com.apple.ManagedClient.preferences` for the domain `com.example.VMRunner` (Forced
settings under `mcx_preference_settings`) lands in `/Library/Managed Preferences`; the app reads it with `UserDefaults`
and checks `objectIsForced(forKey:)`, and must disable the matching UI ([Apple](https://developer.apple.com/documentation/foundation/userdefaults/objectisforced(forkey:))).
Those files are world-readable, so no secrets belong in them. A newer route is the DDM
`com.apple.configuration.app.managed` declaration (`AppConfig` is macOS 27+).

Proposed keys (not implemented): `SecurityProfile`, `AllowSharedFolders`, `AllowClipboardSharing`, `AllowMicrophone`,
`AllowBridgedNetworking`, `AllowedImageHosts`, `RequireDisposableMachines`, `MaxRuntimeMinutes`, `AllowSuspend`,
`RequireVPN` (a check that a tunnel is up, not enforcement).

Enforce at the model layer, not just the UI: reject disallowed configurations at start and import, build the VZ
configuration only after policy evaluation, re-read on change, fail closed on malformed values. No MDM restriction key for
the Virtualization framework or Rosetta was found, and `com.apple.security.virtualization` is a code-signing entitlement
with no documented MDM interaction.

## 4. Linux guests

No MDM. Equivalents: cloud-init (a NoCloud seed disk labelled `CIDATA`, as Lima's VZ driver does), configuration
management, or a guest agent over vsock.

## Recommendation

First slice: a typed `Policy` read from the managed domain with `objectIsForced` checks, one enforcement point at
configuration build and start, annotated locked UI, a diagnostics pane showing each key's value and source, and tests with
a fake `UserDefaults` suite. Defer DDM and the `ManagedApp` framework until macOS 27 behaviour is verified. Document as
unsupported: ADE/ABM for guests, cloning host profiles, silent profile installation, MDM enforcement inside guests.
Risks: another VZ app or a local admin bypassing the policy (mitigate with `PayloadRemovalDisallowed`), key-name drift
between MDM and app, guest enrollment staying vendor-unsupported.
