import Foundation
import PrivateInterfaces
import Virtualization

/// The developer default that lets a Windows machine start although its performance-monitoring emulation is off or
/// unavailable: `defaults write <the app's bundle identifier> WindowsStartsWithoutPMU -bool true`. It is for watching what
/// Windows does without it, not a setting in the app. It is read once when a machine starts, so a change affects the next start
/// only. Only an explicit true turns it on: an absent key, a false and a value of any other type leave the start refused.
enum WindowsStartsWithoutPMU {
    static let defaultsKey = "WindowsStartsWithoutPMU"

    static func isOn(in defaults: UserDefaults = PreferencesDomain.defaults) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) == true
    }
}

/// What a Windows start decides about its private interface before the builder runs, read once when the machine is prepared
/// (`VZMachineFactory.prepare`) and handed to the builder: whether the policy allows the interface, how to turn it on for a
/// platform configuration, and whether the developer default lets the machine start without it. A test states each of them.
struct WindowsStartSettings: Sendable {
    var decision: PrivateCapabilityPolicy.Decision
    var applyPerformanceMonitoring: @Sendable (VZGenericPlatformConfiguration) -> PrivateCapabilityStatus
    var startsWithoutPerformanceMonitoring: Bool
    var applyFramebufferBoot: @Sendable (VZGenericPlatformConfiguration) -> PrivateCapabilityStatus = { _ in .unavailable(.notRegistered) }
    var bootMedia: WindowsBootMedia?

    /// The settings of this Mac and this app for `config`, which is the configuration the start uses (managed keys applied).
    /// Without a `context`, this Mac's is used with the capability turned off when the kill switch is on in `defaults`.
    static func current(
        for config: VMConfig, managed: ManagedPreferences = .current, defaults: UserDefaults = PreferencesDomain.defaults,
        context: PrivateCapabilityContext? = nil, registry: CapabilityRegistry = .standard
    ) -> Self {
        let killSwitch = PrivateInterfacesKillSwitch.isOn(in: defaults)
        let context = context ?? .current(killed: killSwitch ? Set(PrivateCapabilityID.allCases) : [])
        return Self(
            decision: PrivateCapabilityPolicy.decide(posture: config.detectedProfile, managed: managed, killSwitch: killSwitch),
            applyPerformanceMonitoring: { PMUEmulation.apply(to: $0, in: context, registry: registry) },
            startsWithoutPerformanceMonitoring: WindowsStartsWithoutPMU.isOn(in: defaults),
            applyFramebufferBoot: { WindowsBootEmulation.apply(to: $0, in: context) })
    }
}
