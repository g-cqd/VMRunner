import Foundation
import PrivateInterfaces
import Testing

@testable import VMRunner

/// Whether a private interface may be used: the machine's profile, the managed key and the kill switch, and what the rest of the
/// app says about them.
struct PrivateCapabilityPolicyTests {
    private static let postures: [SecurityProfile?] = [nil, .standard, .contained, .isolated, .hardened]
    private static let closed: Set<SecurityProfile> = [.isolated, .hardened]

    /// A managed policy where the key is not forced, forced to true, and forced to values that restrict.
    private static var managedCases: [ManagedCase] {
        [
            ManagedCase(label: "not forced", values: [:], denies: false),
            ManagedCase(label: "true", values: ["AllowPrivateInterfaces": true], denies: false),
            ManagedCase(label: "false", values: ["AllowPrivateInterfaces": false], denies: true),
            ManagedCase(label: "a string", values: ["AllowPrivateInterfaces": "yes"], denies: true),
            ManagedCase(label: "zero", values: ["AllowPrivateInterfaces": 0], denies: true),
        ]
    }

    private struct ManagedCase {
        let label: String
        let values: [String: Any]
        let denies: Bool
    }

    private func forced(_ values: [String: Any]) -> ManagedPreferences {
        ManagedPreferences(forcedValue: { values[$0] })
    }

    private func machine(_ guest: GuestOS) -> VMConfig { VMConfig.new(name: "p", guest: guest) }

    @Test
    func everyPostureManagedValueAndKillSwitchGivesTheExpectedDecision() {
        var checked = 0
        for posture in Self.postures {
            for managed in Self.managedCases {
                for killSwitch in [false, true] {
                    let decision = PrivateCapabilityPolicy.decide(
                        posture: posture, managed: forced(managed.values), killSwitch: killSwitch)
                    let label = "\(String(describing: posture)) / \(managed.label) / kill switch \(killSwitch)"
                    let profileCloses = posture.map { Self.closed.contains($0) } ?? false
                    if managed.denies {
                        #expect(decision == .denied(.managedKey), "\(label)")
                    } else if profileCloses, let posture {
                        #expect(decision == .denied(.profile(posture)), "\(label)")
                    } else if killSwitch {
                        #expect(decision == .denied(.killSwitch), "\(label)")
                    } else {
                        #expect(decision == .allowed, "\(label)")
                    }
                    #expect(decision.isAllowed == (decision == .allowed), "\(label)")
                    checked += 1
                }
            }
        }
        #expect(checked == Self.postures.count * Self.managedCases.count * 2, "every combination was checked")
    }

    @Test
    func aMachineWhoseSwitchesNoProfileMatchesIsNotClosedByAProfile() {
        #expect(PrivateCapabilityPolicy.decide(posture: nil, managed: forced([:]), killSwitch: false) == .allowed)
        for profile in [SecurityProfile.standard, .contained] {
            #expect(PrivateCapabilityPolicy.decide(posture: profile, managed: forced([:]), killSwitch: false) == .allowed, "\(profile)")
        }
        for profile in [SecurityProfile.isolated, .hardened] {
            let decision = PrivateCapabilityPolicy.decide(posture: profile, managed: forced([:]), killSwitch: false)
            #expect(decision == .denied(.profile(profile)), "\(profile)")
        }
    }

    @Test
    func theReasonsReadAsWordsThatNameTheirCause() {
        #expect(
            PrivateCapabilityPolicy.Reason.managedKey.description
                == "your organisation turned private interfaces off (AllowPrivateInterfaces)")
        #expect(
            PrivateCapabilityPolicy.Reason.profile(.hardened).description
                == "this machine uses the Hardened profile, which closes private interfaces")
        #expect(
            PrivateCapabilityPolicy.Reason.profile(.isolated).description
                == "this machine uses the Isolated profile, which closes private interfaces")
        #expect(
            PrivateCapabilityPolicy.Reason.killSwitch.description == "the developer default DisablePrivateInterfaces is on")
    }

    @Test
    func theManagedKeyIsNamedLocksItsControlAndChangesNoConfiguration() {
        #expect(ManagedKey.allowPrivateInterfaces.rawValue == "AllowPrivateInterfaces")
        let refused = forced(["AllowPrivateInterfaces": false])
        #expect(refused.isLocked(.allowPrivateInterfaces))
        #expect(!forced(["AllowPrivateInterfaces": true]).isLocked(.allowPrivateInterfaces))
        #expect(!forced([:]).isLocked(.allowPrivateInterfaces))
        for guest in GuestOS.allCases {
            let config = machine(guest)
            #expect(refused.clamp(config) == config, "the key decides at start; it rewrites no setting (\(guest))")
        }
    }

    @Test
    func theKillSwitchIsOffWhenAbsentOrExplicitlyFalseAndOnForAnythingElse() throws {
        let name = "PrivateCapabilityPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PrivateInterfacesKillSwitch.defaultsKey == "DisablePrivateInterfaces")
        #expect(!PrivateInterfacesKillSwitch.isOn(in: defaults), "nothing stored")
        let stored: [(Any, Bool)] = [(false, false), (true, true), ("yes", true), ("false", true), (2, true), (0, false)]
        for (value, expected) in stored {
            defaults.set(value, forKey: PrivateInterfacesKillSwitch.defaultsKey)
            #expect(PrivateInterfacesKillSwitch.isOn(in: defaults) == expected, "\(value)")
        }
        defaults.removeObject(forKey: PrivateInterfacesKillSwitch.defaultsKey)
        #expect(!PrivateInterfacesKillSwitch.isOn(in: defaults), "removed again")
    }

    @Test
    func theExposureLineNamesTheInterfaceAndRanksItLow() {
        let line = PrivateCapabilityPolicy.exposure(for: .performanceMonitoringEmulation)
        #expect(line.level == .low)
        #expect(line.text.hasPrefix("Private interface: performance-monitoring emulation."))
        #expect(line.text.contains("does not document"))
    }

    @Test(arguments: GuestOS.allCases)
    func theGuestsTheAppBuildsTodayUseNoPrivateInterfaceAndShowNoLine(guest: GuestOS) {
        let config = machine(guest)
        #expect(config.privateCapabilities.isEmpty)
        #expect(!config.exposures.contains { $0.text.hasPrefix("Private interface") })
    }

    @Test
    func theHelpExplainsTheInterfaceTheProfilesTheKeyAndTheKillSwitch() {
        let entry = HelpTopic.privateInterfaces.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for phrase in [
            "performance-monitoring emulation", "Isolated", "Hardened", "`AllowPrivateInterfaces`", "`DisablePrivateInterfaces`",
        ] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
        #expect(text.contains("Mac App Store"))
        #expect(entry.area == .security)
        #expect(entry.related.contains(.securityProfiles) && entry.related.contains(.managedSettings))
        #expect(HelpCatalog.search("private interface").contains(.privateInterfaces))
    }
}
