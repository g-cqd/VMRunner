import Foundation
import Testing

@testable import VMRunner

/// The custom GPU against the security profiles, the exposure summary and the managed preferences.
struct CustomGPUPolicyTests {
    private static let exposureText = "Custom GPU: the app parses the guest's graphics commands itself."

    private func machine(_ guest: GuestOS = .linux, gpu: GPUChoice = .custom) -> VMConfig {
        var config = VMConfig.new(name: "g", guest: guest)
        config.gpu = gpu
        return config
    }

    private func forced(_ values: [String: Any]) -> ManagedPreferences {
        ManagedPreferences(forcedValue: { values[$0] })
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened])
    func closedProfilesForceTheFrameworksOwnDevice(profile: SecurityProfile) {
        #expect(machine().applying(profile).gpu == .apple)
        #expect(machine().applying(profile).detectedProfile == profile)
    }

    @Test(arguments: [SecurityProfile.standard, .contained])
    func openProfilesKeepTheChoiceAndStillReadAsThemselves(profile: SecurityProfile) {
        let custom = machine(gpu: .custom).applying(profile)
        #expect(custom.gpu == .custom)
        #expect(custom.detectedProfile == profile, "the custom device must not hide the profile it was applied with")
        #expect(machine(gpu: .apple).applying(profile).gpu == .apple)
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened])
    func turningTheCustomDeviceBackOnAfterAClosedProfileMakesItCustom(profile: SecurityProfile) {
        var config = machine(gpu: .apple).applying(profile)
        config.gpu = .custom
        #expect(config.posture.customGPU)
        #expect(config.detectedProfile == nil)
    }

    @Test
    func aMacOSGuestIsNeverCustomBecauseItNeverBuildsTheDevice() {
        let config = machine(.macOS, gpu: .custom)
        #expect(!config.posture.customGPU)
        #expect(config.detectedProfile == .standard)
        #expect(!config.exposures.contains { $0.text.hasPrefix("Custom GPU") })
    }

    @Test
    func theExposureNamesHostSideParsingAndRanksItMedium() throws {
        let line = try #require(machine().exposures.first { $0.text.hasPrefix("Custom GPU") })
        #expect(line.text == Self.exposureText)
        #expect(line.level == .medium)
    }

    @Test
    func theExposureIsAbsentWhileTheFrameworksOwnDeviceIsUsedOrAProfileClosedTheChoice() {
        #expect(!machine(gpu: .apple).exposures.contains { $0.text.hasPrefix("Custom GPU") })
        for profile in [SecurityProfile.isolated, .hardened] {
            #expect(!machine().applying(profile).exposures.contains { $0.text.hasPrefix("Custom GPU") }, "\(profile)")
        }
    }

    @Test
    func aDeniedKeyLocksTheChoiceAndForcesTheFrameworksOwnDevice() {
        let refusals: [Any] = [false, "yes", 0]
        for value in refusals {
            let policy = forced(["AllowCustomGPU": value])
            #expect(policy.isLocked(.allowCustomGPU), "\(value)")
            #expect(policy.clamp(machine(gpu: .custom)).gpu == .apple, "\(value)")
            #expect(policy.clamp(machine(gpu: .apple)).gpu == .apple, "\(value)")
        }
    }

    @Test
    func anAllowedOrUnforcedKeyLeavesTheChoiceAlone() {
        let config = machine(gpu: .custom)
        let allowed = forced(["AllowCustomGPU": true])
        #expect(!allowed.isLocked(.allowCustomGPU))
        #expect(allowed.clamp(config) == config)
        let nothing = forced([:])
        #expect(!nothing.isLocked(.allowCustomGPU))
        #expect(nothing.clamp(config) == config, "nothing forced changes nothing")
    }

    @Test
    func theManagedKeyIsNamedInTheHelpOfManagedSettings() {
        let entry = HelpTopic.managedSettings.entry
        #expect((entry.paragraphs + entry.advanced).joined(separator: " ").contains("`AllowCustomGPU`"))
    }
}
