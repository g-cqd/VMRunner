import Foundation
import Testing

@testable import VMRunner

/// A provisioning spec is a channel from the Mac into the guest: the Isolated and Hardened profiles remove it, it is part of
/// the posture, and the exposure summary lists it while it is in use.
struct ProvisioningPostureTests {
    private func machine(_ guest: GuestOS = .linux) -> VMConfig {
        var config = VMConfig.new(name: "m", guest: guest)
        config.provisioningSpecPath = "/Users/me/machine.yaml"
        return config
    }

    @Test(arguments: SecurityProfile.allCases, GuestOS.allCases)
    func eachProfileKeepsOrRemovesTheSpecAsItsDefinitionSays(profile: SecurityProfile, guest: GuestOS) {
        let applied = machine(guest).applying(profile)
        let removed = profile == .isolated || profile == .hardened
        #expect(applied.provisioningSpecPath.isEmpty == removed, "\(profile) \(guest)")
        #expect(applied.detectedProfile == profile, "a spec that is kept must not hide the profile it was applied with")
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened])
    func aSpecChosenAgainAfterAClosedProfileMakesALinuxMachineCustom(profile: SecurityProfile) {
        var config = machine().applying(profile)
        config.provisioningSpecPath = "/Users/me/machine.yaml"
        #expect(config.posture.provisioning)
        #expect(config.detectedProfile == nil)
    }

    @Test
    func aMacGuestHasNoProvisioningInItsPosture() {
        #expect(!machine(.macOS).posture.provisioning)
    }

    @Test
    func theExposureNamesTheSpecAndSaysTheStepsRunAsRoot() throws {
        let line = try #require(machine().exposures.first { $0.text.hasPrefix("Provisioning") })
        #expect(
            line.text == "Provisioning (experimental): at each start the guest reads a seed built from /Users/me/machine.yaml "
                + "and runs its steps as root.")
        #expect(line.level == .medium)
    }

    @Test
    func theExposureIsAbsentWhileTheSpecIsNotInUse() {
        var installing = machine()
        installing.installerISO = "/Users/me/installer.iso"
        var none = machine()
        none.provisioningSpecPath = ""
        for config in [installing, none, machine(.macOS), machine().applying(.isolated)] {
            #expect(!config.exposures.contains { $0.text.hasPrefix("Provisioning") })
        }
    }
}
