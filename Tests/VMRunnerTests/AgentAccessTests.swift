import Foundation
import Testing

@testable import VMRunner

/// The per-machine agent access switch: stored with a tolerant decode, set by the security profiles, part of the posture,
/// listed in the exposure summary, and explained in the help.
struct AgentAccessTests {
    private func machine(_ guest: GuestOS = .linux, access: Bool = true) -> VMConfig {
        var config = VMConfig.new(name: "a", guest: guest)
        config.agentAccess = access
        return config
    }

    @Test
    func accessIsOffForANewMachineAndForAConfigWrittenBeforeTheSwitchExisted() throws {
        for guest in GuestOS.allCases { #expect(!VMConfig.new(name: "n", guest: guest).agentAccess) }
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        #expect(try !VMConfig.decode(from: Data(old.utf8)).agentAccess)
    }

    @Test
    func theSwitchIsStoredAndReadBack() throws {
        #expect(try VMConfig.decode(from: machine().encoded()).agentAccess)
        #expect(try !VMConfig.decode(from: machine(access: false).encoded()).agentAccess)
    }

    @Test(arguments: SecurityProfile.allCases, GuestOS.allCases)
    func eachProfileSetsAccessAsItsDefinitionSays(profile: SecurityProfile, guest: GuestOS) {
        let applied = machine(guest).applying(profile)
        let forcedOff = profile == .isolated || profile == .hardened
        #expect(applied.agentAccess == !forcedOff, "\(profile) \(guest)")
        #expect(applied.detectedProfile == profile, "access that is on must not hide the profile it was applied with")
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened], GuestOS.allCases)
    func turningAccessBackOnAfterAClosedProfileMakesItCustom(profile: SecurityProfile, guest: GuestOS) {
        var config = machine(guest).applying(profile)
        #expect(!config.agentAccess)
        config.agentAccess = true
        #expect(config.posture.agentAccess)
        #expect(config.detectedProfile == nil)
    }

    @Test(arguments: [SecurityProfile.standard, .contained])
    func openProfilesKeepTheUsersChoice(profile: SecurityProfile) {
        #expect(machine(access: true).applying(profile).agentAccess)
        #expect(!machine(access: false).applying(profile).agentAccess)
    }

    @Test(arguments: GuestOS.allCases)
    func theExposureSaysWhatAnAgentCanDoAndRanksItLow(guest: GuestOS) throws {
        let line = try #require(machine(guest).exposures.first { $0.text.hasPrefix("Agent access") })
        #expect(
            line.text == "Agent access: a script or AI agent with a control token can see this machine and start or stop it "
                + "while the control service is on in Settings. A token with the Read screen capability can also read the picture "
                + "of the screen of a machine that uses the custom GPU.")
        #expect(line.level == .low)
    }

    @Test
    func theExposureIsAbsentWhileAccessIsOffOrAProfileClosedIt() {
        #expect(!machine(access: false).exposures.contains { $0.text.hasPrefix("Agent access") })
        for profile in [SecurityProfile.isolated, .hardened] {
            #expect(!machine().applying(profile).exposures.contains { $0.text.hasPrefix("Agent access") }, "\(profile)")
        }
    }

    @Test
    func theHelpExplainsTheSwitchAndWhatTurnsItOff() {
        let entry = HelpTopic.agentAccess.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        #expect(entry.area == .security)
        #expect(text.contains("Allow agent access"))
        #expect(text.contains("Isolated and Hardened"))
        #expect(entry.related.contains(.exposureSummary))
    }
}
