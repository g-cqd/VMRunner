import Foundation
import Testing

@testable import VMRunner

/// The per-machine host-information switches: stored with a tolerant decode, cleared by the closed profiles, counted in
/// the posture, listed in the exposure summary and explained in the help.
struct HostInfoSharingTests {
    private func machine(_ guest: GuestOS = .linux, sharing: Bool = true) -> VMConfig {
        var config = VMConfig.new(name: "h", guest: guest)
        config.hostInfo.battery = sharing
        config.hostInfo.timeZone = sharing
        return config
    }

    private func isHostInfoLine(_ exposure: Exposure) -> Bool { exposure.text.contains("(read-only share)") }

    @Test func nothingIsSharedForANewMachineOrAConfigWrittenBeforeTheSwitches() throws {
        for guest in GuestOS.allCases { #expect(VMConfig.new(name: "n", guest: guest).hostInfo.isEmpty) }
        let head = #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"#
        #expect(try VMConfig.decode(from: Data((head + #""memoryMiB":2048,"diskGiB":32}"#).utf8)).hostInfo == HostInfoSharing())
        let partial = head + #""memoryMiB":2048,"diskGiB":32,"hostInfo":{"thermal":true}}"#
        let decoded = try VMConfig.decode(from: Data(partial.utf8)).hostInfo
        #expect(decoded.thermal && !decoded.battery, "a key missing from a stored object takes its default")
    }

    @Test func theSwitchesAreStoredAndReadBack() throws {
        let config = machine()
        #expect(try VMConfig.decode(from: config.encoded()).hostInfo == config.hostInfo)
    }

    @Test(arguments: SecurityProfile.allCases, GuestOS.allCases)
    func eachProfileSetsTheSwitchesAsItsDefinitionSays(profile: SecurityProfile, guest: GuestOS) {
        let applied = machine(guest).applying(profile)
        let cleared = profile == .isolated || profile == .hardened
        #expect(applied.hostInfo.isEmpty == cleared, "\(profile) \(guest)")
        #expect(applied.detectedProfile == profile, "what is shared must not hide the profile it was applied with")
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened])
    func sharingAgainAfterAClosedProfileMakesItCustom(profile: SecurityProfile) {
        var config = machine().applying(profile)
        config.hostInfo.thermal = true
        #expect(config.detectedProfile == nil)
    }

    @Test func theSummaryNamesWhatIsSharedAndRanksItLow() throws {
        let line = try #require(machine().exposures.first(where: isHostInfoLine))
        #expect(line.text == "The guest can read this Mac's battery level, time zone (read-only share).")
        #expect(line.level == .low)
        #expect(!machine(sharing: false).exposures.contains(where: isHostInfoLine))
    }

    @Test func theHelpSaysHowToReadItAndWhoTurnsItOff() {
        let entry = HelpTopic.hostInformation.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for phrase in ["read-only", "mount -t virtiofs", "mount_virtiofs", "Isolated and Hardened", "percent="] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
        #expect(SecurityProfile.isolated.summary.contains("host information"))
    }
}
