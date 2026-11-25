import Foundation
import PrivateInterfaces

/// Who may turn a private interface on: the machine's security profile, the organisation's managed preferences and a developer's
/// kill switch (ADR-0019, ADR-0059). The decision is made before the capability module is asked anything, so a closed profile or a
/// managed refusal never reaches the framework.
enum PrivateCapabilityPolicy {
    /// The managed key that turns every private interface off for the organisation's Macs.
    static let managedKey = ManagedKey.allowPrivateInterfaces

    enum Decision: Equatable, Sendable {
        case allowed
        case denied(Reason)

        var isAllowed: Bool { self == .allowed }
    }

    /// Why a private interface is off, in the order the policy looks: the organisation first, then the profile, then the kill switch.
    enum Reason: Equatable, Sendable, CustomStringConvertible {
        case managedKey
        case profile(SecurityProfile)
        case killSwitch

        var description: String {
            switch self {
            case .managedKey:
                "your organisation turned private interfaces off (\(ManagedKey.allowPrivateInterfaces.rawValue))"
            case .profile(let profile):
                "this machine uses the \(profile.label) profile, which closes private interfaces"
            case .killSwitch:
                "the developer default \(PrivateInterfacesKillSwitch.defaultsKey) is on"
            }
        }
    }

    /// The profiles that close every private interface.
    static let closingProfiles: Set<SecurityProfile> = [.isolated, .hardened, .agent]

    /// `posture` is the profile the machine matches (`VMConfig.detectedProfile`), or nil when its switches have been customized,
    /// which no profile closes. A refusal by the organisation outranks the profile, and the profile outranks the kill switch, so
    /// the reason names the party that can change the outcome last.
    static func decide(posture: SecurityProfile?, managed: ManagedPreferences, killSwitch: Bool) -> Decision {
        if managed.isLocked(managedKey) { return .denied(.managedKey) }
        if let posture, closingProfiles.contains(posture) { return .denied(.profile(posture)) }
        if killSwitch { return .denied(.killSwitch) }
        return .allowed
    }

    /// What the exposure summary says about a private interface a machine would use.
    static func exposure(for capability: PrivateCapabilityID) -> Exposure {
        Exposure(
            level: .low,
            text: "Private interface: \(capability.title). The app uses a framework switch Apple does not document; "
                + "it can stop working with a macOS update.")
    }
}

/// A developer's kill switch for every private interface, in the app's defaults domain: `defaults write <the app's bundle
/// identifier> DisablePrivateInterfaces -bool true`. It is read once when a machine starts, not a setting in the app. Only an
/// absent key or an explicit false leaves the interfaces on; a value of any other type turns them off.
enum PrivateInterfacesKillSwitch {
    static let defaultsKey = "DisablePrivateInterfaces"

    static func isOn(in defaults: UserDefaults = PreferencesDomain.defaults) -> Bool {
        guard let stored = defaults.object(forKey: defaultsKey) else { return false }
        return (stored as? Bool) != false
    }
}

extension VMConfig {
    /// The private interfaces this machine's start would use, each listed in its exposure summary. A Windows machine needs the
    /// performance-monitoring emulation; a guest that needs another names it here, and the switch fails to compile until it does.
    var privateCapabilities: [PrivateCapabilityID] {
        switch guest {
        case .macOS, .linux: []
        case .windows: [.performanceMonitoringEmulation, .fineGrainedTrapsEmulation]
        }
    }
}
